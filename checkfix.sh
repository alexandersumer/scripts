#!/bin/bash
{
set -u -o pipefail
source "$(dirname "$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")")/common/agentcli.sh"

header() { printf '\n%b──────────────────────%b\n%b%s%b\n' "$DIM" "$RESET" "$BOLD" "$1" "$RESET" >&2; }
show_issues() {
    [[ -z "$1" ]] && return
    local lines count
    lines=$(grep -E '[a-zA-Z0-9_/-]+\.[a-zA-Z]+:[0-9]+' <<< "$1") || true
    count=${lines:+$(wc -l <<< "$lines")}; count=${count:-0}
    if [[ -z "$lines" ]]; then
        printf '%b%s%b\n' "$DIM" "$(head -5 <<< "$1" | sed 's/^/  /')" "$RESET" >&2
    else
        printf '%b%s%b\n' "$DIM" "$(head -10 <<< "$lines" | sed 's/^/  /')" "$RESET" >&2
        (( count > 10 )) && printf '%b  ...+%d more%b\n' "$DIM" "$((count - 10))" "$RESET" >&2
    fi
}

for cmd in "shasum -a 256" sha256sum md5sum "md5 -r" cksum; do
    command -v "${cmd%% *}" &>/dev/null && { HASH_CMD=$cmd; break; }
done
[[ -z "${HASH_CMD:-}" ]] && fatal "no hash command"
hash_str() { printf '%s' "$1" | $HASH_CMD | cut -c1-16; }

LOCK_ID=$(hash_str "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
LOCK_DIR="/tmp/checkfix-${LOCK_ID}.lock" LOCK_PID="$LOCK_DIR/pid"
LOG_DIR="/tmp/checkfix-${LOCK_ID}-$$"
MAX_ITERS=15 CLEAN_REQUIRED=3 RETRIES=2 TIMEOUT=1200
DRY_RUN=false REPO=false CHILD_PID="" PHASE="" FILES=() SEEN_HASHES=()
CUSTOM_CHECK="" CUSTOM_FIX=""
CLI="${CHECKFIX_CLI:-claude}"
[[ -n "${CHECKFIX_CLI:-}" ]] && ! cli_cmd "$CLI" >/dev/null && fatal "unknown CLI: $CLI ($CLI_LIST)"

file_mode() { (( ${#FILES[@]} )); }
repo_mode() { $REPO; }
state_hash() {
    if repo_mode; then hash_str "$(git ls-files -z | xargs -0 cat 2>/dev/null)"
    elif file_mode; then hash_str "$(cat "${FILES[@]}")"
    else hash_str "$(git diff "$BASE"...HEAD)"; fi
}
diff_size() {
    if repo_mode; then git ls-files -z | xargs -0 wc -l 2>/dev/null | tail -1 | awk '{print $1+0}'
    elif file_mode; then wc -l < <(cat "${FILES[@]}") | tr -d ' '
    else git diff --numstat "$BASE"...HEAD 2>/dev/null | awk '{s+=$1+$2} END {print s+0}'; fi
}
check_cycle() {
    local hash i=0; hash=$(state_hash)
    for seen in "${SEEN_HASHES[@]}"; do
        [[ "$seen" == "$hash" ]] && fatal "cycle: matches $( (( i )) && echo "iter $i" || echo initial)"
        ((i++))
    done
    SEEN_HASHES+=("$hash")
}

usage() { cat <<EOF
Usage: ${0##*/} [OPTIONS] [--files FILE...]
Modes: Git (diff vs main), File (--files), Repo (--repo)
  -l, --cli NAME        CLI ($CLI_LIST; default: $CLI)
  -f, --files FILE...   Check specific files
  -R, --repo            Explore entire repo
  -m, --max-iterations  Max iterations (default: $MAX_ITERS)
  -c, --consecutive     Passes needed (default: $CLEAN_REQUIRED)
  -r, --retries         Retries per call (default: $RETRIES)
  -t, --timeout SECS    Timeout per call (default: $TIMEOUT)
  -C, --check-prompt P  Custom check prompt (- for stdin)
  -F, --fix-prompt P    Custom fix prompt (- for stdin)
  --dry-run             Skip CLI calls
  -h, --help            Show help
EOF
exit 0; }

while (( $# )); do
    case $1 in
        -l|--cli) require_val "$1" "${2:-}"; cli_cmd "$2" >/dev/null || fatal "unknown CLI: $2"; CLI=$2; shift 2 ;;
        -f|--files) shift
            while (( $# )) && [[ "$1" != -* ]]; do
                [[ -f "$1" && -r "$1" ]] || fatal "file not found: $1"
                FILES+=("$(realpath "$1")"); shift
            done
            (( ${#FILES[@]} )) || fatal "--files requires file" ;;
        -m|--max-iterations) require_val "$1" "${2:-}"; require_int "$1" "$2"; MAX_ITERS=$2; shift 2 ;;
        -c|--consecutive) require_val "$1" "${2:-}"; require_int "$1" "$2"; CLEAN_REQUIRED=$2; shift 2 ;;
        -r|--retries) require_val "$1" "${2:-}"; require_int "$1" "$2"; RETRIES=$2; shift 2 ;;
        -t|--timeout) require_val "$1" "${2:-}"; require_int "$1" "$2"; TIMEOUT=$2; shift 2 ;;
        -C|--check-prompt) require_val "$1" "${2:-}"; [[ "$2" == "-" ]] && CUSTOM_CHECK=$(cat) || CUSTOM_CHECK=$2; shift 2 ;;
        -F|--fix-prompt) require_val "$1" "${2:-}"; [[ "$2" == "-" ]] && CUSTOM_FIX=$(cat) || CUSTOM_FIX=$2; shift 2 ;;
        -R|--repo) REPO=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage ;;
        *) fatal "unknown option: $1" ;;
    esac
done

$REPO && (( ${#FILES[@]} )) && fatal "--repo and --files are mutually exclusive"
CLI_CMD=$(cli_cmd "$CLI")
[[ -n "${CHECKFIX_CLI_CMD:-}" ]] && CLI_CMD=$CHECKFIX_CLI_CMD CLI=custom
command -v "${CLI_CMD%% *}" &>/dev/null || fatal "$CLI not found"

# shellcheck disable=SC2317,SC2329
cleanup() {
    local code=$?; trap - EXIT
    [[ -n "$CHILD_PID" ]] && kill "$CHILD_PID" 2>/dev/null
    [[ -f "$LOCK_PID" && "$(<"$LOCK_PID")" == "$$" ]] && rm -rf "$LOCK_DIR"
    if (( code )); then say checkfix "logs: $LOG_DIR"; else rm -rf "$LOG_DIR"; fi
    exit "$code"
}
trap 'printf "\n" >&2; warn checkfix interrupted; cleanup' INT TERM
trap cleanup EXIT

acquire_lock() {
    local attempt=0 tmp pid; tmp=$(mktemp) || fatal "mktemp failed"; echo "$$" > "$tmp"
    while (( ++attempt <= 5 )); do
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            mv "$tmp" "$LOCK_PID" 2>/dev/null && return 0
            rm -rf "$LOCK_DIR" "$tmp"; fatal "cannot install PID file"
        fi
        pid=$(<"$LOCK_PID" 2>/dev/null)
        [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && { rm -f "$tmp"; fatal "running (PID $pid)"; }
        rm -rf "$LOCK_DIR" 2>/dev/null; sleep 0.1 2>/dev/null || sleep 1
    done
    rm -f "$tmp"; fatal "cannot acquire lock"
}

verify_repo() {
    git rev-parse --git-dir &>/dev/null || fatal "not a git repo: use --files"
    BRANCH=$(git rev-parse --abbrev-ref HEAD)
    [[ "$BRANCH" =~ ^(main|master)$ ]] && fatal "on protected branch '$BRANCH'"
    BASE=$(find_base) || fatal "no base branch: ensure main/master exists or use --files"
    has_changes "$BASE"...HEAD || has_changes HEAD || has_changes --cached \
        || fatal "no changes to check"
    say checkfix "$BRANCH → $BASE"
}

run_cli() {
    local prompt=$1 output=$2 start last_size last_change elapsed size status code
    read -ra cmd <<< "$CLI_CMD"
    for (( attempt=1; attempt<=RETRIES; attempt++ )); do
        $DRY_RUN && { echo "[PASS] Dry run" > "$output"; return 0; }
        start=$(now) last_size=0 last_change=$start; : > "$output"
        if [[ -n "${TIMEOUT_CMD:-}" ]]; then
            printf '%s' "$prompt" | "$TIMEOUT_CMD" "${TIMEOUT}s" "${cmd[@]}" > "$output" 2>&1 &
        else printf '%s' "$prompt" | "${cmd[@]}" > "$output" 2>&1 & fi
        CHILD_PID=$!
        while kill -0 "$CHILD_PID" 2>/dev/null; do
            sleep 1; elapsed=$(($(now) - start)); size=$(wc -c < "$output" 2>/dev/null || echo 0)
            status=active
            if [[ -z "${TIMEOUT_CMD:-}" ]] && (( elapsed >= TIMEOUT )); then
                kill "$CHILD_PID" 2>/dev/null; wait "$CHILD_PID" 2>/dev/null; CHILD_PID=""; return 1
            fi
            if (( size > last_size )); then last_size=$size last_change=$(now)
            elif (( $(now) - last_change >= 90 )); then
                is_stuck "$output" && { printf '\n' >&2; fatal "CLI blocked on permission prompt"; }
                status=stalled
            fi
            progress "$PHASE" "$status" "$elapsed"
        done
        wait "$CHILD_PID" 2>/dev/null; code=$?; CHILD_PID=""
        [[ -s "$output" ]] && (( code == 0 )) && return 0
        printf '\r\033[K' >&2
        local reason="exit $code"
        (( code == 124 )) && reason=timeout; (( code == 0 )) && reason="empty output"
        warn "$CLI" "attempt $attempt/$RETRIES: $reason"
        (( attempt < RETRIES )) && { [[ -s "$output" ]] && head -5 "$output" >&2; sleep 5; }
    done
    return 1
}

is_clean() { local s=${1//[[:space:]*_\`#]/}; [[ "$s" =~ \[PASS\] && ! "$s" =~ \[FAIL\] ]]; }
extract_tag() { grep -oE "\[$1\].*" "$2" 2>/dev/null | head -1 | sed "s/\[$1\][[:space:]]*//"; }

DEFAULT_CHECK='Read files first. Review for bugs: logic errors, crashes, data loss, security flaws, resource leaks, races.
Skip style, naming, refactoring opinions, speculative issues. Report all instances of each bug pattern.'
CHECK_FORMAT='Output: [PASS] if clean, or [FAIL] with: filename.ext:line - "quoted code" - issue (max 12 words, one per line)'
CHECK_BODY="${CUSTOM_CHECK:-$DEFAULT_CHECK}"$'\n'"$CHECK_FORMAT"

check_prompt() {
    if repo_mode; then printf '%s\n' "$CHECK_BODY"
    else printf '<files>\n%s\n</files>\n\n%s\n' "$1" "$CHECK_BODY"; fi
}

DEFAULT_FIX='Fix each issue minimally. Fix all occurrences. Follow existing patterns. Run tests.'
FIX_FORMAT='Output: [DONE] brief summary (max 10 words), or [BLOCKED] reason.'
FIX_BODY="${CUSTOM_FIX:-$DEFAULT_FIX}"$'\n'"$FIX_FORMAT"

fix_prompt() {
    if repo_mode; then printf '<issues>\n%s\n</issues>\n\n%s\n' "$1" "$FIX_BODY"
    else printf '<files>\n%s\n</files>\n\n<issues>\n%s\n</issues>\n\n%s\n' "$2" "$1" "$FIX_BODY"; fi
}

build_target() {
    repo_mode && return
    if file_mode; then printf '%s\n' "${FILES[@]}"; else git diff --name-only "$BASE"...HEAD; fi
}

finish() {
    header Done
    say checkfix "$clean_count passes in $iter iter ($(($(now) - SCRIPT_START))s)"
    exit 0
}

run_fix() {
    local issues=$1 target=$2 start hash_before hash_after size_before delta
    PHASE=fix; progress fix starting 0
    start=$(now) hash_before=$(state_hash) size_before=$(diff_size)
    run_cli "$(fix_prompt "$issues" "$target")" "$LOG_DIR/fix_$iter.txt" || fatal "fix failed"
    local blocked; blocked=$(extract_tag BLOCKED "$LOG_DIR/fix_$iter.txt")
    [[ -n "$blocked" ]] && fatal "fix blocked: $blocked"
    hash_after=$(state_hash)
    if [[ "$hash_before" == "$hash_after" ]]; then
        local summary; summary=$(extract_tag DONE "$LOG_DIR/fix_$iter.txt")
        [[ -n "$summary" ]] && warn fix "CLI claimed: $summary"
        warn fix "no changes, re-verifying..."
        local vstart; vstart=$(now); PHASE=verify; progress verify starting 0
        if run_cli "$(check_prompt "$target")" "$LOG_DIR/verify_$iter.txt" && \
           is_clean "$(<"$LOG_DIR/verify_$iter.txt")"; then
            ok verify "$(($(now) - vstart))" "false positive"
            warn checkfix "likely false positive"; return 1
        fi
        fatal "fix made no changes, issue persists"
    fi
    delta=$(( $(diff_size) - size_before ))
    (( delta < 0 )) && delta=$(( -delta ))
    (( delta > 1000 )) && fatal "fix too large (>1000 lines)"
    check_cycle
    ok fix "$(($(now) - start))" "$(extract_tag DONE "$LOG_DIR/fix_$iter.txt" || echo fixed)"
    clean_count=0
}

mkdir -p "$LOG_DIR"; acquire_lock; header Checkfix
say checkfix "cli=$CLI max=$MAX_ITERS passes=$CLEAN_REQUIRED$($DRY_RUN && echo ' dry-run')"
if repo_mode; then git rev-parse --git-dir &>/dev/null || fatal "not a git repo"; say checkfix "repo-wide"
elif file_mode; then say checkfix "${#FILES[@]} file(s): ${FILES[*]}"
else verify_repo; fi

iter=0 clean_count=0 SCRIPT_START=$(now); SEEN_HASHES+=("$(state_hash)")

while (( ++iter <= MAX_ITERS )); do
    header "Iteration $iter/$MAX_ITERS"
    TARGET=$(build_target); PHASE=check; progress check starting 0; start=$(now)
    run_cli "$(check_prompt "$TARGET")" "$LOG_DIR/check_$iter.txt" || fatal "check failed after $RETRIES attempts"
    result=$(<"$LOG_DIR/check_$iter.txt"); elapsed=$(($(now) - start))
    if ! is_clean "$result"; then
        fail check "$elapsed"; show_issues "$result"
        if ! run_fix "$result" "$TARGET"; then
            (( ++clean_count )); say progress "$clean_count/$CLEAN_REQUIRED passes (false positive)"
            (( clean_count >= CLEAN_REQUIRED )) && finish
        fi
        continue
    fi
    ok check "$elapsed" passed
    (( ++clean_count )); say progress "$clean_count/$CLEAN_REQUIRED passes"
    (( clean_count >= CLEAN_REQUIRED )) && finish
done
fatal "max iterations ($MAX_ITERS): cycle did not stabilize"
}
