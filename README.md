# Scripts

A collection of shell utilities.

---

## [checkfix.sh](./checkfix.sh)

Iterative LLM-based code review. Checks code for bugs, fixes them, and repeats until stable.

### Usage

```bash
# Check current branch against main/master
./checkfix.sh

# Check specific files
./checkfix.sh --files src/lib.py src/utils.py

# Use a different LLM CLI
./checkfix.sh --cli codex
```

### Options

| Option | Description | Default |
|--------|-------------|---------|
| `-l, --cli NAME` | LLM CLI to use (claude, codex, gemini, rovo) | claude |
| `-f, --files FILE...` | Check specific files instead of git diff | — |
| `-m, --max-iterations N` | Maximum fix iterations | 15 |
| `-c, --consecutive N` | Clean passes required to succeed | 3 |
| `-r, --retries N` | Retries per CLI call | 2 |
| `-t, --timeout SECS` | Timeout per CLI call | 1200 |
| `-R, --repo` | Run repo-wide (CLI explores on its own) | — |
| `--dry-run` | Run without calling the LLM | — |

### How it works

1. **Check** — Sends code to the LLM for bug review (logic errors, crashes, security flaws, etc.)
2. **Fix** — If issues found, asks the LLM to fix them with minimal changes
3. **Repeat** — Loops until consecutive clean passes (default 3) or max iterations reached

The script detects cycles (returning to a previous state) and guards against runaway changes.

---

## [zap.sh](./zap.sh)

Run a single LLM prompt against code context. Quick one-shot tasks like PR descriptions, improvements, or cleanup.

### Usage

```bash
# Generate a PR description from current branch diff
./zap.sh pr

# Tighten specific files
./zap.sh --files lib.py utils.py tighten

# Custom prompt
./zap.sh -p "Explain this code"

# Prompt from stdin
echo "Review for bugs" | ./zap.sh -p -
```

### Options

| Option | Description | Default |
|--------|-------------|---------|
| `-l, --cli NAME` | LLM CLI to use (claude, codex, gemini, rovo) | claude |
| `-f, --files FILE...` | Target specific files instead of git diff | — |
| `-R, --repo` | Run prompt repo-wide (CLI explores on its own) | — |
| `-p, --prompt TEXT` | Custom prompt (use `-` for stdin) | — |
| `-t, --timeout SECS` | Timeout per CLI call | 300 |
| `-r, --retries N` | Retries on failure | 2 |
| `--raw` | Output raw response without status messages | — |
| `--list` | List available presets | — |

### Presets

| Preset | Description |
|--------|-------------|
| `pr` | Write a brief PR description from the diff |
| `build` | Run build/tests and fix failures |
| `tighten` | Remove redundancy, simplify verbose expressions |
| `check` | Review for bugs with [PASS]/[FAIL] output |
| `checkfix` | Review for bugs and fix them |
| `resolve` | Resolve merge conflicts with main |
| `clean` | Clean up code: simplify, remove dead code, improve naming |

### Iterative cleanup

Run until no more changes are found:

```bash
for i in {1..5}; do zap --repo clean || break; done
```

Useful for multi-pass cleanup where each run may expose new opportunities.