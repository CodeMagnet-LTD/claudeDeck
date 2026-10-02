#!/bin/sh
# Stand-in for `claude` in demo mode (tools/demo.sh). Prints the canned conversation for this
# terminal, reports its state the way the real hook would, then waits until the terminal closes.
DEMO="$(cd "$(dirname "$0")/.." && pwd)"
ID="$CLAUDEDECK_TERMINAL_ID"
SCENE="$DEMO/scenes/$ID"
ESC=$(printf '\033')

[ -f "$SCENE.txt" ] && sed "s/\[\([0-9;]*m\)/$ESC[\1/g" "$SCENE.txt"

if [ -f "$SCENE.state" ]; then
  IFS='|' read -r STATE EVENT TOOL DETAIL < "$SCENE.state"
  sleep 1   # after the app has recorded the launch
  TRANSCRIPT=""; [ -f "$SCENE.jsonl" ] && TRANSCRIPT="$SCENE.jsonl"
  jq -n --arg sid "demo-$ID" --arg tid "$ID" --argjson pid $$ --arg cwd "$PWD" --arg tp "$TRANSCRIPT" \
        --arg state "$STATE" --arg event "$EVENT" --arg tool "$TOOL" --arg detail "$DETAIL" \
        '{session_id: $sid, terminal_id: $tid, pid: $pid, cwd: $cwd,
          transcript_path: (if $tp == "" then null else $tp end),
          state: $state, event: $event, detail: $detail,
          tool_name: (if $tool == "" then null else $tool end), updated_at: now}' \
    > "$DEMO/sessions/.$ID.tmp" && mv "$DEMO/sessions/.$ID.tmp" "$DEMO/sessions/demo-$ID.json"
fi

trap 'exit 0' HUP INT TERM
while :; do sleep 3600 & wait $!; done
