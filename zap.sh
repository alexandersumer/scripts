#!/bin/bash
{
set -u -o pipefail
source "$(dirname "$0")/common/agentcli.sh"

PRESETS="pr build tighten check checkfix resolve"
PROMPT_DEFAULTS="If modifying code: be minimal, follow existing patterns, avoid redundancy."

preset_prompt() {
    local preset=$1 repo=${2:-false} t
    case "$preset" in
        pr) cat <<'END'
Analyze diff vs main. Write brief PR description: one paragraph on core issue and fix
rationale. Skip file lists, bullets, implementation details, line refs. Follow with
one-line summary under 10 words, lowercase, no punctuation. Neutral tone.
END
            ;;
        build) echo "Run build and tests. Fix failures at root cause. Keep fixes simple." ;;
        tighten)
            t="this code"; $repo && t="the codebase"
            echo "Tighten $t. Remove redundancy, simplify verbose expressions, cut unnecessary comments. Keep lines reasonable length. Concise, not cryptic." ;;
        check) cat <<'END'
Review for bugs: logic errors, crashes, data loss, security flaws, resource leaks, races.
Skip style/naming opinions. Report all instances. Output: [PASS] if clean, or [FAIL]
with: file.ext:line - "quoted code" - issue (max 12 words, one per line, no markdown)
END
            ;;
        checkfix) cat <<'END'
Read files first. Review for bugs: logic errors, crashes, data loss, security flaws,
resource leaks, races. Skip style/naming opinions. If bugs found, fix each minimally,
all occurrences, follow existing patterns, run tests. Output: [PASS], [DONE], or [BLOCKED].
END
            ;;
        resolve) echo "Resolve merge conflicts. Preserve branch intent. Remove all conflict markers." ;;
        *) return 1 ;;
    esac
}

TIMEOUT=1200 RETRIES=2 RAW=false REPO=false CHILD_PID="" PROMPT="" FILES=()
CLI="${ZAP_CLI:-claude}"
[[ -n "${ZAP_CLI:-}" ]] && ! cli_cmd "$CLI" >/dev/null && fatal "unknown CLI: $CLI ($CLI_LIST)"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] PRESET | -p "prompt"

Modes:  Git (default: diff vs main), File (--files), Repo (--repo)

Options:
  -l, --cli NAME       CLI to use (default: $CLI; $CLI_LIST)
  -f, --files FILE...  Target specific files
  -R, --repo           Let CLI explore entire repo
  -p, --prompt TEXT    Custom prompt (- for stdin)
  -t, --timeout SECS   Timeout per call (default: $TIMEOUT)
  -r, --retries N      Retries on failure (default: $RETRIES)
  --raw                Raw output, no status
  --list               List presets
  -h, --help           Show help

Presets: $PRESETS
EOF
    exit 0
}

list_presets() {
    printf '%bPresets:%b\n' "$BOLD" "$RESET"
    for p in $PRESETS; do printf '  %b%-10s%b %.60s...\n' "$GREEN" "$p" "$RESET" "$(preset_prompt "$p")"; done
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

$REPO && (( ${#FILES[@]} )) && fatal "--repo and --files are mutually exclusive"
[[ -n "$PRESET" && -n "$PROMPT" ]] && fatal "preset and --prompt are mutually exclusive"

if [[ -n "$PRESET" ]]; then
    $REPO && [[ "$PRESET" =~ ^(pr|resolve)$ ]] && fatal "'$PRESET' requires diff context"
    PROMPT=$(preset_prompt "$PRESET" "$REPO") || fatal "unknown preset: $PRESET"
elif [[ -n "$PROMPT" ]]; then
    PROMPT="$PROMPT"$'\n\n'"$PROMPT_DEFAULTS"
else
    fatal "missing preset or --prompt"
fi

if [[ "$PRESET" == "resolve" ]] && ! $REPO && (( ! ${#FILES[@]} )); then
    git rev-parse MERGE_HEAD &>/dev/null || fatal "not in merge conflict state"
    root=$(git rev-parse --show-toplevel)
    while IFS= read -r f; do [[ -n "$f" ]] && FILES+=("$root/$f"); done \
        < <(git diff --name-only --diff-filter=U)
    (( ${#FILES[@]} )) || fatal "no conflicted files"
fi

CLI_CMD=$(cli_cmd "$CLI")
[[ -n "${ZAP_CLI_CMD:-}" ]] && CLI_CMD=$ZAP_CLI_CMD CLI=custom
command -v "${CLI_CMD%% *}" &>/dev/null || fatal "$CLI not found"

cleanup() { [[ -n "$CHILD_PID" ]] && kill "$CHILD_PID" 2>/dev/null; rm -f "${TMPFILE:-}"; }
trap 'printf "\n" >&2; warn zap interrupted; cleanup; exit 130' INT TERM
trap cleanup EXIT

verify_repo() {
    git rev-parse --git-dir &>/dev/null || fatal "not a git repo; use --files"
    BRANCH=$(git rev-parse --abbrev-ref HEAD)
    BASE=$(find_base) || fatal "no base branch; ensure main/master exists or use --files"
    has_changes "$BASE"...HEAD || has_changes HEAD || has_changes --cached \
        || fatal "no changes to analyze"
    $RAW || say zap "$BRANCH → $BASE"
}

build_context() {
    $REPO && return
    if (( ${#FILES[@]} )); then
        if [[ "$PRESET" == "resolve" ]]; then
            local merge_base; merge_base=$(git merge-base HEAD MERGE_HEAD 2>/dev/null)
            [[ -n "$merge_base" ]] && printf '<branch-diff>\n%s\n</branch-diff>\n' "$(git diff "$merge_base" HEAD -- "${FILES[@]}" 2>/dev/null)"
        fi
        printf '<files>\n'
        for f in "${FILES[@]}"; do printf '=== %s ===\n%s\n' "$f" "$(cat "$f")"; done
        printf '</files>\n'
    else printf '<diff>\n%s\n</diff>\n' "$(git diff "$(git merge-base "$BASE" HEAD)")"; fi
}

run_cli() {
    local prompt=$1 output=$2 start last_size last_change elapsed size status code
    read -ra cmd <<< "$CLI_CMD"
    for (( attempt=1; attempt<=RETRIES; attempt++ )); do
        start=$(now) last_size=0 last_change=$start code=1; : > "$output"
        if [[ -n "${TIMEOUT_CMD:-}" ]]; then
            printf '%s' "$prompt" | "$TIMEOUT_CMD" "${TIMEOUT}s" "${cmd[@]}" > "$output" 2>&1 &
        else printf '%s' "$prompt" | "${cmd[@]}" > "$output" 2>&1 & fi
        CHILD_PID=$!
        while kill -0 "$CHILD_PID" 2>/dev/null; do
            sleep 1; elapsed=$(($(now) - start)); size=$(wc -c < "$output" 2>/dev/null || echo 0)
            status=active
            if [[ -z "${TIMEOUT_CMD:-}" ]] && (( elapsed >= TIMEOUT )); then
                kill "$CHILD_PID" 2>/dev/null; wait "$CHILD_PID" 2>/dev/null; CHILD_PID=""; code=124; break
            fi
            if (( size > last_size )); then last_size=$size last_change=$(now)
            elif (( $(now) - last_change >= 90 )); then
                is_stuck "$output" && { printf '\n' >&2; fatal "CLI blocked on permission prompt"; }
                status=stalled
            fi
            $RAW || progress zap "$status" "$elapsed"
        done
        [[ -n "$CHILD_PID" ]] && { wait "$CHILD_PID" 2>/dev/null; code=$?; CHILD_PID=""; }
        $RAW || printf '\r\033[K' >&2
        [[ -s "$output" ]] && (( code == 0 )) && return 0
        local reason="exit $code"
        (( code == 124 )) && reason=timeout; (( code == 0 )) && reason="empty output"
        $RAW || warn "$CLI" "attempt $attempt/$RETRIES: $reason"
        [[ -s "$output" ]] && ! $RAW && head -5 "$output" >&2
        (( attempt < RETRIES )) && sleep 3
    done
    return 1
}

if $REPO; then git rev-parse --git-dir &>/dev/null || fatal "not a git repo"; $RAW || say zap "repo-wide"
elif (( ${#FILES[@]} )); then $RAW || say zap "${#FILES[@]} file(s)"
else verify_repo; fi

TMPFILE=$(mktemp) || fatal "cannot create temp file"
START=$(now)
if ! run_cli "$(build_context)"$'\n\n'"$PROMPT" "$TMPFILE"; then
    fail zap "$(($(now) - START))"
    [[ -s "$TMPFILE" ]] && cat "$TMPFILE"
    exit 1
fi
$RAW || ok zap "$(($(now) - START))" completed
cat "$TMPFILE"
}
