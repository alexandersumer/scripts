#!/bin/bash
{
set -u -o pipefail

RESET='' RED='' GREEN='' YELLOW='' BOLD='' DIM=''
if [[ -t 1 || -t 2 ]] && [[ -z "${NO_COLOR:-}" ]] && command -v tput &>/dev/null && (( $(tput colors 2>/dev/null || echo 0) >= 8 )); then
    BOLD=$(tput bold) DIM=$(tput dim) RESET=$(tput sgr0)
    RED=$BOLD$(tput setaf 1) GREEN=$BOLD$(tput setaf 2) YELLOW=$BOLD$(tput setaf 3)
fi

say()      { printf '%s: %s\n' "$1" "$2" >&2; }
ok()       { printf '%s: %b%s%b [%ss]\n' "$1" "$GREEN" "${2:-done}" "$RESET" "$3" >&2; }
fail()     { printf '%s: %bfailed%b [%ss]\n' "$1" "$RED" "$RESET" "$2" >&2; }
warn()     { printf '%s: %b%s%b\n' "$1" "$YELLOW" "$2" "$RESET" >&2; }
fatal()    { printf 'zap: %b%s%b\n' "$RED" "$1" "$RESET" >&2; exit "${2:-1}"; }
progress() { printf '\r\033[K%s: %b%s%b [%ss]' "$1" "$([[ $2 == stalled ]] && echo "$YELLOW" || echo "$DIM")" "$2" "$RESET" "$3" >&2; }
now()      { date +%s; }

PRESETS="pr improve build clean check checkfix"
CLI_LIST="claude codex gemini rovo"

preset_prompt() {
    case "$1" in
        pr)      echo "Analyze the diff against main and write a brief PR description in one short paragraph explaining the core issue and fix rationale. Skip file lists, bullets, implementation details, and line references. Follow with a one-line summary under 10 words in lowercase without punctuation. Tone: neutral, idiomatic." ;;
        improve) echo "Analyze the diff against main and implement targeted, high-value improvements using robust, standard patterns. Ensure consistency and comprehensive test coverage. Keep the solution simple and self-documenting, strictly avoiding over-engineering and redundant comments." ;;
        build)   echo "Run the build and test suite to ensure all checks pass. Fix any failures by addressing the root cause. Keep the solution simple and robust, strictly avoiding brittle workarounds or error suppression." ;;
        clean)   echo "Refactor this code to be tighter and cleaner without sacrificing readability. Remove redundancy and fluff, simplify verbose expressions, but don't over-compress. Avoid unnecessary comments. Concise, not cryptic." ;;
        check)   echo "Review for bugs: logic errors, crashes, data loss, security flaws, resource leaks, race conditions, performance problems. Consider overall purpose when evaluating correctness. Skip style, naming, refactoring opinions, speculative issues. Report all instances of each bug pattern found. Output: [PASS] if clean, or [FAIL] with: filename.ext:line - description max 12 words (one per line, no full paths, no markdown)" ;;
        checkfix) echo "Review for bugs: logic errors, crashes, data loss, security flaws, resource leaks, race conditions, performance problems. Consider overall purpose when evaluating correctness. Skip style, naming, refactoring opinions, speculative issues. Fix each bug with minimal changes. Fix all occurrences of each bug pattern. Follow existing patterns. Do not remove unrelated code. Run tests to verify. Output: [PASS] if clean, [DONE] brief summary if fixed, or [BLOCKED] reason if unable." ;;
        *) return 1 ;;
    esac
}

cli_cmd() {
    case "$1" in
        claude) echo "claude --print" ;; codex) echo "codex exec" ;;
        gemini) echo "gemini" ;; rovo) echo "acli rovodev run" ;; *) return 1 ;;
    esac
}

for cmd in gtimeout timeout; do command -v $cmd &>/dev/null && { TIMEOUT_CMD=$cmd; break; }; done

TIMEOUT=300 RETRIES=2 STUCK_THRESHOLD=90
RAW=false CHILD_PID="" PROMPT="" FILES=()
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

Options:
    -l, --cli NAME       CLI to use (default: $CLI, available: $CLI_LIST)
    -f, --files FILE...  Target specific files instead of git diff
    -p, --prompt TEXT    Custom prompt (use - for stdin)
    -t, --timeout SECS   Timeout per call (default: $TIMEOUT)
    -r, --retries N      Retries on failure (default: $RETRIES)
    --raw                Output raw response without status messages
    --list               List available presets
    -h, --help           Show this help

Presets: $PRESETS

Examples:
    $(basename "$0") pr
    $(basename "$0") --files lib.py clean
    $(basename "$0") -p "Explain this code"
    echo "Review for bugs" | $(basename "$0") -p -
EOF
    exit 0
}

list_presets() {
    printf '%bAvailable presets:%b\n' "$BOLD" "$RESET"
    for name in $PRESETS; do printf '  %b%-12s%b %.60s...\n' "$GREEN" "$name" "$RESET" "$(preset_prompt "$name")"; done
    exit 0
}

require_int() { [[ "$2" =~ ^[1-9][0-9]*$ ]] || fatal "$1 must be a positive integer"; }
require_val() { [[ -n "${2:-}" && ! "$2" =~ ^- ]] || fatal "$1 requires a value"; }

PRESET=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -l|--cli) require_val "$1" "${2:-}"; cli_cmd "$2" >/dev/null || fatal "unknown CLI: $2"; CLI=$2; shift 2 ;;
        -f|--files)
            shift
            while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do
                [[ " $PRESETS " == *" $1 "* ]] && break
                [[ -e "$1" ]] || fatal "file not found: $1"
                [[ -f "$1" ]] || fatal "not a file: $1"
                [[ -r "$1" ]] || fatal "file not readable: $1"
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
        --list) list_presets ;;
        -h|--help) usage ;;
        -*) fatal "unknown option: $1" ;;
        *) [[ -n "$PRESET" ]] && fatal "unexpected argument: $1"; PRESET=$1; shift ;;
    esac
done

if [[ -n "$PRESET" && -n "$PROMPT" ]]; then
    fatal "cannot use both preset and --prompt"
elif [[ -n "$PRESET" ]]; then
    PROMPT=$(preset_prompt "$PRESET") || fatal "unknown preset: $PRESET (use --list to see available)"
elif [[ -z "$PROMPT" ]]; then
    fatal "missing preset or --prompt (use --help for usage)"
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
        local upstream=$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)
        [[ -n "$upstream" ]] && has_changes "$upstream"...HEAD && BASE=$upstream
    fi
    [[ -z "$BASE" ]] && fatal "no base branch found: ensure main/master exists or use --files"

    has_changes "$BASE"...HEAD || has_changes HEAD || has_changes --cached || fatal "no changes detected: nothing to analyze"
    $RAW || say zap "$BRANCH → $BASE"
}

build_context() {
    if (( ${#FILES[@]} )); then
        printf '<files>\n'
        for f in "${FILES[@]}"; do printf '=== %s ===\n%s\n' "$f" "$(cat -- "$f")"; done
        printf '</files>\n'
    else
        printf '<diff>\n%s\n</diff>\n' "$(git diff "$(git merge-base "$BASE" HEAD)")"
    fi
}

is_stuck() {
    [[ -f "$1" ]] || return 1
    local c=$(tail -20 "$1" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    [[ "$c" =~ (allow|permit|approve|confirm|continue|proceed).*(y/n|\[y\]|yes.*no|\?) || "$c" =~ [\(\[]y/?n[\)\]] ]]
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

(( ${#FILES[@]} )) && { $RAW || say zap "${#FILES[@]} file(s)"; } || verify_repo

TMPFILE=$(mktemp) || fatal "cannot create temp file"
START=$(now)

if ! run_cli "$(build_context)"$'\n\n'"$PROMPT" "$TMPFILE"; then
    fail zap "$(($(now) - START))"
    exit 1
fi

$RAW || ok zap completed "$(($(now) - START))"
cat "$TMPFILE"
}
