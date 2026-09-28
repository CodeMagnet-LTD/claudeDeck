import Foundation

/// The hook command installed into `~/.claude/settings.json`.
///
/// Claude Code runs it for every registered event with the hook JSON on stdin.
/// It only acts inside ClaudeDeck terminals (identified by `CLAUDEDECK_TERMINAL_ID`)
/// and atomically writes `~/.claude/deck/sessions/<session_id>.json`.
/// `$PPID` is the `claude` process itself (verified), so the app can check liveness.
public enum HookScript {
    public static let version = 3

    public static let source = #"""
#!/bin/sh
# ClaudeDeck status hook v3 — managed by ClaudeDeck.app, do not edit.
[ -n "$CLAUDEDECK_TERMINAL_ID" ] || { cat >/dev/null; exit 0; }
JQ=/usr/bin/jq
[ -x "$JQ" ] || JQ=$(command -v jq) || exit 0
DIR="${CLAUDEDECK_STATE_DIR:-$HOME/.claude/deck/sessions}"
IN=$(cat)
SID=$(printf '%s' "$IN" | "$JQ" -r '.session_id // empty' 2>/dev/null)
case "$SID" in ''|*/*|.*) exit 0 ;; esac
mkdir -p "$DIR" || exit 0
F="$DIR/$SID.json"
PREV=$("$JQ" -c . "$F" 2>/dev/null)
[ -n "$PREV" ] || PREV=null
OUT=$(printf '%s' "$IN" | "$JQ" -c --arg tid "$CLAUDEDECK_TERMINAL_ID" --argjson pid "${PPID:-0}" --argjson prev "$PREV" '
def clip(n): if type == "string" then (gsub("\\s+"; " ") | if length > n then .[0:n] + "…" else . end) else null end;
def tooldetail: (.tool_input // {}) as $t
  | (.tool_name // "tool") + (
      if ($t | type) != "object" then ""
      elif $t.command then ": " + ($t.command | tostring)
      elif $t.file_path then ": " + ($t.file_path | tostring)
      elif $t.url then ": " + ($t.url | tostring)
      elif $t.pattern then ": " + ($t.pattern | tostring)
      elif $t.description then ": " + ($t.description | tostring)
      else "" end);
def question: (.tool_input.questions[0].question // .tool_input.question // "Claude bir soru soruyor");
def waiting: $prev != null and ($prev.state == "needsPermission" or $prev.state == "needsAnswer");
def sig: ((.tool_name // "") + ":" + ((.tool_input // {}) | tojson)) | .[0:300];
# While a prompt is open, tool events of *other* (parallel) tools must not hide it.
def othertool: waiting and (
  if $prev.tool_use_id != null and .tool_use_id != null then $prev.tool_use_id != .tool_use_id
  else $prev.tool_sig != sig end);
. as $in
| .hook_event_name as $e
| (if $e == "UserPromptSubmit" then {state: "running", detail: (.prompt | clip(200))}
   elif $e == "PreToolUse" then
     (if .tool_name == "AskUserQuestion" then {state: "needsAnswer", detail: (question | clip(200))}
      elif othertool then null
      else {state: "running", detail: (tooldetail | clip(200))} end)
   elif $e == "PostToolUse" or $e == "PostToolUseFailure" then
     (if othertool then null else {state: "running", detail: (tooldetail | clip(200))} end)
   elif $e == "PermissionRequest" then
     (if .tool_name == "AskUserQuestion" then {state: "needsAnswer", detail: (question | clip(200))}
      else {state: "needsPermission", detail: (tooldetail | clip(200))} end)
   elif $e == "Notification" then
     (if .notification_type == "permission_prompt" then {state: "needsPermission"}
      elif .notification_type == "elicitation_dialog" or .notification_type == "agent_needs_input" then {state: "needsAnswer"}
      elif .notification_type == "idle_prompt" then (if waiting then null else {state: "idle"} end)
      else null end)
     | if . == null then null
       elif $prev != null and $prev.state == .state and $prev.detail != null then .detail = $prev.detail
       else .detail = ($in.message | clip(200)) end
   elif $e == "Stop" then {state: "idle", detail: (.last_assistant_message | clip(300))}
   elif $e == "StopFailure" then {state: "idle", detail: ("Hata: " + ((.error_type // .error // "API") | tostring) | clip(200))}
   elif $e == "SessionStart" then
     (if .source == "compact" and $prev != null and (($prev.detail // "") | startswith("/compact") | not)
        then {state: $prev.state, detail: $prev.detail}
      else {state: "idle", detail: null} end)
   elif $e == "SessionEnd" then {state: "ended", detail: .reason}
   else null end) as $s
| if $s == null then empty else
  { session_id, terminal_id: $tid, pid: $pid, cwd, transcript_path,
    state: $s.state, detail: $s.detail,
    tool_name: (.tool_name // null), notification_type: (.notification_type // null),
    tool_use_id: (if $e == "Notification" then $prev.tool_use_id else .tool_use_id end),
    tool_sig: (if $e == "Notification" then $prev.tool_sig elif .tool_name then sig else null end),
  } + (if $e == "Notification" and $prev != null and $prev.state == $s.state
        then {event: $prev.event, source: $prev.source, updated_at: $prev.updated_at}
        else {event: $e, source: (.source // null), updated_at: now} end)
  end' 2>/dev/null) || exit 0
[ -n "$OUT" ] || exit 0
TMP="$DIR/.$SID.$$.tmp"
printf '%s\n' "$OUT" > "$TMP" && mv -f "$TMP" "$F"
exit 0
"""#

    /// Events the hook is registered for.
    public static let events = [
        "SessionStart", "SessionEnd", "UserPromptSubmit",
        "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "PermissionRequest", "Notification", "Stop", "StopFailure",
    ]
}
