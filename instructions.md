# Installing the Claude Code Statusline

**Audience:** a Claude Code session running on the user's machine. This document tells you (the assistant) how to install a billing-mode-aware, cost- and rate-limit-tracking statusline into the user's Claude Code setup. Work through the steps in order, pausing at decision points rather than charging ahead.

---

## What you're installing

Two shell scripts that coordinate through JSON state files on disk, plus an optional companion skill:

1. **`statusline-command.sh`** — The renderer. Claude Code invokes it on every statusline refresh, piping a JSON blob to stdin. It prints 3, 4, or 5 colored lines depending on the user's billing mode and current rate-limit state.
2. **`track-turn-cost.sh`** — A `Stop` hook. Runs after every turn, parses the session transcript, computes per-turn + session-total cost, and (for account-billed users currently in 5h OR 7d overage) maintains a shared overage ledger across sessions, organized into "episodes" (maximal intervals during which at least one rate-limit is ≥100%).
3. **`skills/better-statusline/SKILL.md`** *(optional but recommended)* — A Claude Code skill installed to `~/.claude/skills/better-statusline/` that lets the user query state ("am I in overage?", "total overage this month?"), tune thresholds and colors via Claude, debug rendering issues, and uninstall — all via natural language. Named `better-statusline` so it doesn't collide with Claude's native `/statusline-setup` command. Not required for the statusline to work, but makes the installed system much easier to live with.

### Files on disk

| Path | Written by | Role |
|---|---|---|
| `~/.claude/costs/live_turn_<session_id>.json` | hook | per-session turn stats (cost, tokens, duration). Pruned after 7 days. |
| `~/.claude/costs/rl_snapshot.json` | renderer | last-seen 5h + 7d rate-limit data, used by the hook (which doesn't receive it in its own input). |
| `~/.claude/costs/overage_state.json` | hook | current episode's in-progress overage state: per-session baselines + shared running total + active_triggers + triggers_ever + seen_resets. Only exists while in overage. Auto-created by the Stop hook on its first fire after either the 5h or 7d quota crosses 100% — no manual setup. Until that first fire, the renderer shows `⚠ state pending` on the overage line. |
| `~/.claude/costs/overages.json` | hook | historical overage ledger. Keyed by `<episode_start_unix>` (pure integer); appended when an episode ends (both limits drop back below 100%). |
| `/tmp/claude_statusline_billing_mode` | renderer | 1h TTL cache of auto-detected billing mode. |

### Billing-mode auto-detection

**No CLI flag.** The renderer reads `~/.claude.json` and looks at `.oauthAccount.billingType`:

- `"stripe_subscription"` → **account** (Max / Pro / Team; subscription covers up to 5h+7d limits, then overage billing kicks in)
- anything else (or missing) → **api** (pay-per-token)

The result is cached to `/tmp/claude_statusline_billing_mode` for 1h.

### Line layout (three modes)

```
API mode (3 lines)
 L1  repo [dir] branch (+ahead/-behind)
 L2  $total | ↑$last ~$avg x17 | $0.24/m | 12m 34s | +120/-40 | model
 L3  c-read: c-write: read: write: window:

Account mode, no limit ≥100% (4 lines)
 L1  repo [dir] branch (+ahead/-behind)
 L2  12m 34s | +120/-40 | model                  ← cost fields hidden
 L3  c-read: c-write: read: write: window:
 L4  5h █████░░░░░ 50% r:2h 15m | 7d ███░░░░░░░ 28% r:4d 12h

Account mode, 5h or 7d ≥100% (5 lines)
 L1  repo [dir] branch (+ahead/-behind)
 L2  12m 34s | +120/-40 | model
 L3  c-read: c-write: read: write: window:
 L4  overages: $sess_over | ↑$last ~$avg x17 | $0.24/m | $4.82   ← overage line (either limit triggers it)
 L5  5h ██████████ 100% r:12m | 7d ███░░░░░░ 28% r:4d 12h
```

**Line 1 notes:**
- `repo` is the basename of the main checkout (the true parent repository), resolved via `git worktree list --porcelain` so it stays correct from any worktree location — not just those under a `.worktrees/` convention.
- `[dir]` renders only when the current directory name differs from **both** `repo` and `branch`. Under conventions where a worktree directory matches its branch name (e.g. kluein `gw`'s `.worktrees/<branch-name>/` layout), `dir` collapses away to avoid printing the same string twice. For arbitrary-location worktrees where `dir` and `branch` diverge, both still render.
- `(+ahead/-behind)` is computed against `origin/main`; silent if that ref doesn't exist.

### Overage episode model

Overage tracking is organized into **episodes**. An episode is a maximal interval during which at least one of {5h, 7d} rate-limits is ≥100%. The episode starts the moment `in_overage` flips to true, and ends the moment both limits drop below 100% again (typically at a reset). Each episode gets its own row in `overages.json`, keyed by `<episode_start_unix>`.

Per-session baselines are captured at the moment a session first appears during the episode. They are **never re-captured mid-episode**, so `current_overage_usd = session_total_cost - baseline_usd` stays a pure, idempotent computation. This means:

- **No double-counting when both limits overlap.** If 7d and 5h are both ≥100% and 7d later resets, the episode continues under 5h with the same baselines — no ledger row is written at the mid-episode transition.
- **Fresh baselines on episode restart.** If 7d triggers an episode, 7d resets mid-5h-session (ending the episode), and then 5h later crosses 100% in the same session, a new episode starts with new baselines. Overage counts from zero, not continuing from the 7d-triggered total.

Each episode record carries `triggers_ever` — the union of limits that were ≥100% at any point during the episode. In the ledger it's named `triggers`. Common values: `["five_hour"]`, `["seven_day"]`, `["five_hour","seven_day"]`.

The `overages:` label and the trailing `$4.82` both render in bright red. The line reads:

| Segment | Meaning |
|---|---|
| `overages:` | Mode indicator — we are accruing overage right now. |
| `$sess_over` | **This session's post-crossover spend only** (from `overage_state.json`). Pre-overage spend is deliberately *not* shown — it was covered by the subscription and shouldn't leak onto the "paying real dollars now" line. If the session had $10 of pre-overage turns and a $0.30 crossover turn, this figure shows `$0.300` (not `$10.300`). |
| `↑$last` | Last turn's cost. Intrinsically post-crossover when we're in overage (the latest turn *is* an overage turn). |
| `~$avg xN` | Session-wide rolling average — **not** chopped at the crossover. Chopping would skew the average, and the crossover turn's cost is already surfaced via `$sess_over` and `↑$last`. |
| `$0.24/m` | Burn rate for the last turn. Per-turn metric, post-crossover. |
| `$4.82` | **Cross-session aggregate** — sum of every session's `current_overage_usd` in the current episode. Archived to `overages.json` when the episode ends. |

**Important:** `$sess_over` and `$4.82` measure different things and either can be larger. `$sess_over` is this session's post-crossover contribution. `$4.82` is the sum across *all* sessions in the episode. A long-running session that just tipped into overage shows a tiny `$sess_over` while the aggregate could be much larger (if other sessions have been racking up overage too), or vice versa.

**Degenerate forms** the renderer handles automatically. In every case the `overages:` label itself is always shown so the user knows they are accruing overage; what varies is what follows it.

- **`overage_state.json` doesn't exist yet** (the 5h or 7d threshold just crossed and no Stop hook has fired since): instead of rendering a misleading `$0.00` aggregate, the line shows `overages: ⚠ state pending — populates after next turn | ↑$last ~$avg | $/m`. The file is created automatically by the Stop hook on its next fire — no manual setup required — and the warning self-resolves on the same turn-end. The trailing aggregate `$agg` is deliberately suppressed in this branch because the state file carries the aggregate and its absence means "no measurement yet," not "measured zero".
- **State file exists but this session isn't in its `sessions` map yet** (the session started before the episode began and hasn't fired a Stop hook since): `$sess_over` would otherwise be silently omitted. Instead the line renders `overages: ⏳ session pending | ↑$last ~$avg | $/m | $agg` — the cross-session aggregate is still real, only the per-session leading figure is pending registration. Resolves on the next Stop hook fire for this session.
- **Hook registered this session but this session has no post-crossover spend yet** (uncommon — session total equals baseline exactly): `$sess_over` is omitted without a warning. Line becomes `overages: ↑$last ~$avg | $/m | $agg`.
- **No turns completed yet** (brand-new session during overage, no live_turn file yet): the perturn segment is empty. Line collapses to `overages: $agg` (state exists) or `overages: ⚠ state pending — populates after next turn` (state doesn't exist yet).

---

## Step 0 — Prerequisites

```bash
command -v bash >/dev/null && echo "bash OK"
command -v jq   >/dev/null && echo "jq OK"   || echo "MISSING: install jq (e.g. 'brew install jq')"
command -v awk  >/dev/null && echo "awk OK"  # BSD awk and gawk both work
command -v git  >/dev/null && echo "git OK"  # used for branch + ahead/behind
```

The user's terminal must support ANSI 256-color escape codes. Virtually all modern terminals do — if colors look wrong later, that's the cause.

---

## Upgrading from a previous version

Already installed an earlier version of the package? Replace your local package directory with the newer one, then **re-run Step 1** — that's it. Step 1 is written to be idempotent and self-backing-up: every file it replaces is copied to `<path>.bak-<timestamp>` first, so a bad upgrade reverts with a single `cp` pair. Step 2 (settings.json wiring) is likewise idempotent — you can re-run it safely, and it's only necessary if the new version changes the wiring (a rare event; the changelog of the new version will tell you).

The `~/.claude/costs/` directory — your historical overage ledger — is never touched by Step 1. Upgrades preserve your data by default.

If you've customized the installed scripts locally (e.g., tuned threshold numbers), the upgrade will overwrite those customizations — but the backup file lets you diff and re-apply them:

```bash
# After an upgrade, see what your customizations were (or what the new version changed):
diff ~/.claude/statusline-command.sh.bak-<ts> ~/.claude/statusline-command.sh
```

If you'd rather drive the upgrade through Claude than the CLI, the `/better-statusline` skill's Update-mode workflow (diff → back up → replace, already documented inside the skill) handles it: point Claude at the new package directory and ask it to upgrade — the same backup-then-replace mechanics apply.

---

## Step 1 — Place the scripts and skill

Defaults used here (paths are not coupled; only `settings.json` points at the scripts):

- `~/.claude/statusline-command.sh` — the renderer
- `~/.claude/scripts/track-turn-cost.sh` — the Stop hook
- `~/.claude/skills/better-statusline/SKILL.md` — the companion skill

**This step is both the install AND the upgrade path.** Re-running it against a newer version of the package upgrades an existing install in place. Every file that gets replaced is timestamp-backed-up first (suffix `.bak-<unix_ts>`), so a bad upgrade is revertible without re-downloading anything.

If the user has customized the installed scripts (e.g., tweaked threshold numbers), warn them: the backup preserves their old version, but they'll need to re-apply their edits to the new version manually. Diff the backup against the new script to see what to port.

```bash
TS=$(date +%s)    # shared timestamp for all backups in this run

# Scripts — back up if present, then install.
mkdir -p "$HOME/.claude/scripts"
[ -f "$HOME/.claude/statusline-command.sh" ] \
    && cp "$HOME/.claude/statusline-command.sh" "$HOME/.claude/statusline-command.sh.bak-$TS"
[ -f "$HOME/.claude/scripts/track-turn-cost.sh" ] \
    && cp "$HOME/.claude/scripts/track-turn-cost.sh" "$HOME/.claude/scripts/track-turn-cost.sh.bak-$TS"
cp scripts/statusline-command.sh "$HOME/.claude/statusline-command.sh"
cp scripts/track-turn-cost.sh    "$HOME/.claude/scripts/track-turn-cost.sh"
chmod +x "$HOME/.claude/statusline-command.sh" "$HOME/.claude/scripts/track-turn-cost.sh"

# Skill (optional — skip this block if the user declines the companion skill).
# Same backup-then-replace pattern, so re-running Step 1 upgrades the skill too.
SKILL_DEST="$HOME/.claude/skills/better-statusline/SKILL.md"
mkdir -p "$(dirname "$SKILL_DEST")"
[ -f "$SKILL_DEST" ] && cp "$SKILL_DEST" "$SKILL_DEST.bak-$TS"
cp skills/better-statusline/SKILL.md "$SKILL_DEST"

# After an upgrade, clear the billing-mode cache so auto-detection re-runs
# against the latest ~/.claude.json. Cheap no-op on first install.
rm -f /tmp/claude_statusline_billing_mode

echo "done. backups (if any) tagged: $TS"
```

The `~/.claude/costs/` directory will be auto-created by the hook on first use; **do NOT delete it during an upgrade** — it holds the user's historical overage ledger.

---

## Step 2 — Wire up `settings.json`

Two edits to `~/.claude/settings.json`:

1. **Set the top-level `statusLine` key.** Only one is allowed; if the user has a different statusline already, confirm before replacing.
2. **Append a new entry to `hooks.Stop[]`.** Do NOT overwrite — most users already have Stop hooks (notifications, compliance trackers, etc.). Append, don't replace.

### Safe, idempotent merge with `jq`

```bash
SETTINGS="$HOME/.claude/settings.json"
cp "$SETTINGS" "$SETTINGS.bak-$(date +%s)"    # always back up first

# 1. statusLine key — idempotent; replaces whatever was there.
jq '.statusLine = {type: "command", command: "/bin/bash $HOME/.claude/statusline-command.sh"}' \
   "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"

# 2. Stop hook — append only if our command isn't already registered.
if ! jq -e '(.hooks.Stop // []) | map(.hooks // []) | flatten | map(.command // "") | any(contains("track-turn-cost.sh"))' \
     "$SETTINGS" >/dev/null; then
  jq '.hooks.Stop = ((.hooks.Stop // []) + [{
        matcher: "",
        hooks: [{type: "command", command: "bash ~/.claude/scripts/track-turn-cost.sh"}]
      }])' \
     "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
fi
```

### Manual-merge reference

Ready-to-paste JSON fragments live in `settings-snippets/`:

- `settings-snippets/statusLine.json` — the object to assign to `.statusLine`
- `settings-snippets/stop-hook.json` — one entry to append to `.hooks.Stop[]`

---

## Step 3 — Verify

### 3a. Billing-mode detection

```bash
jq -r '.oauthAccount.billingType // "api"' "$HOME/.claude.json"
# "stripe_subscription" → account | anything else → api
```

### 3b. Renderer smoke tests

**API mode** — pipe minimal JSON without `rate_limits`; expect 3 lines with full cost segments on line 2:

```bash
rm -f /tmp/claude_statusline_billing_mode  # clear cache
# Temporarily force API mode for this test:
echo "api" > /tmp/claude_statusline_billing_mode

printf '%s' '{
  "workspace": {"current_dir": "'"$PWD"'"},
  "model": {"display_name": "claude-opus-4-7"},
  "cost": {"total_cost_usd": 0.5, "total_duration_ms": 120000, "total_lines_added": 10, "total_lines_removed": 5},
  "context_window": {"total_input_tokens": 100, "total_output_tokens": 200, "used_percentage": 15, "context_window_size": 1000000},
  "session_id": "smoke-test"
}' | bash "$HOME/.claude/statusline-command.sh"

rm /tmp/claude_statusline_billing_mode  # restore auto-detection
```

**Account mode, no limit ≥100%** — include `rate_limits` with both `used_percentage < 100`; expect 4 lines, no cost fields on line 2, rate bars on line 4:

```bash
printf '%s' '{
  "workspace": {"current_dir": "'"$PWD"'"},
  "model": {"display_name": "claude-opus-4-7"},
  "cost": {"total_cost_usd": 0.5, "total_duration_ms": 120000, "total_lines_added": 10, "total_lines_removed": 5},
  "context_window": {"total_input_tokens": 100, "total_output_tokens": 200, "used_percentage": 15, "context_window_size": 1000000},
  "rate_limits": {
    "five_hour":  {"used_percentage": 50, "resets_at": "2099-01-01T00:00:00Z"},
    "seven_day":  {"used_percentage": 28, "resets_at": "2099-01-08T00:00:00Z"}
  },
  "session_id": "smoke-test"
}' | bash "$HOME/.claude/statusline-command.sh"

# Confirm renderer wrote the rate-limit snapshot:
cat "$HOME/.claude/costs/rl_snapshot.json"
```

**Account mode, over limit** — set EITHER `five_hour.used_percentage: 100` OR `seven_day.used_percentage: 100` (either triggers overage mode). Expect 5 lines including an overage line above the rate bars. Because no `overage_state.json` exists during a smoke test, the line renders the "state pending" warning instead of a misleading `$0.00` aggregate: `overages: ⚠ state pending — populates after next turn`. (In real use, the file is created automatically on the first Stop hook fire after crossover — the warning self-resolves within one turn.)

```bash
printf '%s' '{
  "workspace": {"current_dir": "'"$PWD"'"},
  "model": {"display_name": "claude-opus-4-7"},
  "cost": {"total_cost_usd": 0.5, "total_duration_ms": 120000, "total_lines_added": 10, "total_lines_removed": 5},
  "context_window": {"total_input_tokens": 100, "total_output_tokens": 200, "used_percentage": 15, "context_window_size": 1000000},
  "rate_limits": {
    "five_hour":  {"used_percentage": 100, "resets_at": "2099-01-01T00:00:00Z"},
    "seven_day":  {"used_percentage": 28,  "resets_at": "2099-01-08T00:00:00Z"}
  },
  "session_id": "smoke-test"
}' | bash "$HOME/.claude/statusline-command.sh"
```

### 3c. Hook smoke test

Fake a Stop-hook input with a nonexistent transcript. Should exit 0 silently:

```bash
echo '{"session_id":"smoke","transcript_path":"/nonexistent"}' \
  | bash "$HOME/.claude/scripts/track-turn-cost.sh"
echo "exit=$?"   # expect: exit=0
```

### 3d. Live test

Start a new Claude Code session, send any prompt, wait for the turn to end. Then:

```bash
ls "$HOME/.claude/costs/"           # expect: live_turn_*.json + rl_snapshot.json
jq . "$HOME/.claude/costs/live_turn_"*.json | head
```

`session_total_cost` should be present alongside `last_cost`/`avg_cost`.

---

## Step 4 — Querying the overage ledger

Once the user has hit a 5h or 7d limit at least once, they'll accumulate episode entries here. Useful snippets:

```bash
# Total overage spend across all recorded episodes:
jq '[.[] | .total_overage_usd] | add' "$HOME/.claude/costs/overages.json"

# Per-episode breakdown, sorted chronologically (shows which limit(s) triggered):
jq -r 'to_entries | sort_by(.value.episode_start) | .[] |
    "\(.value.episode_start) → \(.value.episode_end)  [\(.value.triggers | join(","))]  $\(.value.total_overage_usd | . * 100 | round / 100)"' \
   "$HOME/.claude/costs/overages.json"

# Per-trigger breakdown (how much overage came from 5h vs 7d vs both):
jq -r '[.[] | {t: (.triggers | sort | join("+")), c: .total_overage_usd}]
      | group_by(.t) | map({trigger: .[0].t, total: (map(.c) | add)})
      | .[] | "\(.trigger): $\(.total)"' \
   "$HOME/.claude/costs/overages.json"

# Currently in-progress overage episode (if any):
jq . "$HOME/.claude/costs/overage_state.json" 2>/dev/null || echo "not currently in overage"
```

Archive format:
```json
{
  "1713649800": {
    "episode_start": "2026-04-20T19:30:00Z",
    "episode_end":   "2026-04-21T00:30:00Z",
    "triggers":      ["five_hour"],
    "total_overage_usd": 4.82,
    "sessions": {
      "<session_id>": {
        "baseline_usd": 3.14,
        "current_overage_usd": 1.68,
        "updated_at": "2026-04-20T23:55:00Z"
      }
    }
  }
}
```

---

## Step 5 — (Optional) Customization pointers

If the user asks about tuning thresholds, the knobs are all near the top of `statusline-command.sh`:

| Thing | Where | Default | Meaning |
|---|---|---|---|
| Session-cost tiers (L2 / overage line) | `color_scale "$total_cost" ...` | `1 5 10 25` | USD — `<1` green → `≥25` red |
| Burn-rate tiers | `color_scale "$burn_rate" ...` | `0.10 0.25 0.50 1.00` | USD per minute |
| Context-window tiers | `color_scale "$window_used" ...` | `100000 200000 400000 700000` | tokens |
| Rate-limit bar tiers | inside `build_rl_segment` | `50 70 85 95` | percent used |
| Overage-line highlight color | uses `C_CRIT` (196 bright red) | — | tone down if too loud |
| 256-color palette | `C_SAFE`, `C_LOW`, … | named at top | ANSI 256-color codes |
| Base branch for ahead/behind | `origin/main...$git_branch` | `origin/main` | change if default is `master`/`trunk` |
| Billing-mode cache TTL | `_age -lt 3600` | 1h | bump if subscription changes never happen |

---

## Rollback

```bash
# Restore the settings backup made in Step 2
cp "$HOME/.claude/settings.json.bak-<timestamp>" "$HOME/.claude/settings.json"

# Remove the scripts
rm -f "$HOME/.claude/statusline-command.sh"
rm -f "$HOME/.claude/scripts/track-turn-cost.sh"

# Remove the skill (if it was installed)
rm -rf "$HOME/.claude/skills/better-statusline"

# Optional — clear everything the statusline ever wrote
rm -rf "$HOME/.claude/costs"
rm -f  /tmp/claude_statusline_billing_mode
```

The companion skill also provides an `/better-statusline` → "uninstall" path that handles this interactively (with backup detection and a prompt about whether to preserve `costs/` data). That's usually the easier route.

---

## Common failure modes

- **Account user sees no costs anywhere** — intentional under-limit behaviour. Cost fields reappear automatically when EITHER `five_hour.used_percentage` OR `seven_day.used_percentage` hits 100.
- **`overages: ⚠ state pending — populates after next turn`** — expected transient state between crossing either threshold and the Stop hook's next fire. The hook auto-creates `overage_state.json`; no manual action needed. Resolves within one turn-end. If it persists across multiple turn-ends, verify `cat ~/.claude/costs/rl_snapshot.json` shows `five_hour_pct >= 100` OR `seven_day_pct >= 100`, the Stop hook is wired in `settings.json`, and `~/.claude/scripts/track-turn-cost.sh` is executable.
- **`overages: ⏳ session pending`** — the global state file exists but this specific session hasn't fired a Stop hook since the episode began. Send any prompt to trigger the hook; the leading `$<session_overage>` will appear on the next render. Cross-session aggregate on the right is already correct.
- **Trailing `$0.00` on the overages line** — should not occur under current rendering logic; the line either shows a real `$<aggregate>` or one of the pending-state warnings above. If you do see `$0.00`, the installed `~/.claude/statusline-command.sh` is from a pre-warning version of the package — re-run Step 1 to upgrade.
- **Line 1 shows the directory but no branch.** `git` isn't on PATH, or the dir isn't inside a repo. Both are expected/benign.
- **Colors render as garbage like `[38;5;114m`.** Terminal doesn't support ANSI escapes. Switch terminals (iTerm2, modern Terminal.app, Ghostty, Alacritty, etc.).
- **`jq: error` on every refresh.** `jq` isn't installed. See Step 0.
- **API mode but rate bars still show.** The billing-mode cache is stale. `rm /tmp/claude_statusline_billing_mode` and let it re-detect.
- **Stale overage state after subscription downgrade.** The ledger is keyed by episode; just `rm ~/.claude/costs/overage_state.json` to clear the in-progress episode (archived history at `overages.json` is preserved).
- **Ahead/behind never shows.** Default branch isn't `origin/main`. Edit the `origin/main...$git_branch` reference in `statusline-command.sh`.
