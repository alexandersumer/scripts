# shellcheck shell=bash
# shellcheck disable=SC2034  # Variables used by sourcing scripts
SCRIPT_NAME="${SCRIPT_NAME:-$(basename "$0" .sh)}"

RESET='' RED='' GREEN='' YELLOW='' BOLD='' DIM=''
if [[ -t 1 || -t 2 ]] && [[ -z "${NO_COLOR:-}" ]] && command -v tput &>/dev/null && (( $(tput colors 2>/dev/null || echo 0) >= 8 )); then
    BOLD=$(tput bold) DIM=$(tput dim) RESET=$(tput sgr0)
    RED=$BOLD$(tput setaf 1) GREEN=$BOLD$(tput setaf 2) YELLOW=$BOLD$(tput setaf 3)
fi

say()      { printf '%s: %s\n' "$1" "$2" >&2; }
ok()       { printf '\r\033[K%s: %b%s%b [%ss]\n' "$1" "$GREEN" "${3:-done}" "$RESET" "$2" >&2; }
fail()     { printf '\r\033[K%s: %bfailed%b [%ss]\n' "$1" "$RED" "$RESET" "$2" >&2; }
warn()     { printf '%s: %b%s%b\n' "$1" "$YELLOW" "$2" "$RESET" >&2; }
fatal()    { printf '%s: %b%s%b\n' "$SCRIPT_NAME" "$RED" "$1" "$RESET" >&2; exit "${2:-1}"; }
progress() { printf '\r\033[K%s: %b%s%b [%ss]' "$1" "$([[ $2 == stalled ]] && echo "$YELLOW" || echo "$DIM")" "$2" "$RESET" "$3" >&2; }
now()      { date +%s; }

CLI_LIST="claude codex gemini rovo"
cli_cmd() {
    case "$1" in
        claude) echo "claude --print" ;; codex) echo "codex exec" ;;
        gemini) echo "gemini" ;; rovo) echo "acli rovodev run" ;; *) return 1 ;;
    esac
}

for cmd in gtimeout timeout; do command -v $cmd &>/dev/null && { TIMEOUT_CMD=$cmd; break; }; done

require_int() { [[ "$2" =~ ^[1-9][0-9]*$ ]] || fatal "$1 must be a positive integer"; }
require_val() { [[ -n "${2:-}" && ! "$2" =~ ^- ]] || fatal "$1 requires a value"; }

is_stuck() {
    [[ -f "$1" ]] || return 1
    local c; c=$(tail -20 "$1" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    [[ "$c" =~ (allow|permit|approve|confirm|continue|proceed).*(y/n|\[y\]|yes.*no|\?) || "$c" =~ [\(\[]y/?n[\)\]] ]]
}
