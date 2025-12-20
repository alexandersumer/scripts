#!/bin/bash
{
set -u -o pipefail
source "$(dirname "$0")/lib/agentcli.sh"

header() { printf '\n%b────────────────────────────────────────%b\n%b%s%b\n' "$DIM" "$RESET" "$BOLD" "$1" "$RESET" >&2; }

show_issues() {
    [[ -z "$1" ]] && return
    local lines count
    lines=$(grep -E '[a-zA-Z0-9_/-]+\.[a-zA-Z]+:[0-9]+' <<< "$1") || true
    count=$(wc -l <<< "${lines:-x}" | tr -d ' ')
    if [[ -z "$lines" ]]; then
        printf '%b%s%b\n' "$DIM" "$(head -5 <<< "$1" | sed 's/^/  /')" "$RESET" >&2
    else
        printf '%b%s%b\n' "$DIM" "$(head -10 <<< "$lines" | sed 's/^/  /')" "$RESET" >&2
        (( count > 10 )) && printf '%b  ...and %d more%b\n' "$DIM" "$((count - 10))" "$RESET" >&2
    fi
}

for cmd in "shasum -a 256" sha256sum md5sum "md5 -r" cksum; do
    command -v "${cmd%% *}" &>/dev/null && { HASH_CMD=$cmd; break; }
done
[[ -z "${HASH_CMD:-}" ]] && fatal "no hash command found"
hash_str() { printf '%s' "$1" | $HASH_CMD | cut -c1-16; }

LOCK_ID=$(hash_str "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
LOCK_DIR="/tmp/checkfix-${LOCK_ID}.lock" LOCK_PID="$LOCK_DIR/pid" LOG_DIR="/tmp/checkfix-${LOCK_ID}-$$"

MAX_ITERS=15 CLEAN_REQUIRED=3 RETRIES=2 TIMEOUT=1200 STUCK_THRESHOLD=90
DRY_RUN=false REPO=false CHILD_PID="" PHASE=""
FILES=() SEEN_HASHES=()

CLI="${CHECKFIX_CLI:-claude}"
[[ -n "${CHECKFIX_CLI:-}" ]] && ! cli_cmd "$CLI" >/dev/null && fatal "unknown CLI: $CLI (available: $CLI_LIST)"

file_mode() { (( ${#FILES[@]} > 0 )); }
repo_mode() { $REPO; }
state_hash() {
    if repo_mode; then hash_str "$(git ls-files -z 2>/dev/null | xargs -0 cat 2>/dev/null)"
    elif file_mode; then hash_str "$(cat -- "${FILES[@]}")"
    else hash_str "$(git diff "$BASE"...HEAD)"; fi
}
diff_size() {
    if repo_mode; then git ls-files -z 2>/dev/null | xargs -0 wc -l 2>/dev/null | tail -1 | awk '{print $1+0}'
    elif file_mode; then wc -l < <(cat -- "${FILES[@]}") | tr -d ' '
    else git diff --numstat "$BASE"...HEAD 2>/dev/null | awk '{s+=$1+$2} END {print s+0}'; fi
}

check_cycle() {
    local hash i=0
    hash=$(state_hash)
    for seen in "${SEEN_HASHES[@]}"; do
        [[ "$seen" == "$hash" ]] && fatal "cycle detected: state matches ${i:+iteration $i}${i:-initial state}"
        ((i++))
    done
    SEEN_HASHES+=("$hash")
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [--files FILE...]

Iteratively check and fix code until stable.

Modes:
    Git mode (default):  Check branch diff against main/master
    File mode:           Check specific files with --files
    Repo mode:           Let CLI explore entire repo with --repo

Options:
    -l, --cli NAME           CLI to use (default: $CLI, available: $CLI_LIST)
    -f, --files FILE...      Check specific files instead of git diff
    -R, --repo               Run repo-wide (CLI explores on its own)
    -m, --max-iterations N   Max iterations (default: $MAX_ITERS)
    -c, --consecutive N      Consecutive passes needed (default: $CLEAN_REQUIRED)
    -r, --retries N          Retries per call (default: $RETRIES)
    -t, --timeout SECONDS    Timeout per call (default: $TIMEOUT)
    --dry-run                Run without calling the CLI
    -h, --help               Show this help

Examples:
    $(basename "$0")                       # Check current branch
    $(basename "$0") -l codex -f lib.py    # Check file with Codex
    $(basename "$0") --repo                # Check entire repo
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -l|--cli) require_val "$1" "${2:-}"; cli_cmd "$2" >/dev/null || fatal "unknown CLI: $2"; CLI="$2"; shift 2 ;;
        -f|--files)
            shift
            while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do
                [[ -f "$1" && -r "$1" ]] || fatal "file not found: $1"
                FILES+=("$(realpath "$1")"); shift
            done
            (( ${#FILES[@]} )) || fatal "--files requires at least one file" ;;
        -m|--max-iterations) require_val "$1" "${2:-}"; require_int "$1" "$2"; MAX_ITERS=$2; shift 2 ;;
        -c|--consecutive)    require_val "$1" "${2:-}"; require_int "$1" "$2"; CLEAN_REQUIRED=$2; shift 2 ;;
        -r|--retries)        require_val "$1" "${2:-}"; require_int "$1" "$2"; RETRIES=$2; shift 2 ;;
        -t|--timeout)        require_val "$1" "${2:-}"; require_int "$1" "$2"; TIMEOUT=$2; shift 2 ;;
        -R|--repo) REPO=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage ;;
        *) fatal "unknown option: $1" ;;
    esac
done

$REPO && (( ${#FILES[@]} )) && fatal "cannot use both --repo and --files"

CLI_CMD=$(cli_cmd "$CLI")
[[ -n "${CHECKFIX_CLI_CMD:-}" ]] && CLI_CMD="$CHECKFIX_CLI_CMD" CLI="custom"
command -v "${CLI_CMD%% *}" &>/dev/null || fatal "$CLI not found in PATH"

# shellcheck disable=SC2329  # Used by trap
cleanup() {
    local code=$?
    trap - EXIT
    [[ -n "$CHILD_PID" ]] && kill "$CHILD_PID" 2>/dev/null
    [[ -f "$LOCK_PID" && "$(<"$LOCK_PID")" == "$$" ]] && rm -rf "$LOCK_DIR"
    if (( code == 0 )); then rm -rf "$LOG_DIR"; else say checkfix "logs: $LOG_DIR"; fi
    exit "$code"
}
trap 'printf "\n" >&2; warn checkfix interrupted; cleanup' INT TERM
trap cleanup EXIT

acquire_lock() {
    local attempt=0 tmp pid
    tmp=$(mktemp) || fatal "cannot create temp file"
    echo "$$" > "$tmp"
    while (( ++attempt <= 5 )); do
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            mv "$tmp" "$LOCK_PID" 2>/dev/null && return 0
            rm -rf "$LOCK_DIR" "$tmp"; fatal "cannot install PID file"
        fi
        pid=$(<"$LOCK_PID" 2>/dev/null)
        [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && { rm -f "$tmp"; fatal "already running (PID $pid)"; }
        rm -rf "$LOCK_DIR" 2>/dev/null
        sleep 0.1 2>/dev/null || sleep 1
    done
    rm -f "$tmp"; fatal "cannot acquire lock"
}

verify_repo() {
    git rev-parse --git-dir &>/dev/null || fatal "not a git repository: use --files for standalone files"
    BRANCH=$(git rev-parse --abbrev-ref HEAD)
    [[ "$BRANCH" =~ ^(main|master)$ ]] && fatal "on protected branch '$BRANCH': checkout a feature branch or use --files"

    BASE=; for b in main master; do git rev-parse --verify "$b" &>/dev/null && { BASE=$b; break; }; done
    if [[ -z "$BASE" ]] || git diff --quiet "$BASE"...HEAD 2>/dev/null; then
        local upstream; upstream=$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null) || true
        [[ -n "$upstream" ]] && ! git diff --quiet "$upstream"...HEAD 2>/dev/null && BASE=$upstream
    fi
    [[ -z "$BASE" ]] && fatal "no base branch found: ensure main/master exists or use --files"

    git diff --quiet "$BASE"...HEAD 2>/dev/null && git diff --quiet HEAD 2>/dev/null && git diff --quiet --cached 2>/dev/null &&
        fatal "no changes detected: nothing to check"
    say checkfix "$BRANCH → $BASE"
}

run_cli() {
    local prompt=$1 output=$2 start last_size last_change elapsed size status code
    read -ra cmd_parts <<< "$CLI_CMD"

    for (( attempt=1; attempt<=RETRIES; attempt++ )); do
        $DRY_RUN && { echo "[PASS] Dry run" > "$output"; return 0; }

        start=$(now) last_size=0 last_change=$start
        : > "$output"

        if [[ -n "${TIMEOUT_CMD:-}" ]]; then printf '%s' "$prompt" | "$TIMEOUT_CMD" "${TIMEOUT}s" "${cmd_parts[@]}" > "$output" 2>&1 &
        else printf '%s' "$prompt" | "${cmd_parts[@]}" > "$output" 2>&1 & fi
        CHILD_PID=$!

        while kill -0 "$CHILD_PID" 2>/dev/null; do
            sleep 1
            elapsed=$(($(now) - start)) size=$(wc -c < "$output" 2>/dev/null || echo 0) status=active
            [[ -z "${TIMEOUT_CMD:-}" ]] && (( elapsed >= TIMEOUT )) && { kill "$CHILD_PID" 2>/dev/null; wait "$CHILD_PID" 2>/dev/null; CHILD_PID=""; return 1; }
            if (( size > last_size )); then last_size=$size last_change=$(now)
            elif (( $(now) - last_change >= STUCK_THRESHOLD )); then
                is_stuck "$output" && { printf '\n' >&2; fatal "CLI blocked on permission prompt"; }
                status=stalled
            fi
            progress "$PHASE" "$status" "$elapsed"
        done
        wait "$CHILD_PID" 2>/dev/null; code=$?
        CHILD_PID=""

        [[ -s "$output" ]] && (( code == 0 )) && return 0

        printf '\r\033[K' >&2
        local reason="exit $code"; (( code == 124 )) && reason=timeout; (( code == 0 )) && reason="empty output"
        warn "$CLI" "attempt $attempt/$RETRIES: $reason"
        (( attempt < RETRIES )) && sleep 5
    done
    return 1
}

is_clean() { local s; s=$(tr -d '[:space:]*_\`#' <<< "$1"); [[ "$s" =~ \[PASS\] && ! "$s" =~ \[FAIL\] ]]; }
extract_tag() { grep -oE "\[$1\].*" "$2" 2>/dev/null | head -1 | sed "s/\[$1\][[:space:]]*//"; }

check_prompt() {
    if repo_mode; then cat <<EOF
Review this repository for bugs: logic errors, crashes, data loss, security flaws, resource leaks, race conditions, performance problems.
Consider overall purpose when evaluating correctness. Skip style, naming, refactoring opinions, speculative issues.
Report all instances of each bug pattern found.

Output: [PASS] if clean, or [FAIL] with:
filename.ext:line - description max 12 words (one per line, no full paths, no markdown)
EOF
    else cat <<EOF
<files>
$1
</files>

Review the listed files for bugs: logic errors, crashes, data loss, security flaws, resource leaks, race conditions, performance problems.
Consider overall purpose when evaluating correctness. Skip style, naming, refactoring opinions, speculative issues.
Report all instances of each bug pattern found.

Output: [PASS] if clean, or [FAIL] with:
filename.ext:line - description max 12 words (one per line, no full paths, no markdown)
EOF
    fi
}

fix_prompt() {
    if repo_mode; then cat <<EOF
<issues>
$1
</issues>

Fix each issue with minimal changes. Fix all occurrences of each bug pattern. Follow existing patterns. Do not remove unrelated code. Run tests to verify.

Output: [DONE] brief summary (max 10 words), or [BLOCKED] reason if unable.
EOF
    else cat <<EOF
<files>
$2
</files>

<issues>
$1
</issues>

Fix each issue with minimal changes. Fix all occurrences of each bug pattern. Follow existing patterns. Do not remove unrelated code. Run tests to verify.

Output: [DONE] brief summary (max 10 words), or [BLOCKED] reason if unable.
EOF
    fi
}

build_target() { repo_mode && return; if file_mode; then printf '%s\n' "${FILES[@]}"; else git diff --name-only "$BASE"...HEAD; fi; }

finish() {
    header Done
    say checkfix "$clean_count passes in $iter iteration(s) ($(($(now) - SCRIPT_START))s)"
    exit 0
}

run_fix() {
    local issues=$1 target=$2 start hash_before hash_after size_before size_after changed blocked summary verify_start
    PHASE=fix; progress fix starting 0
    start=$(now) hash_before=$(state_hash) size_before=$(diff_size)

    run_cli "$(fix_prompt "$issues" "$target")" "$LOG_DIR/fix_$iter.txt" || fatal "fix failed: CLI error"

    blocked=$(extract_tag BLOCKED "$LOG_DIR/fix_$iter.txt")
    [[ -n "$blocked" ]] && fatal "fix blocked: $blocked"

    hash_after=$(state_hash)
    if [[ "$hash_before" == "$hash_after" ]]; then
        summary=$(extract_tag DONE "$LOG_DIR/fix_$iter.txt")
        [[ -n "$summary" ]] && warn fix "CLI claimed: $summary"
        warn fix "no changes, re-verifying..."
        verify_start=$(now)
        PHASE=verify; progress verify starting 0
        if run_cli "$(check_prompt "$target")" "$LOG_DIR/verify_$iter.txt" && is_clean "$(<"$LOG_DIR/verify_$iter.txt")"; then
            ok verify "$(($(now) - verify_start))" "false positive"
            warn checkfix "issue was likely a false positive"
            return 1
        fi
        fatal "fix made no changes and issue persists"
    fi

    size_after=$(diff_size) changed=$(( size_after - size_before ))
    (( changed < 0 )) && changed=$(( -changed ))
    (( changed > 1000 )) && fatal "fix too large: exceeds 1000 line threshold"

    check_cycle
    ok fix "$(($(now) - start))" "$(extract_tag DONE "$LOG_DIR/fix_$iter.txt" || echo completed)"
    clean_count=0
}

mkdir -p "$LOG_DIR"
acquire_lock
header Checkfix
say checkfix "cli=$CLI max=$MAX_ITERS passes=$CLEAN_REQUIRED$($DRY_RUN && echo ' dry-run')"
if repo_mode; then
    git rev-parse --git-dir &>/dev/null || fatal "not a git repository"
    say checkfix "repo-wide"
elif file_mode; then
    say checkfix "${#FILES[@]} file(s): ${FILES[*]}"
else
    verify_repo
fi

iter=0 clean_count=0 SCRIPT_START=$(now)
SEEN_HASHES+=("$(state_hash)")

while (( ++iter <= MAX_ITERS )); do
    header "Iteration $iter/$MAX_ITERS"
    TARGET=$(build_target)
    PHASE=check; progress check starting 0
    start=$(now)

    run_cli "$(check_prompt "$TARGET")" "$LOG_DIR/check_$iter.txt" || fatal "check failed: CLI error after $RETRIES attempts"
    result=$(<"$LOG_DIR/check_$iter.txt") elapsed=$(($(now) - start))

    if ! is_clean "$result"; then
        fail check "$elapsed"; show_issues "$result"
        if ! run_fix "$result" "$TARGET"; then
            (( ++clean_count )); say progress "$clean_count/$CLEAN_REQUIRED consecutive passes (false positive)"
            (( clean_count >= CLEAN_REQUIRED )) && finish
        fi
        continue
    fi

    ok check "$elapsed" passed
    (( ++clean_count )); say progress "$clean_count/$CLEAN_REQUIRED consecutive passes"
    (( clean_count >= CLEAN_REQUIRED )) && finish
done

fatal "max iterations ($MAX_ITERS): check/fix cycle did not stabilize"
}
