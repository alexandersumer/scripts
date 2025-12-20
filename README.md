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
| `-t, --timeout SECONDS` | Timeout per CLI call | 1200 |
| `--dry-run` | Run without calling the LLM | — |

### How it works

1. **Check** — Sends code to the LLM for bug review (logic errors, crashes, security flaws, etc.)
2. **Fix** — If issues found, asks the LLM to fix them with minimal changes
3. **Repeat** — Loops until consecutive clean passes (default 3) or max iterations reached

The script detects cycles (returning to a previous state) and guards against runaway changes.