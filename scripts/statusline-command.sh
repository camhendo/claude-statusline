#!/usr/bin/env bash

# Claude Code Status Line Script
# See https://code.claude.com/docs/en/statusline for JSON structure

# Read JSON input from stdin
input=$(cat)

# ── Number formatting helpers ─────────────────────────────────────────────────

# Auto-scaling integer formatter (n → k → m). Used where sub-unit precision
# doesn't matter (context-window fill, duration pair).
format_num() {
    local n=$1
    [ -z "$n" ] && echo "" && return
    if [ $n -ge 1000000 ]; then
        echo "$((n / 1000000))m"
    elif [ $n -ge 1000 ]; then
        echo "$((n / 1000))k"
    else
        echo "$n"
    fi
}

# 2-decimal auto-scaling formatter for per-turn billable token counts. These
# numbers need to line up with cost calculations downstream, so precision
# matters — "2.41m" vs "2.48m" vs "2m" is the difference between "this turn
# cost me a dollar more than expected" and "nothing to see here."
format_num2() {
    local n=$1
    [ -z "$n" ] && echo "0.00" && return
    awk -v n="$n" 'BEGIN {
        if (n >= 1000000)    printf "%.2fm", n/1000000;
        else if (n >= 1000)  printf "%.2fk", n/1000;
        else                 printf "%.2f",  n;
    }'
}

# ── Color helpers ─────────────────────────────────────────────────────────────
# Cost-awareness is the whole point of this refresh. Color is the fastest way
# to draw the eye to a number that's gone sideways. Two kinds of color logic:
#
#   1. Tiered scales (green → yellow → red) for continuous values like session
#      cost, burn rate, and context-window fill. Drivers cross visible tiers
#      so a glance is enough to gauge "am I in trouble yet?"
#   2. Boolean thresholds for alert-only cases (last_cost > $1 flips to red,
#      avg_cost > $1 flips to a *brighter* red signalling sustained trouble).

# ANSI 256-color palette, named so the thresholds below read clearly.
C_SAFE=114      # mint green
C_LOW=148       # yellow-green
C_MED=220       # gold
C_HIGH=208      # orange
C_ALERT=203     # red-orange  (single-turn concern)
C_CRIT=196      # bright red  (sustained pattern)
C_LABEL=153     # pale cyan (labels stay constant for readability)
C_PIPE=183      # lavender separators
C_DIM=2         # dim (for secondary info like rolling avg)

# Tiered scale: four thresholds split the domain into five color bands.
# Usage: scale <value> <t1> <t2> <t3> <t4>
color_scale() {
    awk -v v="$1" -v t1="$2" -v t2="$3" -v t3="$4" -v t4="$5" \
        -v safe="$C_SAFE" -v low="$C_LOW" -v med="$C_MED" \
        -v high="$C_HIGH" -v alert="$C_ALERT" 'BEGIN {
        if      (v < t1) print safe
        else if (v < t2) print low
        else if (v < t3) print med
        else if (v < t4) print high
        else             print alert
    }'
}

# Boolean threshold: pick one of two colors by whether value is at/above t.
color_above() {
    awk -v v="$1" -v t="$2" -v low="$3" -v high="$4" 'BEGIN {
        if (v >= t) print high; else print low
    }'
}

# Render a proportional bar (█ filled, ░ empty) of a given width.
# Width defaults to 10 for the rate-limit bars on line 4.
render_bar() {
    local pct=$1 width=${2:-10}
    awk -v p="$pct" -v w="$width" 'BEGIN {
        filled = int((p * w) / 100 + 0.5)
        if (filled > w) filled = w
        if (filled < 0) filled = 0
        for (i = 0; i < filled; i++) printf "█"
        for (i = 0; i < w - filled; i++) printf "░"
    }'
}

# Convert a unix epoch "resets at" timestamp to a compact relative-time string
# like "2h 15m" or "38m" showing time remaining. If the timestamp is in the
# past (rate limit has reset), returns "now".
format_reset_in() {
    local target=$1
    local now
    now=$(date +%s)
    awk -v t="$target" -v n="$now" 'BEGIN {
        diff = t - n
        if (diff <= 0) { print "now"; exit }
        h = int(diff / 3600)
        m = int((diff % 3600) / 60)
        if (h > 0) printf "%dh %dm", h, m
        else       printf "%dm",      m
    }'
}

# ── Extract data from JSON ────────────────────────────────────────────────────
dir=$(echo "$input" | jq -r '.workspace.current_dir // empty')
dir_name=$(basename "$dir" 2>/dev/null || echo "unknown")
model=$(echo "$input" | jq -r '.model.display_name // empty')

# Rate-limit info (5-hour + 7-day quotas). Populated by Claude Code itself;
# we derive bar/reset-time for line 4.
rl_5h_pct=$(echo "$input"    | jq -r '.rate_limits.five_hour.used_percentage // empty')
rl_5h_reset=$(echo "$input"  | jq -r '.rate_limits.five_hour.resets_at        // empty')
rl_7d_pct=$(echo "$input"    | jq -r '.rate_limits.seven_day.used_percentage // empty')
rl_7d_reset=$(echo "$input"  | jq -r '.rate_limits.seven_day.resets_at        // empty')

# Claude Code exposes its own 200k-context degradation flag. We use it to
# tint line 3 whenever we cross that boundary, regardless of model.
exceeds_200k=$(echo "$input" | jq -r '.exceeds_200k_tokens // false')

# Cost section
total_cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
total_duration=$(echo "$input" | jq -r '.cost.total_duration_ms // empty')
lines_added=$(echo "$input" | jq -r '.cost.total_lines_added // empty')
lines_removed=$(echo "$input" | jq -r '.cost.total_lines_removed // empty')

# Per-turn state written by track-turn-cost.sh on Stop (per-session file)
session_id=$(echo "$input" | jq -r '.session_id // empty')
last_msg_cost=''
avg_msg_cost=''
turn_count_val=''
turn_input=''
turn_output=''
turn_cache_read=''
turn_cache_write=''
turn_duration_ms=''
if [ -n "$session_id" ]; then
    live_turn_file="$HOME/.claude/costs/live_turn_${session_id}.json"
    if [ -f "$live_turn_file" ]; then
        last_msg_cost=$(jq       -r '.last_cost        // empty' "$live_turn_file" 2>/dev/null)
        avg_msg_cost=$(jq        -r '.avg_cost         // empty' "$live_turn_file" 2>/dev/null)
        turn_count_val=$(jq      -r '.turn_count       // empty' "$live_turn_file" 2>/dev/null)
        turn_input=$(jq          -r '.turn_input       // empty' "$live_turn_file" 2>/dev/null)
        turn_output=$(jq         -r '.turn_output      // empty' "$live_turn_file" 2>/dev/null)
        turn_cache_read=$(jq     -r '.turn_cache_read  // empty' "$live_turn_file" 2>/dev/null)
        turn_cache_write=$(jq    -r '.turn_cache_write // empty' "$live_turn_file" 2>/dev/null)
        turn_duration_ms=$(jq    -r '.turn_duration_ms // empty' "$live_turn_file" 2>/dev/null)
    fi
fi

# Context window section
total_input=$(echo "$input" | jq -r '.context_window.total_input_tokens // empty')
total_output=$(echo "$input" | jq -r '.context_window.total_output_tokens // empty')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
max_tokens=$(echo "$input" | jq -r '.context_window.context_window_size // empty')

# ── Billing mode detection ────────────────────────────────────────────────────
# Single source of truth: ~/.claude.json's oauthAccount.billingType.
#   "stripe_subscription" → account-based (Max/Pro/Team; subscription covers
#                                          usage, with possible overage billing)
#   anything else          → api-based   (pay-per-token; no rate_limits)
# The statusline refreshes sub-second; re-reading ~/.claude.json each time is
# cheap, but we still cache to /tmp to skip the disk hit when it hasn't changed.
_billing_cache="/tmp/claude_statusline_billing_mode"
billing_mode=''
if [ -f "$_billing_cache" ] && [ -s "$_billing_cache" ]; then
    # Cache TTL = 1h (subscription changes are rare; this is just a soft ceiling
    # on how long bad state can persist if someone flips modes mid-session).
    _age=$(( $(date +%s) - $(stat -f %m "$_billing_cache" 2>/dev/null \
                           || stat -c %Y "$_billing_cache" 2>/dev/null \
                           || echo 0) ))
    [ "$_age" -lt 3600 ] && billing_mode=$(cat "$_billing_cache")
fi
if [ -z "$billing_mode" ]; then
    _btype=$(jq -r '.oauthAccount.billingType // empty' "$HOME/.claude.json" 2>/dev/null)
    if [ "$_btype" = "stripe_subscription" ]; then
        billing_mode="account"
    else
        billing_mode="api"
    fi
    echo "$billing_mode" > "$_billing_cache" 2>/dev/null || true
fi

# ── Rate-limit snapshot for the Stop hook ─────────────────────────────────────
# track-turn-cost.sh runs on Stop and does not receive rate_limits in its input
# — it only gets session_id + transcript_path. We write what we know here so
# the hook can decide whether overage tracking is active. Only meaningful for
# account-billed users; skip writing for API users (they have no rate_limits).
if [ "$billing_mode" = "account" ] && [ -n "$rl_5h_pct" ] && [ -n "$rl_5h_reset" ]; then
    _costs_dir="$HOME/.claude/costs"
    mkdir -p "$_costs_dir" 2>/dev/null || true
    _snapshot_tmp="$_costs_dir/rl_snapshot.json.tmp.$$"
    jq -n \
        --argjson pct5 "$rl_5h_pct" \
        --arg     rst5 "$rl_5h_reset" \
        --argjson pct7 "${rl_7d_pct:-0}" \
        --arg     rst7 "${rl_7d_reset:-}" \
        --arg     ts   "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{five_hour_pct: $pct5, five_hour_resets_at: $rst5,
          seven_day_pct: $pct7, seven_day_resets_at: $rst7,
          updated_at: $ts}' \
        > "$_snapshot_tmp" 2>/dev/null \
      && mv "$_snapshot_tmp" "$_costs_dir/rl_snapshot.json" 2>/dev/null \
      || rm -f "$_snapshot_tmp" 2>/dev/null
fi

# ── Overage state (read-only; hook owns writes) ───────────────────────────────
# Three values derived from overage_state.json:
#   overage_total_usd     — cross-session aggregate (trailing number on L4)
#   session_overage_usd   — THIS session's post-crossover spend (leading $ on L4).
#                           Empty if the hook hasn't registered this session yet
#                           (small window during the first post-crossover turn).
#   overage_state_exists  — 1 only if the state file is present. When 0 we know
#                           the Stop hook hasn't written any overage state yet
#                           for the current episode. In that case the renderer
#                           shows an explicit warning on L4 rather than a
#                           misleading "$0.00" aggregate. The file gets created
#                           automatically on the first Stop hook fire after the
#                           threshold crosses, so this is a transient state.
#
# Episode trigger: in_overage=1 iff EITHER 5h OR 7d rate-limit is >=100%. The
# episode persists until BOTH drop below 100% again. Matches the Stop hook's
# episode-model gating so the two stay in sync.
in_overage=0
overage_total_usd=''
session_overage_usd=''
overage_state_exists=0
if [ "$billing_mode" = "account" ] && [ -n "$rl_5h_pct" ]; then
    in_overage=$(awk -v p5="$rl_5h_pct" -v p7="${rl_7d_pct:-0}" \
        'BEGIN { print (p5 >= 100 || p7 >= 100) ? 1 : 0 }')
    if [ "$in_overage" -eq 1 ] && [ -f "$HOME/.claude/costs/overage_state.json" ]; then
        overage_state_exists=1
        overage_total_usd=$(jq -r '.total_overage_usd // 0' \
            "$HOME/.claude/costs/overage_state.json" 2>/dev/null)
        if [ -n "$session_id" ]; then
            session_overage_usd=$(jq -r --arg sid "$session_id" \
                '.sessions[$sid].current_overage_usd // empty' \
                "$HOME/.claude/costs/overage_state.json" 2>/dev/null)
        fi
    fi
fi

# ── Git information ───────────────────────────────────────────────────────────
git_branch=''
git_ahead_behind=''
repo_name=''
if [ -n "$dir" ] && [ -d "$dir" ]; then
    repo_root=$(cd "$dir" 2>/dev/null && git -c core.useBuiltinFSMonitor=false -c core.fsmonitor=false rev-parse --show-toplevel 2>/dev/null)
    if [ -n "$repo_root" ]; then
        # Identify the MAIN worktree regardless of where on disk the current
        # checkout lives. `git worktree list --porcelain` always emits the main
        # worktree first (git-worktree(1)), so we don't need path heuristics
        # like */.worktrees/*. Works for: main checkout, kluein `gw` worktrees,
        # `git worktree add` placed anywhere on disk, and submodules (the
        # submodule's own worktree list starts with the submodule root, which
        # matches previous behavior for that case).
        main_worktree=$(cd "$dir" 2>/dev/null && git -c core.useBuiltinFSMonitor=false -c core.fsmonitor=false worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')
        if [ -n "$main_worktree" ]; then
            repo_name=$(basename "$main_worktree")
        else
            repo_name=$(basename "$repo_root")
        fi
    else
        repo_name="$dir_name"
    fi
    git_branch=$(cd "$dir" 2>/dev/null && git -c core.useBuiltinFSMonitor=false -c core.fsmonitor=false branch --show-current 2>/dev/null)
    if [ -n "$git_branch" ]; then
        ahead_behind=$(cd "$dir" 2>/dev/null && git -c core.useBuiltinFSMonitor=false -c core.fsmonitor=false rev-list --left-right --count origin/main...$git_branch 2>/dev/null)
        if [ -n "$ahead_behind" ]; then
            behind=$(echo "$ahead_behind" | awk '{print $1}')
            ahead=$(echo "$ahead_behind" | awk '{print $2}')
            if [ "$ahead" != "0" ] || [ "$behind" != "0" ]; then
                git_ahead_behind=" (+$ahead/-$behind)"
            fi
        fi
    fi
fi

# ── Format duration ───────────────────────────────────────────────────────────
duration_human=''
if [ -n "$total_duration" ]; then
    total_sec=$((total_duration / 1000))
    hours=$((total_sec / 3600))
    minutes=$(((total_sec % 3600) / 60))
    seconds=$((total_sec % 60))
    if [ $hours -gt 0 ]; then
        duration_human="${hours}h ${minutes}m"
    elif [ $minutes -gt 0 ]; then
        duration_human="${minutes}m ${seconds}s"
    else
        duration_human="${seconds}s"
    fi
fi

# ── Format numbers ────────────────────────────────────────────────────────────
total_input_fmt=$(format_num "$total_input")
total_output_fmt=$(format_num "$total_output")
max_tokens_fmt=$(format_num "$max_tokens")

cost_fmt=''
if [ -n "$total_cost" ]; then
    cost_fmt=$(printf "%.3f" "$total_cost")
fi

# Separator (lavender)
pipe="\033[38;5;${C_PIPE}m|\033[0m"

# === LINE 1: repo | dir | branch | ahead/behind ==============================
line1="\033[38;5;${C_LABEL}m${repo_name:-$dir_name}\033[0m"
# Suppress dir_name when it duplicates the branch name. Under the kluein `gw`
# convention, worktree dirs are named after their branch (e.g.
# .worktrees/cam-feat-foo holds branch cam-feat-foo), which would otherwise
# print the same string twice on L1 in different colors. For non-kluein
# worktrees where the dir and branch diverge, both still render.
if [ -n "$repo_name" ] && [ "$dir_name" != "$repo_name" ] \
   && [ "$dir_name" != "$git_branch" ]; then
    line1="$line1 \033[38;5;${C_PIPE}m${dir_name}\033[0m"
fi
if [ -n "$git_branch" ]; then
    line1="$line1 \033[38;5;${C_SAFE}m${git_branch}\033[0m"
    if [ -n "$git_ahead_behind" ]; then
        line1="$line1\033[${C_DIM}m${git_ahead_behind}\033[0m"
    fi
fi

# === COST SEGMENTS ===========================================================
# The cost run on line 2 / line 4 is built in two layers:
#
#   cost_seg_total    — the leading "$X.XXX" session-total figure. ONLY used on
#                       API-mode line 2. For account-overage line 4 we use the
#                       session's post-crossover contribution (session_overage)
#                       instead, so pre-overage spend doesn't leak onto the
#                       "you are paying real dollars now" line.
#   perturn_segments  — "↑$last ~$avg xN | $burn/m". Shared verbatim between
#                       API line 2 and account-overage line 4. These are
#                       per-turn metrics — the last-turn cost is intrinsically
#                       post-crossover when we're in overage (latest turn ≡
#                       overage turn), and the session-wide rolling avg is left
#                       intact on purpose: chopping it at crossover would skew
#                       the avg, and the crossover turn's cost is already
#                       surfaced via session_overage and ↑$last.
#
# Final cost_segments = cost_seg_total + perturn_segments (pipe-joined).
# API mode line 2 uses cost_segments. Overage line 4 builds its own variant
# using session_overage in place of cost_seg_total.

# --- Session total segment (API mode only) -----------------------------------
# Thresholds chosen for active dev sessions on Opus 4.6: <$1 is cheap, >$25 is
# "you are paying for a small coffee per prompt, maybe reconsider."
cost_seg_total=''
if [ -n "$cost_fmt" ]; then
    total_color=$(color_scale "$total_cost" 1 5 10 25)
    cost_seg_total="\033[38;5;${total_color}m\$${cost_fmt}\033[0m"
fi

# --- Per-turn segments (last/avg + burn rate), shared ------------------------
perturn_segments=''

# Last-turn cost + rolling avg.
# last_cost: red above $1 (alert: one expensive turn), keep label color otherwise.
# avg_cost:  bright red above $1 (critical: EVERY turn is averaging >$1).
if [ -n "$last_msg_cost" ] && [ -n "$avg_msg_cost" ]; then
    last_fmt=$(printf "%.3f" "$last_msg_cost")
    avg_fmt=$(printf "%.3f" "$avg_msg_cost")
    turn_label=''
    if [ -n "$turn_count_val" ]; then
        turn_label="x${turn_count_val}"
    fi
    arrow=$(awk -v last="$last_msg_cost" -v avg="$avg_msg_cost" \
        'BEGIN { if (avg > 0 && last > avg * 1.05) print "↑"; else if (avg > 0 && last < avg * 0.95) print "↓"; else print "→" }')

    last_color=$(color_above "$last_msg_cost" 1  "$C_LABEL" "$C_ALERT")
    avg_color=$(color_above  "$avg_msg_cost"  1  "$C_DIM"   "$C_CRIT")

    perturn_segments="\033[38;5;${last_color}m${arrow}\$${last_fmt}\033[0m"
    if [ "$avg_color" = "$C_DIM" ]; then
        # Dim styling for the normal case (no 38;5 color, just dim attr)
        perturn_segments="${perturn_segments} \033[${C_DIM}m~\$${avg_fmt}${turn_label}\033[0m"
    else
        perturn_segments="${perturn_segments} \033[38;5;${avg_color}m~\$${avg_fmt}${turn_label}\033[0m"
    fi
fi

# Turn burn rate ($/min for the last completed turn). Tiered scale.
# Thresholds: <$0.10/min is fine, >$1/min means you're burning serious money per
# minute of wall clock — the runaway-tool-loop signature.
burn_rate=''
if [ -n "$last_msg_cost" ] && [ -n "$turn_duration_ms" ] && [ "$turn_duration_ms" -gt 0 ]; then
    burn_rate=$(awk -v c="$last_msg_cost" -v ms="$turn_duration_ms" \
        'BEGIN { printf "%.2f", (c / (ms / 60000.0)) }')
    rate_color=$(color_scale "$burn_rate" 0.10 0.25 0.50 1.00)
    [ -n "$perturn_segments" ] && perturn_segments="$perturn_segments $pipe "
    perturn_segments="${perturn_segments}\033[38;5;${rate_color}m\$${burn_rate}/m\033[0m"
fi

# --- Assemble cost_segments for API mode -------------------------------------
cost_segments=''
if [ -n "$cost_seg_total" ]; then
    cost_segments="$cost_seg_total"
fi
if [ -n "$perturn_segments" ]; then
    [ -n "$cost_segments" ] && cost_segments="$cost_segments $pipe "
    cost_segments="${cost_segments}${perturn_segments}"
fi

# === LINE 2: [cost segments |] duration | +/- | model ========================
# Cost segments appear only for API users; account users get them on the
# overage line (L4) when applicable and hide them completely otherwise.
line2=''
if [ "$billing_mode" = "api" ]; then
    line2="$cost_segments"
fi

# Duration
if [ -n "$duration_human" ]; then
    [ -n "$line2" ] && line2="$line2 $pipe "
    line2="${line2}\033[38;5;209m${duration_human}\033[0m"
fi

# Lines added/removed
if [ -n "$lines_added" ] || [ -n "$lines_removed" ]; then
    [ -n "$line2" ] && line2="$line2 $pipe "
    line2="${line2}\033[38;5;${C_SAFE}m+${lines_added:-0}\033[0m/\033[38;5;${C_PIPE}m-${lines_removed:-0}\033[0m"
fi

# Model
if [ -n "$model" ]; then
    [ -n "$line2" ] && line2="$line2 $pipe "
    line2="${line2}\033[38;5;209m${model}\033[0m"
fi

# === LINE 3: last-turn tokens | window =======================================
line3=''

cr_fmt=$(format_num2 "$turn_cache_read")
cw_fmt=$(format_num2 "$turn_cache_write")
r_fmt=$(format_num2 "$turn_input")
w_fmt=$(format_num2 "$turn_output")

line3="\033[38;5;${C_LABEL}mc-read:\033[0m${cr_fmt}"
line3="${line3} \033[38;5;${C_LABEL}mc-write:\033[0m${cw_fmt}"
line3="${line3} \033[38;5;${C_LABEL}mread:\033[0m${r_fmt}"
line3="${line3} \033[38;5;${C_LABEL}mwrite:\033[0m${w_fmt}"

# Window fill — tiered scale centered on 200k, which is the threshold where
# Opus-4.6 (and most Claude models) start showing attention degradation. Above
# 200k the cost per turn also grows linearly because every API call re-reads
# the now-much-larger cached prefix. Scale goes green → red beyond that.
if [ -n "$used_pct" ] && [ -n "$max_tokens" ]; then
    window_used=$(( (used_pct * max_tokens) / 100 ))
    window_used_fmt=$(format_num "$window_used")
    # Thresholds in tokens: 100k, 200k (degradation begins), 400k, 700k
    window_color=$(color_scale "$window_used" 100000 200000 400000 700000)
    line3="${line3} \033[38;5;${window_color}mwindow:\033[0m\033[38;5;${window_color}m${window_used_fmt}/${max_tokens_fmt}\033[0m"
fi

# === LINE 4: rate-limit usage bars (5-hour + 7-day windows) ==================
# Claude Code exposes two quota windows via .rate_limits: a rolling 5-hour and
# a rolling 7-day cap. Both ship {used_percentage, resets_at}. We render each
# as a 10-char bar with its % and time-until-reset so the user can glance down
# and know "am I burning this session too fast for my 5-hour window?"
#
# Bar color tiers (same scale applied to both windows):
#   < 50% safe, 50-70% low, 70-85% med, 85-95% high, > 95% alert.
# The 7-day window tends to move slowly; the 5-hour is the one that catches
# runaway sessions — this is the signal the user specifically wants visible.
line4=''
build_rl_segment() {
    local label=$1 pct=$2 reset_ts=$3
    [ -z "$pct" ] && return
    local bar color reset_str
    bar=$(render_bar "$pct" 10)
    color=$(color_scale "$pct" 50 70 85 95)
    if [ -n "$reset_ts" ]; then
        reset_str=" r:$(format_reset_in "$reset_ts")"
    else
        reset_str=""
    fi
    # Claude Code can ship fractional percentages (e.g. 28.999999999999996 for
    # the 7-day window), so use %.0f instead of %d — bash printf errors on
    # floats fed to %d and silently substitutes 0.
    printf "\033[38;5;%dm%s\033[0m \033[38;5;%dm%s\033[0m %3.0f%%\033[%dm%s\033[0m" \
        "$C_LABEL" "$label" "$color" "$bar" "$pct" "$C_DIM" "$reset_str"
}

if [ -n "$rl_5h_pct" ]; then
    seg_5h=$(build_rl_segment "5h" "$rl_5h_pct" "$rl_5h_reset")
    line4="$seg_5h"
fi
if [ -n "$rl_7d_pct" ]; then
    seg_7d=$(build_rl_segment "7d" "$rl_7d_pct" "$rl_7d_reset")
    [ -n "$line4" ] && line4="$line4 $pipe "
    line4="${line4}${seg_7d}"
fi

# === OVERAGE LINE (account mode, either 5h OR 7d limit crossed) ==============
# Layout:
#
#   overages: $<session overage> | ↑$<last> ~$<avg>xN | $<burn>/m | $<aggregate>
#   ^^^^^^^^^ ^^^^^^^^^^^^^^^^^^                                    ^^^^^^^^^^^^
#   C_CRIT    session's post-                                       cross-session
#   label     crossover spend                                       total (C_CRIT)
#
# KEY SEMANTIC CHOICE: the first $ figure is this session's POST-CROSSOVER
# overage contribution (from overage_state.json), NOT the session total. Pre-
# overage spend was covered by the subscription and intentionally does NOT leak
# onto this line — the user's mental model while reading this line is "how
# much am I currently over by?", not "how much total have I ever spent?"
#
# The per-turn metrics (↑$last, ~$avg xN, burn rate) are reused from the shared
# perturn_segments:
#   - ↑$last and burn rate are intrinsically post-crossover when we're in
#     overage (the latest turn IS an overage turn).
#   - ~$avg xN is deliberately LEFT session-wide. Chopping it at the crossover
#     would skew the statistic, and the crossover-turn's cost is already
#     surfaced via $session_overage and ↑$last.
#
# Degenerate forms handled:
#   - Hook hasn't registered this session yet → omit session-overage figure
#     and its pipe separator. Line collapses to "overages: <perturn> | $agg".
#   - No per-turn data yet (brand-new session)  → omit perturn chunk. Line
#     collapses to "overages: $session_overage | $agg" or just "overages: $agg".
line_overage=''
if [ "$billing_mode" = "account" ] && [ "$in_overage" -eq 1 ]; then
    line_overage="\033[38;5;${C_CRIT}moverages:\033[0m"
    _lo_has_mid=0    # tracks whether anything has been appended after the label

    if [ "$overage_state_exists" -eq 0 ]; then
        # State file missing — the Stop hook hasn't recorded this episode
        # yet (either the threshold just crossed mid-turn, or a prior hook
        # run failed). Print an explicit warning so the user knows tracking
        # will populate on the next turn, rather than showing a misleading
        # "$0.00" aggregate that looks like a measured zero.
        line_overage="$line_overage \033[38;5;${C_ALERT}m⚠ state pending — populates after next turn\033[0m"
        _lo_has_mid=1
    elif [ -n "$session_overage_usd" ]; then
        # Session's post-crossover overage contribution (reuses the same tiered
        # color scale as the session-total figure on line 2 so the eye calibrates
        # on the same thresholds).
        sov_fmt=$(printf "%.3f" "$session_overage_usd")
        sov_color=$(color_scale "$session_overage_usd" 1 5 10 25)
        line_overage="$line_overage \033[38;5;${sov_color}m\$${sov_fmt}\033[0m"
        _lo_has_mid=1
    else
        # State file exists but this session_id isn't in the sessions map yet.
        # Happens when a session started before the episode began (5h or 7d
        # crossed 100%) and hasn't fired a Stop hook since. Next turn-end will
        # register it. Show an indicator so the absent leading $ is explained.
        line_overage="$line_overage \033[38;5;${C_ALERT}m⏳ session pending\033[0m"
        _lo_has_mid=1
    fi

    # Per-turn segments (last/avg + burn rate). These are derived from the
    # live_turn file and are independent of the overage state file, so they
    # render in both the warning and the populated cases.
    if [ -n "$perturn_segments" ]; then
        if [ "$_lo_has_mid" -eq 1 ]; then
            line_overage="$line_overage $pipe $perturn_segments"
        else
            line_overage="$line_overage $perturn_segments"
        fi
        _lo_has_mid=1
    fi

    # Trailing cross-session aggregate — only rendered when the ledger has
    # real data. In the warning branch the "state pending" text already
    # communicates that no measurement exists, so suppressing the $0.00
    # keeps the line honest.
    if [ "$overage_state_exists" -eq 1 ]; then
        over_fmt=$(printf "%.2f" "${overage_total_usd:-0}")
        if [ "$_lo_has_mid" -eq 1 ]; then
            line_overage="$line_overage $pipe \033[38;5;${C_CRIT}m\$${over_fmt}\033[0m"
        else
            line_overage="$line_overage \033[38;5;${C_CRIT}m\$${over_fmt}\033[0m"
        fi
    fi
fi

# === OUTPUT ==================================================================
# Layout depends on billing mode + overage state:
#   api                               → 3 lines (no rate bars; cost lives on line 2)
#   account, no limit >=100%          → 4 lines (rate bars as line 4)
#   account, 5h or 7d limit >=100%    → 5 lines (overage as line 4, rate bars as line 5)
# If rate_limits are missing (transient glitch), we degrade to the shorter
# layout for the mode — never print a blank line or hang on missing data.
case "$billing_mode" in
    api)
        printf "%b\n%b\n%b" "$line1" "$line2" "$line3"
        ;;
    account)
        if [ "$in_overage" -eq 1 ] && [ -n "$line_overage" ]; then
            if [ -n "$line4" ]; then
                printf "%b\n%b\n%b\n%b\n%b" "$line1" "$line2" "$line3" "$line_overage" "$line4"
            else
                printf "%b\n%b\n%b\n%b"      "$line1" "$line2" "$line3" "$line_overage"
            fi
        else
            if [ -n "$line4" ]; then
                printf "%b\n%b\n%b\n%b"      "$line1" "$line2" "$line3" "$line4"
            else
                printf "%b\n%b\n%b"          "$line1" "$line2" "$line3"
            fi
        fi
        ;;
    *)
        printf "%b\n%b\n%b" "$line1" "$line2" "$line3"
        ;;
esac
