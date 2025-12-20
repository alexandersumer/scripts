#!/bin/bash
{
set -u -o pipefail
source "$(dirname "$0")/lib/agentcli.sh"

PRESETS="pr build tighten check checkfix resolve"
PROMPT_DEFAULTS="If modifying code: be minimal, follow existing patterns, avoid redundancy and unnecessary comments."

preset_prompt() {
    local preset=$1 repo=${2:-false}
    case "$preset" in
        pr)      echo "Analyze the diff against main and write a brief PR description in one short paragraph explaining the core issue and fix rationale. Skip file lists, bullets, implementation details, and line references. Follow with a one-line summary under 10 words in lowercase without punctuation. Tone: neutral, idiomatic." ;;
        build)   echo "Run the build and test suite to ensure all checks pass. Fix any failures by addressing the root cause. Keep the solution simple and robust, strictly avoiding brittle workarounds or error suppression." ;;
        tighten) local t="this code"; $repo && t="the codebase"; echo "Tighten $t. Remove redundancy, simplify verbose expressions, cut unnecessary comments. Keep lines reasonable length. Concise, not cryptic." ;;
        check)   echo "Review for bugs: logic errors, crashes, data loss, security flaws, resource leaks, race conditions, performance problems. Consider overall purpose when evaluating correctness. Skip style, naming, refactoring opinions, speculative issues. Report all instances of each bug pattern found. Output: [PASS] if clean, or [FAIL] with: filename.ext:line - description max 12 words (one per line, no full paths, no markdown)" ;;
        checkfix) echo "Review for bugs: logic errors, crashes, data loss, security flaws, resource leaks, race conditions, performance problems. Consider overall purpose when evaluating correctness. Skip style, naming, refactoring opinions, speculative issues. Fix each bug with minimal changes. Fix all occurrences of each bug pattern. Follow existing patterns. Do not remove unrelated code. Run tests to verify. Output: [PASS] if clean, [DONE] brief summary if fixed, or [BLOCKED] reason if unable." ;;
        resolve) echo "Resolve merge conflicts with main. Preserve the branch's intent while incorporating updates from main. Remove all conflict markers." ;;
        *) return 1 ;;
    esac
}

TIMEOUT=300 RETRIES=2 STUCK_THRESHOLD=90
RAW=false REPO=false CHILD_PID="" PROMPT="" FILES=()
CLI="${ZAP_CLI:-claude}"
[[ -n "${ZAP_CLI:-}" ]] && ! cli_cmd "$CLI" >/dev/null && fatal "unknown CLI: $CLI (available: $CLI_LIST)"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] PRESET
       $(basename "$0") [OPTIONS] -p "prompt"

Run a single prompt against code context.

Modes:
    Git mode (default):  Analyze branch diff against main/master
    File mode:           Analyze specific files with --files
    Repo mode:           Let CLI explore entire repo with --repo

Options:
    -l, --cli NAME       CLI to use (default: $CLI, available: $CLI_LIST)
    -f, --files FILE...  Target specific files instead of git diff
    -R, --repo           Run prompt repo-wide (CLI explores on its own)
    -p, --prompt TEXT    Custom prompt (use - for stdin)
    -t, --timeout SECS   Timeout per call (default: $TIMEOUT)
    -r, --retries N      Retries on failure (default: $RETRIES)
    --raw                Output raw response without status messages
    --list               List available presets
    -h, --help           Show this help

Presets: $PRESETS

Examples:
    $(basename "$0") pr
    $(basename "$0") --files lib.py tighten
    $(basename "$0") --repo -p "Find security issues"
    echo "Review for bugs" | $(basename "$0") -p -
EOF
    exit 0
}

list_presets() {
    printf '%bAvailable presets:%b\n' "$BOLD" "$RESET"
    for name in $PRESETS; do printf '  %b%-12s%b %.60s...\n' "$GREEN" "$name" "$RESET" "$(preset_prompt "$name")"; done
    exit 0
}

PRESET=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -l|--cli) require_val "$1" "${2:-}"; cli_cmd "$2" >/dev/null || fatal "unknown CLI: $2"; CLI=$2; shift 2 ;;
        -f|--files)
            shift
            while [[ $# -gt 0 && ! "$1" =~ ^- && ! " $PRESETS " == *" $1 "* ]]; do
                [[ -f "$1" && -r "$1" ]] || fatal "cannot read file: $1"
                FILES+=("$(realpath "$1")"); shift
            done
            (( ${#FILES[@]} )) || fatal "--files requires at least one file" ;;
        -p|--prompt)
            require_val "$1" "${2:-}"
            [[ "$2" == "-" ]] && PROMPT=$(cat) || PROMPT=$2
            shift 2 ;;
        -t|--timeout) require_val "$1" "${2:-}"; require_int "$1" "$2"; TIMEOUT=$2; shift 2 ;;
        -r|--retries) require_val "$1" "${2:-}"; require_int "$1" "$2"; RETRIES=$2; shift 2 ;;
        --raw) RAW=true; shift ;;
        -R|--repo) REPO=true; shift ;;
        --list) list_presets ;;
        -h|--help) usage ;;
        -*) fatal "unknown option: $1" ;;
        *) [[ -n "$PRESET" ]] && fatal "unexpected argument: $1"; PRESET=$1; shift ;;
    esac
done

$REPO && (( ${#FILES[@]} )) && fatal "cannot use both --repo and --files"

if [[ -n "$PRESET" && -n "$PROMPT" ]]; then
    fatal "cannot use both preset and --prompt"
elif [[ -n "$PRESET" ]]; then
    $REPO && [[ "$PRESET" =~ ^(pr|resolve)$ ]] && fatal "preset '$PRESET' requires diff context; use -p or a repo-compatible preset"
    PROMPT=$(preset_prompt "$PRESET" "$REPO") || fatal "unknown preset: $PRESET (use --list to see available)"
elif [[ -n "$PROMPT" ]]; then
    PROMPT="$PROMPT"$'\n\n'"$PROMPT_DEFAULTS"
else
    fatal "missing preset or --prompt (use --help for usage)"
fi

if [[ "$PRESET" == "resolve" ]] && ! $REPO && (( ! ${#FILES[@]} )); then
    git rev-parse MERGE_HEAD &>/dev/null || fatal "not in merge conflict state (run git merge first)"
    root=$(git rev-parse --show-toplevel)
    while IFS= read -r f; do
        [[ -n "$f" ]] && FILES+=("$root/$f")
    done < <(git diff --name-only --diff-filter=U)
    (( ${#FILES[@]} )) || fatal "no conflicted files found"
fi

CLI_CMD=$(cli_cmd "$CLI")
[[ -n "${ZAP_CLI_CMD:-}" ]] && CLI_CMD=$ZAP_CLI_CMD CLI=custom
command -v "${CLI_CMD%% *}" &>/dev/null || fatal "$CLI not found in PATH"

cleanup() {
    [[ -n "$CHILD_PID" ]] && kill "$CHILD_PID" 2>/dev/null
    [[ -n "${TMPFILE:-}" ]] && rm -f "$TMPFILE"
}
trap 'printf "\n" >&2; warn zap interrupted; cleanup; exit 130' INT TERM
trap cleanup EXIT

has_changes() { ! git diff --quiet "$@" 2>/dev/null; }

verify_repo() {
    git rev-parse --git-dir &>/dev/null || fatal "not a git repository: use --files for standalone files"
    BRANCH=$(git rev-parse --abbrev-ref HEAD)

    BASE=""
    for b in main master; do git rev-parse --verify "$b" &>/dev/null && { BASE=$b; break; }; done
    if [[ -z "$BASE" ]] || ! has_changes "$BASE"...HEAD; then
        local upstream; upstream=$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null) || true
        [[ -n "$upstream" ]] && has_changes "$upstream"...HEAD && BASE=$upstream
    fi
    [[ -z "$BASE" ]] && fatal "no base branch found: ensure main/master exists or use --files"

    has_changes "$BASE"...HEAD || has_changes HEAD || has_changes --cached || fatal "no changes detected: nothing to analyze"
    $RAW || say zap "$BRANCH → $BASE"
}

build_context() {
    $REPO && return
    if (( ${#FILES[@]} )); then
        printf '<files>\n'
        for f in "${FILES[@]}"; do printf '=== %s ===\n%s\n' "$f" "$(cat -- "$f")"; done
        printf '</files>\n'
    else
        printf '<diff>\n%s\n</diff>\n' "$(git diff "$(git merge-base "$BASE" HEAD)")"
    fi
}

run_cli() {
    local prompt=$1 output=$2 start last_size last_change elapsed size status code
    read -ra cmd <<< "$CLI_CMD"

    for (( attempt=1; attempt<=RETRIES; attempt++ )); do
        start=$(now) last_size=0 last_change=$start
        : > "$output"

        if [[ -n "${TIMEOUT_CMD:-}" ]]; then printf '%s' "$prompt" | "$TIMEOUT_CMD" "${TIMEOUT}s" "${cmd[@]}" > "$output" 2>&1 &
        else printf '%s' "$prompt" | "${cmd[@]}" > "$output" 2>&1 & fi
        CHILD_PID=$!

        while kill -0 "$CHILD_PID" 2>/dev/null; do
            sleep 1
            elapsed=$(($(now) - start))
            size=$(wc -c < "$output" 2>/dev/null || echo 0)
            status=active

            [[ -z "${TIMEOUT_CMD:-}" ]] && (( elapsed >= TIMEOUT )) && { kill "$CHILD_PID" 2>/dev/null; wait "$CHILD_PID" 2>/dev/null; CHILD_PID=""; return 1; }

            if (( size > last_size )); then
                last_size=$size last_change=$(now)
            elif (( $(now) - last_change >= STUCK_THRESHOLD )); then
                is_stuck "$output" && { printf '\n' >&2; fatal "CLI blocked on permission prompt"; }
                status=stalled
            fi
            $RAW || progress zap "$status" "$elapsed"
        done

        wait "$CHILD_PID" 2>/dev/null; code=$?
        CHILD_PID=""
        $RAW || printf '\r\033[K' >&2

        [[ -s "$output" ]] && (( code == 0 )) && return 0

        local reason="exit $code"; (( code == 124 )) && reason=timeout; (( code == 0 )) && reason="empty output"
        $RAW || warn "$CLI" "attempt $attempt/$RETRIES: $reason"
        (( attempt < RETRIES )) && sleep 3
    done
    return 1
}

if $REPO; then
    git rev-parse --git-dir &>/dev/null || fatal "not a git repository"
    $RAW || say zap "repo-wide"
elif (( ${#FILES[@]} )); then
    $RAW || say zap "${#FILES[@]} file(s)"
else
    verify_repo
fi

TMPFILE=$(mktemp) || fatal "cannot create temp file"
START=$(now)

if ! run_cli "$(build_context)"$'\n\n'"$PROMPT" "$TMPFILE"; then
    fail zap "$(($(now) - START))"
    exit 1
fi

$RAW || ok zap "$(($(now) - START))" completed
cat "$TMPFILE"
}
