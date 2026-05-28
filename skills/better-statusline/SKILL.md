---
name: better-statusline
description: Cost-aware statusline at ~/.claude/: query session cost, overages, rate-limit, thresholds; customize or uninstall.
allowed-tools: Read(~/.claude/**), Read(~/.claude.json), Edit(~/.claude/**), Grep, Bash(jq:*), Bash(cat:*), Bash(ls:*), Bash(test:*), Bash(stat:*), Bash(awk:*), Bash(date:*)
---

# Better-Statusline Skill

Scope: the cost-aware statusline installed at `~/.claude/statusline-command.sh` + `~/.claude/scripts/track-turn-cost.sh`. This skill operates on the *installed* files only. It does NOT edit any package source repo, even if one exists locally.

## Absolute rules

- **Never mutate `~/.claude/settings.json` or either installed script without: (1) backing up to `<path>.bak-$(date +%s)`, (2) showing the user an exact diff, (3) asking for explicit confirmation.** All three steps, every time.
- **Never fabricate missing data.** If `overage_state.json` doesn't exist, the user is not currently in overage — say so plainly. Don't report `$0.00` as if it were measured.
- **Never modify the package source repo.** Only operate on `~/.claude/`.
- **Uninstall requires explicit confirmation** — don't fire from fuzzy phrasing like "clean up my statusline."

## Files on disk

| Path | Role | Written by |
|---|---|---|
| `~/.claude/statusline-command.sh` | Renderer (runs on every refresh) | user (installed) |
| `~/.claude/scripts/track-turn-cost.sh` | Stop hook (runs after each turn) | user (installed) |
| `~/.claude/settings.json` | Wires both of the above | user |
| `~/.claude/costs/live_turn_<sid>.json` | Per-session turn stats | Stop hook |
| `~/.claude/costs/rl_snapshot.json` | Last-seen rate-limit state (5h + 7d) | renderer |
| `~/.claude/costs/overage_state.json` | Current 5h window's overage state (per-session baselines + shared total). Exists only while in overage. | Stop hook |
| `~/.claude/costs/overages.json` | Historical overage ledger, keyed by `<window_start_unix>-<window_end_unix>` | Stop hook |
| `/tmp/claude_statusline_billing_mode` | 1h-TTL cache of auto-detected billing mode | renderer |

## Billing mode

Auto-detected from `~/.claude.json:.oauthAccount.billingType`:
- `"stripe_subscription"` → **account** (Max/Pro/Team; has rate_limits + overage tracking)
- anything else → **api** (pay-per-token)

```bash
jq -r '.oauthAccount.billingType // "api"' "$HOME/.claude.json"
```

Cached in `/tmp/claude_statusline_billing_mode` for 1h. Delete to force re-detect.

---

## Query mode

### Current state snapshot

**Am I in overage right now?**
```bash
test -f ~/.claude/costs/overage_state.json && echo yes || echo no
```

**Current 5h / 7d rate-limit state:**
```bash
jq . ~/.claude/costs/rl_snapshot.json 2>/dev/null || echo "no snapshot (renderer may not have run yet)"
```

**Current overage state (per-session + aggregate):**
```bash
jq . ~/.claude/costs/overage_state.json
```

**This session's cost stats.** If the user gave you `session_id`, use it. Otherwise use the most recently modified file:
```bash
# with session_id:
jq . ~/.claude/costs/live_turn_<session_id>.json
# most recent:
ls -t ~/.claude/costs/live_turn_*.json | head -1 | xargs jq .
```

### Historical aggregates (first-class — user cares about these)

**Grand total overage ever recorded:**
```bash
jq '[.[] | .total_overage_usd] | add // 0' ~/.claude/costs/overages.json
```

**Per-window breakdown, chronological:**
```bash
jq -r 'to_entries | sort_by(.value.window_start) | .[] |
  "\(.value.window_start) → \(.value.window_end): $\(.value.total_overage_usd)"' \
  ~/.claude/costs/overages.json
```

**Per calendar day (totals):**
```bash
jq -r '[.[] | {day: (.window_start[0:10]), cost: .total_overage_usd}]
      | group_by(.day) | map({day: .[0].day, total: (map(.cost) | add)})
      | sort_by(.day) | .[] | "\(.day): $\(.total)"' \
  ~/.claude/costs/overages.json
```

**Per calendar month:**
```bash
jq -r '[.[] | {m: (.window_start[0:7]), c: .total_overage_usd}]
      | group_by(.m) | map({m: .[0].m, t: (map(.c) | add)})
      | sort_by(.m) | .[] | "\(.m): $\(.t)"' \
  ~/.claude/costs/overages.json
```

**Last N days total:**
```bash
N=7
SINCE=$(date -u -v-"$N"d "+%Y-%m-%d" 2>/dev/null || date -u -d "$N days ago" "+%Y-%m-%d")
jq --arg s "$SINCE" '[.[] | select(.window_start >= $s) | .total_overage_usd] | add // 0' \
  ~/.claude/costs/overages.json
```

**Grand total including in-progress window:**
```bash
hist=$(jq '[.[] | .total_overage_usd] | add // 0' ~/.claude/costs/overages.json 2>/dev/null || echo 0)
live=$(jq '.total_overage_usd // 0' ~/.claude/costs/overage_state.json 2>/dev/null || echo 0)
awk -v h="$hist" -v l="$live" 'BEGIN { printf "$%.2f (historical $%.2f + in-progress $%.2f)\n", h+l, h, l }'
```

When presenting aggregates to the user, always format dollar values to 2 decimals.

---

## Update mode

### Mandatory workflow (no shortcuts)

1. **Read** the target file (`Read` tool).
2. **Locate** the exact line(s) to change (`Grep` tool — patterns listed below).
3. **Propose** the change: show BEFORE and AFTER in the conversation so the user sees the literal diff.
4. **Ask** for explicit confirmation.
5. **Back up:** `cp <path> <path>.bak-$(date +%s)`.
6. **Apply** via `Edit` tool.
7. **Offer** a smoke-test render against a sample input.

Skipping any step is a bug. If the user is impatient and says "just do it," still back up.

### Customization knobs

All live near the top of `~/.claude/statusline-command.sh`.

| What to change | Grep pattern to find it | Value format |
|---|---|---|
| Session-cost tiers (API L2 + overage session $) | `color_scale "\$total_cost"` AND `color_scale "\$session_overage_usd"` | 4 USD thresholds |
| Burn-rate tiers | `color_scale "\$burn_rate"` | 4 USD/min thresholds |
| Context-window tiers | `color_scale "\$window_used"` | 4 token thresholds |
| Rate-limit bar tiers | `color_scale "\$pct"` inside `build_rl_segment` | 4 percent thresholds |
| Color palette | `C_SAFE=`, `C_LOW=`, `C_MED=`, `C_HIGH=`, `C_ALERT=`, `C_CRIT=`, `C_LABEL=`, `C_PIPE=`, `C_DIM=` | ANSI 256-color codes |
| Overage-line highlight | Uses `C_CRIT` at `overages:` label and trailing `$agg` | one palette constant |
| Base branch for ahead/behind | `origin/main...\$git_branch` | branch name |
| Billing-mode cache TTL | `_age -lt 3600` | seconds |

When the user asks to change cost-tier colors/thresholds, **update both patterns** (`$total_cost` and `$session_overage_usd`) — they should stay synchronized so the eye calibrates on the same scale across modes.

### Smoke-test after update

Suggest running one of the three canonical test inputs to verify rendering:

```bash
# API mode
echo "api" > /tmp/claude_statusline_billing_mode
printf '%s' '{"workspace":{"current_dir":"'"$PWD"'"},"model":{"display_name":"claude-opus-4-7"},
 "cost":{"total_cost_usd":5,"total_duration_ms":120000,"total_lines_added":0,"total_lines_removed":0},
 "context_window":{"total_input_tokens":0,"total_output_tokens":0,"used_percentage":15,"context_window_size":1000000},
 "session_id":"smoke"}' | bash ~/.claude/statusline-command.sh
rm /tmp/claude_statusline_billing_mode
```

---

## Debug mode

### Common symptoms and the check that proves it

| Symptom | First check |
|---|---|
| No statusline at all | `jq '.statusLine' ~/.claude/settings.json` — wired? |
| Per-turn numbers missing (only session total) | `jq '.hooks.Stop' ~/.claude/settings.json` — hook registered? |
| Account user's rate bars disappeared | `jq -r '.oauthAccount.billingType // "api"' ~/.claude.json` — still subscription? Then: `cat /tmp/claude_statusline_billing_mode` — cache stuck on "api"? |
| API user sees rate bars anyway | Same — `rm /tmp/claude_statusline_billing_mode` to force re-detect. |
| `overages:` line never shows | Verify `five_hour_pct >= 100` in `rl_snapshot.json`. Below 100 = by-design hidden. |
| Trailing `$0.00` on overage line after visible spend | Stop hook hasn't fired yet — needs one completed turn. Check `rl_snapshot.json` is fresh. |
| Colors print as `[38;5;114m` | Terminal doesn't support ANSI 256-color. Not fixable in the script. |
| Ahead/behind never shows | Default branch isn't `origin/main`. Fix via customization table. |

### Full diagnostic sweep

When the user says something vague like "statusline is acting up" or "why is my statusline weird," run this before asking questions:

```bash
echo "=== Install check ==="
for f in ~/.claude/statusline-command.sh ~/.claude/scripts/track-turn-cost.sh; do
  test -x "$f" && echo "OK   $f" || echo "MISS $f"
done

echo "=== Settings wire-up ==="
jq '.statusLine.command // "NOT SET"' ~/.claude/settings.json
jq '(.hooks.Stop // []) | map(.hooks // []) | flatten
    | map(.command // "") | any(contains("track-turn-cost.sh"))' ~/.claude/settings.json

echo "=== Billing mode ==="
echo "cache: $(cat /tmp/claude_statusline_billing_mode 2>/dev/null || echo none)"
echo "live:  $(jq -r '.oauthAccount.billingType // "api"' ~/.claude.json)"

echo "=== Rate-limit snapshot ==="
jq . ~/.claude/costs/rl_snapshot.json 2>/dev/null || echo "(no snapshot)"

echo "=== Overage state ==="
jq . ~/.claude/costs/overage_state.json 2>/dev/null || echo "(not in overage)"
```

Then interpret the output for the user — don't just dump it.

---

## Uninstall

**Requires explicit confirmation.** Echo back what you're about to do before any file touches.

Order:
1. Find the most recent settings backup: `ls -t ~/.claude/settings.json.bak-* 2>/dev/null | head -1`. If one exists, offer to restore from it (simplest). Otherwise, strip the statusline wiring with `jq`:
   ```bash
   cp ~/.claude/settings.json ~/.claude/settings.json.bak-$(date +%s)
   jq 'del(.statusLine)
       | .hooks.Stop = ((.hooks.Stop // [])
                        | map(.hooks |= map(select((.command // "") | contains("track-turn-cost.sh") | not)))
                        | map(select((.hooks // []) | length > 0)))' \
      ~/.claude/settings.json > /tmp/settings.new && mv /tmp/settings.new ~/.claude/settings.json
   ```
2. Remove the scripts: `rm ~/.claude/statusline-command.sh ~/.claude/scripts/track-turn-cost.sh`
3. **Ask about cost data.** `~/.claude/costs/` holds overage history. Default answer: **keep**. Only remove if user explicitly asks.
4. Remove the billing cache: `rm -f /tmp/claude_statusline_billing_mode`
5. Offer to also remove this skill directory: `rm -rf ~/.claude/skills/statusline/`. User choice.

Report a summary of every path touched at the end.
