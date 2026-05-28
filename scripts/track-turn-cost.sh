#!/usr/bin/env bash
# Stop hook: compute per-turn cost + token totals, plus rolling avg across all
# completed turns in the session. Writes ~/.claude/costs/live_turn_<sid>.json
# for the statusline.
#
# "Turn" = everything between two consecutive real user prompts (or between the
# last user prompt and end of transcript). An assistant message is assigned to
# the most recent user prompt whose timestamp precedes it — so one user prompt
# + 30 tool-use iterations all bucket into the same turn.
#
# After a compact the transcript resets, so "avg since last compact" is free
# behaviour — no special reset needed.
#
# ── Account-based overage tracking ────────────────────────────────────────────
# On subscription billing, the renderer writes ~/.claude/costs/rl_snapshot.json
# with the current 5-hour AND 7-day rate-limit percentages + resets_at. When
# EITHER limit is >=100%, this hook maintains a shared ledger of overage spend
# across all active sessions. Tracking is organized into "episodes": a maximal
# interval during which at least one limit is >=100%. An episode ends when
# both limits drop below 100% (typically at the reset of the keeping-alive
# limit). Each episode gets its own ledger row keyed by episode_start_unix.
# See the block marked "OVERAGE TRACKING" below.

set -euo pipefail

hook_input=$(cat)
session_id=$(echo "$hook_input" | jq -r '.session_id // "unknown"')
transcript_path=$(echo "$hook_input" | jq -r '.transcript_path // empty')

[[ -z "$transcript_path" || ! -f "$transcript_path" ]] && exit 0

# ── Parse transcript once: user prompt timestamps + deduped assistant msgs ────
# Real user prompts are distinguished from tool_result echoes / slash-command
# injections by `isMeta != true` and content-shape (string or first element of
# type "text" — tool_results fail that check).
# Assistant messages stream in chunks sharing an id; we keep the first seen
# usage record and only update `.out` to the max output_tokens observed.
parsed=$(jq -sc '
  {
    prompts: (
      [ .[]
        | select(.type == "user" and (.isMeta // false) != true)
        | select((.promptId // null) != null)
        | select(
            (.message.content | type) == "string"
            or ((.message.content | type) == "array"
                and (.message.content[0].type // "") == "text")
          )
        # An interrupt aborts the in-flight turn — it has a promptId and text
        # content, so the earlier filters let it through, but it never receives
        # an assistant reply. Treating it as a turn leaves a ghost bucket with
        # $0 cost as the "last turn", which is nonsense for the statusline.
        | select((
            if (.message.content | type) == "string"
            then .message.content
            else (.message.content[0].text // "")
            end) != "[Request interrupted by user]")
        | {pid: .promptId, ts: (.timestamp // "")}
      ]
      | map(select(.ts != ""))
      # One promptId spans many transcript entries (the prompt itself, tool
      # results, possibly resumes after compaction). Dedupe to the earliest
      # timestamp per promptId so each real user turn contributes one bucket.
      | group_by(.pid)
      | map({pid: .[0].pid, ts: (map(.ts) | min)})
      | sort_by(.ts)
      | map(.ts)
    ),
    msgs: (
      [ .[]
        | select(.type == "assistant" and (.message.id // "") != "")
        | {
            id:    .message.id,
            ts:    (.timestamp // ""),
            model: (.message.model // ""),
            usage: (.message.usage // {})
          }
      ]
      | reduce .[] as $m (
          {order: [], data: {}};
          if .data[$m.id] then
            .data[$m.id].out |= ([., ($m.usage.output_tokens // 0)] | max)
          else
            .order += [$m.id] |
            .data[$m.id] = {
              ts:      $m.ts,
              model:   $m.model,
              "in":    ($m.usage.input_tokens               // 0),
              out:     ($m.usage.output_tokens              // 0),
              cr:      ($m.usage.cache_read_input_tokens    // 0),
              cw_flat: ($m.usage.cache_creation_input_tokens // 0),
              cw_5m:   ($m.usage.cache_creation.ephemeral_5m_input_tokens // 0),
              cw_1h:   ($m.usage.cache_creation.ephemeral_1h_input_tokens // 0)
            }
          end
        )
      | .order as $order | .data as $data | $order | map($data[.])
    )
  }
' "$transcript_path") || exit 0

msg_count=$(echo "$parsed" | jq '.msgs | length')
[[ "$msg_count" -eq 0 ]] && exit 0

# ── Cost + turn-bucket assignment ─────────────────────────────────────────────
# Each assistant message is priced on its OWN .model field. This fixes two
# classes of drift from the old session-wide rate lookup:
#   1. Mid-session model switches (e.g. /model sonnet → /model opus). Old code
#      priced every message at one rate, over- or under-counting the other.
#   2. <synthetic> messages. They are not real API calls — we zero their cost
#      out entirely rather than billing them at a default Sonnet rate.
# Bucket = index of the latest user prompt whose timestamp precedes the
# message's timestamp (ISO-8601 sorts lexically). bucket == -1 = predates any
# prompt (startup noise) and is excluded from turn stats.
result=$(echo "$parsed" | jq '
  # Per-message rate table. Keys match substrings we find in .model.
  def rates($model):
    if   ($model | test("opus-4-6|opus-4-5"))     then {ip:  5.0, op: 25.0, crp: 0.5,  cw5p: 6.25,  cw1p: 10.0}
    elif ($model | test("sonnet-4"))              then {ip:  3.0, op: 15.0, crp: 0.3,  cw5p: 3.75,  cw1p:  6.0}
    elif ($model | test("haiku-4-5"))             then {ip:  1.0, op:  5.0, crp: 0.1,  cw5p: 1.25,  cw1p:  2.0}
    elif ($model | test("opus-4-1|opus-4-20"))    then {ip: 15.0, op: 75.0, crp: 1.5,  cw5p: 18.75, cw1p: 30.0}
    elif ($model | test("haiku-3-5"))             then {ip:  0.8, op:  4.0, crp: 0.08, cw5p: 1.0,   cw1p:  1.6}
    else                                               {ip:  3.0, op: 15.0, crp: 0.3,  cw5p: 3.75,  cw1p:  6.0}
    end;

  . as $p
  | $p.prompts as $prompts
  | ($prompts | length) as $nprompts
  | (($nprompts - 1)) as $last_bucket
  | $p.msgs
    | map(
        . as $m
        | (if ($m.cw_5m > 0 or $m.cw_1h > 0) then $m.cw_5m else $m.cw_flat end) as $c5
        | (if ($m.cw_5m > 0 or $m.cw_1h > 0) then $m.cw_1h else 0          end) as $c1
        # <synthetic> messages are not billable API calls; zero their cost.
        # Tokens still roll up into the turn total for line 3 since those
        # numbers describe work visible in the transcript, but dollars do not.
        | (if $m.model == "<synthetic>" then
             0
           else
             rates($m.model) as $r
             | ($m."in" / 1e6 * $r.ip
               + $m.out  / 1e6 * $r.op
               + $m.cr   / 1e6 * $r.crp
               + $c5     / 1e6 * $r.cw5p
               + $c1     / 1e6 * $r.cw1p)
           end) as $cost
        | ($c5 + $c1) as $cw
        | ([range(0; $nprompts) | select($prompts[.] <= $m.ts)] | length - 1) as $bucket
        | {ts: $m.ts, "in": $m."in", out: $m.out, cr: $m.cr, cw: $cw, cost: $cost, bucket: $bucket}
      )
    | . as $msgs
    | ($msgs | map(select(.bucket >= 0)) | group_by(.bucket)) as $turns
    | {
        turn_count:    ($turns | length),
        avg_turn_cost: (
          if ($turns | length) > 0 then
            (($turns | map(map(.cost) | add) | add) / ($turns | length))
          else 0 end
        ),
        # Session-total cost = sum of all billable cost across every completed
        # turn in the session. Used by the overage-tracking block below to
        # snapshot a baseline when the 5-hour rate-limit crosses 100%.
        session_total_cost: (
          if ($turns | length) > 0 then
            (($turns | map(map(.cost) | add) | add) // 0)
          else 0 end
        ),
        last_turn: (
          ($msgs | map(select(.bucket == $last_bucket))) as $last
          | if ($last | length) > 0 then {
              cost: (($last | map(.cost) | add) // 0),
              "in": (($last | map(."in") | add) // 0),
              out:  (($last | map(.out)  | add) // 0),
              cr:   (($last | map(.cr)   | add) // 0),
              cw:   (($last | map(.cw)   | add) // 0),
              # Turn duration = from the prompt that started this bucket to the
              # last assistant message in it. Used for $/min burn-rate on line 2.
              # Falls back to 0 if it cannot be computed (e.g. single-msg turn
              # where prompt ts equals assistant ts to the millisecond).
              duration_ms: (
                # Strip sub-second precision before fromdateiso8601 — it only
                # accepts "...Z", not "....272Z". We lose up to 1s of precision
                # per endpoint, which is fine for the minute-scale burn rate.
                def parse_ts: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
                ($last | map(.ts) | max) as $end
                | $prompts[$last_bucket] as $start
                | if ($end != null and $start != null) then
                    ((($end | parse_ts) - ($start | parse_ts)) * 1000 | floor)
                  else 0 end
              )
            }
            else {cost: 0, "in": 0, out: 0, cr: 0, cw: 0, duration_ms: 0}
            end
        )
      }
')

turn_cost=$(echo          "$result" | jq -r '.last_turn.cost         // 0')
session_total_cost=$(echo "$result" | jq -r '.session_total_cost     // 0')
avg_turn_cost=$(echo      "$result" | jq -r '.avg_turn_cost          // 0')
turn_count=$(echo         "$result" | jq -r '.turn_count             // 0')
turn_in=$(echo            "$result" | jq -r '.last_turn."in"         // 0')
turn_out=$(echo           "$result" | jq -r '.last_turn.out          // 0')
turn_cr=$(echo            "$result" | jq -r '.last_turn.cr           // 0')
turn_cw=$(echo            "$result" | jq -r '.last_turn.cw           // 0')
turn_duration_ms=$(echo   "$result" | jq -r '.last_turn.duration_ms  // 0')

# ── Write per-session state file ──────────────────────────────────────────────
costs_dir="$HOME/.claude/costs"
mkdir -p "$costs_dir"

# Prune per-session files older than 7 days (runs quietly, never fails)
find "$costs_dir" -name 'live_turn_*.json' -mtime +7 -delete 2>/dev/null || true

# Field names preserved for statusline backward-compat: `last_cost` now holds
# the last turn's cost (was: last message cost), `avg_cost` holds avg per turn
# (was: avg per message), `turn_count` now counts user prompts (was: message
# ids). The statusline reads these same keys so no change needed there.
jq -n \
  --arg     sid      "$session_id" \
  --argjson last     "$turn_cost" \
  --argjson avg      "$avg_turn_cost" \
  --argjson stc      "$session_total_cost" \
  --argjson cnt      "$turn_count" \
  --argjson turn_in  "$turn_in" \
  --argjson turn_out "$turn_out" \
  --argjson turn_cr  "$turn_cr" \
  --argjson turn_cw  "$turn_cw" \
  --argjson turn_ms  "$turn_duration_ms" \
  --arg     ts       "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    session_id:         $sid,
    last_cost:          $last,
    avg_cost:           $avg,
    session_total_cost: $stc,
    turn_count:         $cnt,
    turn_input:         $turn_in,
    turn_output:        $turn_out,
    turn_cache_read:    $turn_cr,
    turn_cache_write:   $turn_cw,
    turn_duration_ms:   $turn_ms,
    updated_at:         $ts
   }' \
  > "$costs_dir/live_turn_${session_id}.json"

# ═════════════════════════════════════════════════════════════════════════════
# OVERAGE TRACKING (account-based users only; best-effort)
# ═════════════════════════════════════════════════════════════════════════════
# Episode model: an "episode" is a maximal interval during which at least one
# of {5h, 7d} rate-limit %  is >=100. Each episode gets its own ledger row
# keyed by episode_start_unix, with per-session baselines captured at episode
# start. Baselines are NEVER re-captured mid-episode, so total_overage_usd
# stays a pure function of (session_total_cost - baseline).
#
# Runs after the per-session file is safely written. Any failure here must NOT
# lose the per-session state above, so the whole block is wrapped `|| true`.
(
  set +e

  # Billing gate: only stripe_subscription (Max/Pro/Team) users can incur
  # overage. Everyone else exits cleanly.
  billing_type=$(jq -r '.oauthAccount.billingType // empty' "$HOME/.claude.json" 2>/dev/null)
  [[ "$billing_type" != "stripe_subscription" ]] && exit 0

  # The renderer writes rl_snapshot.json on every refresh. If it doesn't exist,
  # the user hasn't opened a Claude Code session recently — nothing to track.
  rl_snapshot="$costs_dir/rl_snapshot.json"
  [[ ! -f "$rl_snapshot" ]] && exit 0

  five_hour_pct=$(jq -r    '.five_hour_pct       // 0'     "$rl_snapshot" 2>/dev/null)
  five_hour_resets=$(jq -r '.five_hour_resets_at // empty' "$rl_snapshot" 2>/dev/null)
  seven_day_pct=$(jq -r    '.seven_day_pct       // 0'     "$rl_snapshot" 2>/dev/null)
  seven_day_resets=$(jq -r '.seven_day_resets_at // empty' "$rl_snapshot" 2>/dev/null)
  [[ -z "$five_hour_resets" ]] && exit 0

  # Episode trigger: EITHER 5h or 7d at/above 100%.
  five_h_hit=$(awk  -v p="$five_hour_pct" 'BEGIN { print (p >= 100) ? 1 : 0 }')
  seven_d_hit=$(awk -v p="$seven_day_pct" 'BEGIN { print (p >= 100) ? 1 : 0 }')
  cur_in_overage=$(( five_h_hit || seven_d_hit ))

  state_file="$costs_dir/overage_state.json"
  ledger_file="$costs_dir/overages.json"

  # Nothing to do: not in overage AND no lingering state to close out.
  [[ "$cur_in_overage" -eq 0 && ! -f "$state_file" ]] && exit 0

  now_iso=$(date -u "+%Y-%m-%dT%H:%M:%SZ")
  now_unix=$(date -u +%s)

  # Convert a resets_at value (epoch string or ISO-8601) to unix seconds.
  # Claude Code has shipped both formats; we accept either transparently.
  to_unix() {
      local v=$1
      [[ -z "$v" || "$v" = "null" ]] && { echo ""; return; }
      if [[ "$v" =~ ^[0-9]+$ ]]; then
          echo "$v"
      else
          jq -rn --arg t "$v" 'def p: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601; $t | p' 2>/dev/null || echo ""
      fi
  }

  # Convert a unix seconds value to ISO-8601. BSD (`-r`) first, then GNU (`-d @`).
  to_iso() {
      local u=$1
      [[ -z "$u" || "$u" = "null" ]] && { echo ""; return; }
      date -u -r "$u" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
        || date -u -d "@$u" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
        || echo ""
  }

  # Finalize the in-memory state object as a closed episode in the ledger, then
  # delete the live state file. end_ts (ISO-8601) marks when the episode ended.
  finalize_episode() {
      local state_json=$1 end_ts=$2
      local ep_start ep_start_unix entry
      ep_start=$(echo "$state_json" | jq -r '.episode_start_ts')
      ep_start_unix=$(jq -rn --arg t "$ep_start" \
          'def p: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601; $t | p' 2>/dev/null)
      [[ -z "$ep_start_unix" || "$ep_start_unix" = "null" ]] && return 1
      [[ ! -f "$ledger_file" ]] && echo '{}' > "$ledger_file"
      entry=$(echo "$state_json" | jq --arg end "$end_ts" \
          '{episode_start: .episode_start_ts,
            episode_end:   $end,
            triggers:      (.triggers_ever // []),
            total_overage_usd: (.total_overage_usd // 0),
            sessions:      (.sessions // {})}')
      jq --arg k "$ep_start_unix" --argjson e "$entry" \
         '. + {($k): $e}' "$ledger_file" > "$ledger_file.tmp" \
        && mv "$ledger_file.tmp" "$ledger_file"
      rm -f "$state_file"
  }

  lock_dir="$state_file.lock"

  # Portable mkdir-based lock (no flock dependency on macOS).
  # 100 * 50ms = 5s max wait; after that we proceed anyway to avoid blocking
  # the hook indefinitely on a stale lock.
  acquired=0
  for _ in $(seq 1 100); do
      mkdir "$lock_dir" 2>/dev/null && { acquired=1; break; }
      sleep 0.05
  done
  trap 'rmdir "'"$lock_dir"'" 2>/dev/null' EXIT HUP INT TERM

  # ── Load existing state (and migrate from old schema in place) ──────────────
  # Old schema (5h-window-only): {window_key, window_start_iso, window_end_iso,
  #                               crossover_ts, sessions, total_overage_usd}
  # New schema (episode):        {episode_start_ts, active_triggers, triggers_ever,
  #                               seen_resets, sessions, total_overage_usd}
  #
  # If we encounter the old schema, we handle it one of two ways:
  #   (a) Old 5h window has already ended (window_end_iso <= now_unix) → finalize
  #       as a closed episode ending at window_end_iso, assume trigger was 5h.
  #   (b) Old 5h window is still live → rewrite the state object in place to the
  #       new schema, preserving sessions + total_overage_usd verbatim so the
  #       in-flight $ value is not lost.
  existing_state=''
  if [[ -f "$state_file" ]]; then
      existing_state=$(cat "$state_file" 2>/dev/null)
      is_old_schema=$(echo "${existing_state:-null}" | jq -r \
          'if (type == "object" and .window_key != null and .episode_start_ts == null) then "yes" else "no" end' 2>/dev/null)
      if [[ "$is_old_schema" = "yes" ]]; then
          old_window_end_iso=$(echo "$existing_state" | jq -r '.window_end_iso // empty')
          old_window_end_unix=$(to_unix "$old_window_end_iso")
          if [[ -n "$old_window_end_unix" && "$old_window_end_unix" -le "$now_unix" ]]; then
              closed_state=$(echo "$existing_state" | jq \
                  '{episode_start_ts: .crossover_ts,
                    triggers_ever:    ["five_hour"],
                    sessions:         .sessions,
                    total_overage_usd: .total_overage_usd}')
              finalize_episode "$closed_state" "$old_window_end_iso"
              existing_state=''
          else
              existing_state=$(echo "$existing_state" | jq \
                  --arg r5 "${old_window_end_iso:-$five_hour_resets}" \
                  --arg r7 "$seven_day_resets" \
                  '{episode_start_ts: .crossover_ts,
                    active_triggers:  {five_hour: true, seven_day: false},
                    triggers_ever:    ["five_hour"],
                    seen_resets:      {five_hour_at: $r5, seven_day_at: $r7},
                    sessions:         .sessions,
                    total_overage_usd: .total_overage_usd}')
          fi
      fi
  fi

  # ── Decide: finalize / restart / continue / start ───────────────────────────
  if [[ -n "$existing_state" ]]; then
      stored_5h_reset=$(echo "$existing_state" | jq -r '.seen_resets.five_hour_at // empty')
      stored_7d_reset=$(echo "$existing_state" | jq -r '.seen_resets.seven_day_at // empty')
      prev_5h_active=$(echo  "$existing_state" | jq -r '.active_triggers.five_hour // false')
      prev_7d_active=$(echo  "$existing_state" | jq -r '.active_triggers.seven_day // false')

      five_h_reset_happened=0
      seven_d_reset_happened=0
      [[ -n "$stored_5h_reset" && "$stored_5h_reset" != "$five_hour_resets"  ]] && five_h_reset_happened=1
      [[ -n "$stored_7d_reset" && "$stored_7d_reset" != "$seven_day_resets" ]] && seven_d_reset_happened=1

      if [[ "$cur_in_overage" -eq 0 ]]; then
          # Clean end: both limits now below 100%. Finalize at now.
          finalize_episode "$existing_state" "$now_iso"
          [[ "$acquired" -eq 1 ]] && rmdir "$lock_dir" 2>/dev/null
          trap - EXIT HUP INT TERM
          exit 0
      fi

      # cur_in_overage=1. Episode broke iff every previously-active trigger has
      # reset since we last observed. If so, finalize + fall through to start a
      # fresh episode (baselines re-captured below).
      episode_broke=0
      if [[ "$prev_5h_active" = "true" && "$prev_7d_active" = "true" ]]; then
          [[ "$five_h_reset_happened" -eq 1 && "$seven_d_reset_happened" -eq 1 ]] && episode_broke=1
      elif [[ "$prev_5h_active" = "true" ]]; then
          [[ "$five_h_reset_happened" -eq 1 ]] && episode_broke=1
      elif [[ "$prev_7d_active" = "true" ]]; then
          [[ "$seven_d_reset_happened" -eq 1 ]] && episode_broke=1
      fi

      if [[ "$episode_broke" -eq 1 ]]; then
          # Best-effort end_ts: the moment when the episode-keeping trigger reset
          # (= stored reset timestamp for whichever trigger was carrying the
          # episode). If both were active, use whichever reset was latest.
          end_ts_iso=''
          if [[ "$prev_5h_active" = "true" && "$prev_7d_active" = "true" ]]; then
              u5=$(to_unix "$stored_5h_reset")
              u7=$(to_unix "$stored_7d_reset")
              latest=$(awk -v a="$u5" -v b="$u7" 'BEGIN { print (a > b) ? a : b }')
              end_ts_iso=$(to_iso "$latest")
          elif [[ "$prev_5h_active" = "true" ]]; then
              end_ts_iso=$(to_iso "$(to_unix "$stored_5h_reset")")
          elif [[ "$prev_7d_active" = "true" ]]; then
              end_ts_iso=$(to_iso "$(to_unix "$stored_7d_reset")")
          fi
          [[ -z "$end_ts_iso" ]] && end_ts_iso="$now_iso"
          finalize_episode "$existing_state" "$end_ts_iso"
          existing_state=''
      fi
  fi

  # Start a new episode (either no prior state, or we just finalized one).
  if [[ -z "$existing_state" ]]; then
      [[ "$cur_in_overage" -eq 0 ]] && {
          [[ "$acquired" -eq 1 ]] && rmdir "$lock_dir" 2>/dev/null
          trap - EXIT HUP INT TERM
          exit 0
      }
      existing_state=$(jq -n \
          --arg ts "$now_iso" \
          --argjson f5 "$five_h_hit" \
          --argjson s7 "$seven_d_hit" \
          --arg r5 "$five_hour_resets" \
          --arg r7 "$seven_day_resets" \
          '{episode_start_ts: $ts,
            active_triggers:  {five_hour: ($f5 == 1), seven_day: ($s7 == 1)},
            triggers_ever:    ((if $f5 == 1 then ["five_hour"] else [] end)
                             + (if $s7 == 1 then ["seven_day"] else [] end)),
            seen_resets:      {five_hour_at: $r5, seven_day_at: $r7},
            sessions:         {},
            total_overage_usd: 0}')
  fi

  # ── Update this session's entry and the episode totals ──────────────────────
  # Baseline rule (applied uniformly to episode-start session + late joiners):
  #   First registration: baseline = session_total - last_turn_cost.
  #                       (Last turn always counts; trends toward overestimate.)
  #   Subsequent turns:   reuse the baseline already recorded for this session.
  # This preserves the idempotent property: current_overage = cost - baseline
  # is a pure function, re-runnable any number of times without drift.
  sess_entry=$(echo "$existing_state" | jq -r --arg sid "$session_id" '.sessions[$sid] // empty')
  if [[ -z "$sess_entry" ]]; then
      baseline=$(awk -v s="$session_total_cost" -v l="$turn_cost" \
          'BEGIN { v = s - l; printf "%.6f", (v < 0 ? 0 : v) }')
  else
      baseline=$(echo "$existing_state" | jq -r --arg sid "$session_id" \
          '.sessions[$sid].baseline_usd // 0')
  fi
  current_overage=$(awk -v s="$session_total_cost" -v b="$baseline" \
      'BEGIN { v = s - b; printf "%.6f", (v < 0 ? 0 : v) }')

  # Refresh triggers_ever (union-into) and active_triggers/seen_resets
  # (snapshot of current) so the next invocation has fresh comparators.
  new_state=$(echo "$existing_state" | jq \
      --arg sid "$session_id" \
      --argjson bl "$baseline" \
      --argjson ov "$current_overage" \
      --arg uts "$now_iso" \
      --argjson f5 "$five_h_hit" \
      --argjson s7 "$seven_d_hit" \
      --arg r5 "$five_hour_resets" \
      --arg r7 "$seven_day_resets" \
      '.sessions[$sid] = {baseline_usd: $bl, current_overage_usd: $ov, updated_at: $uts}
       | .total_overage_usd = ([.sessions[] | .current_overage_usd] | add // 0)
       | .active_triggers   = {five_hour: ($f5 == 1), seven_day: ($s7 == 1)}
       | .seen_resets       = {five_hour_at: $r5, seven_day_at: $r7}
       | .triggers_ever     = (((.triggers_ever // [])
                                + (if ($f5 == 1) then ["five_hour"] else [] end)
                                + (if ($s7 == 1) then ["seven_day"] else [] end))
                               | unique)')

  # Atomic replace.
  echo "$new_state" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"

  [[ "$acquired" -eq 1 ]] && rmdir "$lock_dir" 2>/dev/null
  trap - EXIT HUP INT TERM
) || true
