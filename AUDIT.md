# Audit: `stay-on-sequoia.sh`

**Overall verdict:** Well-written, production-quality script. Good defensive coding, consistent quoting, proper `set -euo pipefail`, clean structure. Three issues worth fixing, none critical.

---

## Medium Priority — Recommended Fixes

### 1. Command injection via `eval` in `get_user_home()` (line 95)

```bash
home="$(eval echo "~$u" 2>/dev/null || true)"
```

The `eval` is an anti-pattern in a script that runs as root. While macOS usernames are OS-constrained (limiting realistic risk), this should still be removed as a defense-in-depth measure. The `dscl` primary path on line 92 is the correct approach — just fail if it doesn't work rather than falling back to `eval`.

### 2. Argument parsing: `--days`/`--date` give cryptic errors when value is missing (lines 343–349)

```bash
--days)
  shift || die "--days requires a value"
  DEFERRAL_DAYS="$1"
  ;;
```

If `--days` is the last argument, `shift` succeeds (removes `--days`), but then `$1` is unset. With `set -u`, this produces a cryptic `bash: $1: unbound variable` instead of the friendly die message. The `shift || die` guard doesn't catch this because `shift` itself succeeded.

**Fix:** Check `$#` after the shift:

```bash
--days)
  shift
  [[ $# -gt 0 ]] || die "--days requires a value"
  DEFERRAL_DAYS="$1"
  ;;
```

Same issue exists for `--date`.

### 3. Integer comparison with potentially non-numeric value in `show_status()` (line 290)

```bash
if [[ "$os_major" -eq 15 ]]; then
```

If `sw_vers` fails, `product_version` falls back to `"unknown"`, making `os_major` also `"unknown"`. The `-eq` operator on a non-numeric string errors out under `set -e`. Use string comparison instead:

```bash
if [[ "$os_major" == "15" ]]; then
```

---

## Low Priority — Nice to Have

### 4. `$0` not resolved to absolute path (line 120)

`exec sudo bash "$0"` — if the script is invoked via a relative path and CWD is unusual, this could theoretically re-exec the wrong file. Safer:

```bash
exec sudo bash "$(realpath "$0")" "${ORIG_ARGS[@]}"
```

### 5. Redundant `&& true` (line 311)

```bash
run_as_user "$console_user" defaults read ... 2>/dev/null \
  && true || log "  <unset>"
```

The `&& true` is dead code. Simplify to:

```bash
run_as_user "$console_user" defaults read ... 2>/dev/null \
  || log "  <unset>"
```

### 6. No `--date` format validation

A malformed date string passes through silently to `defaults write`, which will fail. Could validate with a regex or `date -jf`.

### 7. Hardcoded "Tahoe"

Intentional for this script's purpose, but consider making it a variable at the top for easy updating when the next macOS version arrives.

---

## Things Done Well

- `set -euo pipefail` + `IFS=$'\n\t'` — textbook defensive bash
- Consistent, thorough quoting everywhere — no word-splitting risks
- Clean function decomposition with proper `local` scoping
- Sensible `|| true` / `|| warn` error handling
- Compatible with macOS's default Bash 3.2 (no Bash 4+ features)
- `need_cmd` pre-flight checks for all required utilities
- Profile validation with `plutil -lint`
- `nullglob` properly scoped around globs
- Smart privilege escalation that captures original args and re-execs
- Good documentation in header and `--help`
