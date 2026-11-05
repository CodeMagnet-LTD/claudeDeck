# Kod checker bridge

ClaudeDeck can forward Claude Code session activity to an external reviewer called **kod checker**, and accept messages back. Kod checker never talks to Claude Code. It only talks to ClaudeDeck.

The bridge is **off** until you turn it on: Settings › Kod Checker › **Enable the kod checker bridge**.

What you configure there:

| Setting | Where it is stored |
|---|---|
| On / off, webhook URL, port | `deck.json` with the rest of the settings |
| Webhook `Authorization` value | Keychain service `co.codemagnet.ClaudeDeck.KodBridge`, account `webhook-authorization` |
| Local API token | Same Keychain service, account `api-token` |

The token is created the first time you turn the bridge on. **Copy** puts it on the clipboard. **Regenerate…** replaces it immediately; the previous token stops working. **Send Test Event** posts a `bridge.test` event to the webhook. **Activity Log…** lists outbound events and inbound messages.

Messages kod checker sends are typed into the session with the same path as typing them yourself. They show a **kod checker** badge in the session pane. On the phone and iPad, the same badge is on that user bubble in the conversation.

The activity log and the list of those messages (not the token, not the Authorization value) are in `~/Library/Application Support/ClaudeDeck/kod-bridge.json`.

This listener is not the Tailscale remote connection. Remote mode stays on port **47821**. The bridge binds **127.0.0.1** only, default port **47647**.

## Outbound webhook

When a Claude session finishes a turn (idle), or is waiting on a permission or a question, ClaudeDeck POSTs JSON to the webhook URL. Startup idle (`SessionStart`) is not a turn, so it does not send. The post does not block the UI: the timeout is 5 seconds, then up to two retries (three tries total) after 0.4s and 0.8s. Transport failures, HTTP 408, 429, and 5xx are retried. Other 4xx responses are not.

If the Authorization field is non-empty, it is sent **verbatim** as the `Authorization` header. A typical value is `Bearer <secret>`. If the field is empty, the header is omitted. An empty webhook URL sends nothing; the local API still works.

```http
POST /hooks/kod HTTP/1.1
Host: example.com
Content-Type: application/json
User-Agent: ClaudeDeck-KodBridge
Authorization: Bearer secret
```

```json
{
  "detail": "Bash: npm test",
  "event": "session.needs_permission",
  "finished": false,
  "last_assistant_reply": "I'll run the tests.",
  "last_user_prompt": "Check the failing test.",
  "project_name": "claudeDeck",
  "project_path": "/Users/mustafa/claudeDeck",
  "session_id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
  "timestamp": "2026-11-05T23:30:00Z",
  "transcript_path": "/Users/mustafa/.claude/projects/-Users-mustafa-claudeDeck/0123abcd.jsonl",
  "waiting_for_input": true
}
```

`timestamp` is ISO-8601 UTC. `session_id` is the ClaudeDeck session id (the same id the local API uses), not Claude's own session id. Claude's id is `claude_session_id` on the project list, and it is also the transcript file name.

| Field | Meaning |
|---|---|
| `event` | `session.idle`, `session.needs_permission`, `session.needs_answer`, or `bridge.test` |
| `project_name` | Project name in the sidebar |
| `project_path` | Absolute path of the project |
| `session_id` | ClaudeDeck session UUID |
| `timestamp` | When the event was built |
| `last_user_prompt` | Last user message in the transcript, trimmed, at most 4,000 characters. `null` if there isn't one |
| `last_assistant_reply` | Last assistant message, trimmed, at most 8,000 characters plus `…` when cut. `null` if there isn't one |
| `finished` | `true` when the turn looks finished (idle). `false` when a permission or question is up |
| `waiting_for_input` | `true` for a permission or a question. `false` for a finished turn |
| `transcript_path` | Absolute path of the session transcript, or `null` |
| `detail` | The hook's short detail (the command, or the question), at most 2,000 characters, or `null` |

`bridge.test` uses the same shape. The reply is `Test event from ClaudeDeck.` When a session is selected, the project name, path, and session id are that session's; otherwise the session id is `00000000-0000-0000-0000-000000000000` and the project fields are empty.

## Local API

Listens on `127.0.0.1` only (not `0.0.0.0`). Default port `47647`, changeable in Settings. Port `47821` is refused because remote mode uses it.

Every request needs:

```http
Authorization: Bearer <token>
```

The scheme is case-insensitive. The token is the exact string from Settings. A missing or wrong token gets **401** and `WWW-Authenticate: Bearer`. The body is one JSON object, `Content-Length` required when there is a body (chunked encoding is rejected). The largest body is 1 MiB.

```bash
export KOD_TOKEN="paste-the-token"
export KOD_PORT=47647
```

### `GET /v1/health`

```bash
curl -sS "http://127.0.0.1:$KOD_PORT/v1/health" \
  -H "Authorization: Bearer $KOD_TOKEN"
```

```json
{"ok": true}
```

### `GET /v1/projects`

Projects and their sessions, including ones that are not running.

```bash
curl -sS "http://127.0.0.1:$KOD_PORT/v1/projects" \
  -H "Authorization: Bearer $KOD_TOKEN"
```

```json
{
  "projects": [
    {
      "id": "11111111-2222-3333-4444-555555555555",
      "name": "claudeDeck",
      "path": "/Users/mustafa/claudeDeck",
      "sessions": [
        {
          "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
          "name": "claudeDeck",
          "kind": "claude",
          "status": "idle",
          "updated_at": "2026-11-05T23:30:00Z",
          "transcript_path": "/Users/mustafa/.claude/projects/-Users-mustafa-claudeDeck/0123abcd.jsonl",
          "claude_session_id": "0123abcd"
        }
      ]
    }
  ]
}
```

`kind` is `claude` or `shell`. `status` is one of `not_started`, `starting`, `shell`, `running`, `needs_permission`, `needs_answer`, `idle`, `ended`. `detail`, `updated_at`, `transcript_path`, and `claude_session_id` are omitted when they are unknown.

### `GET /v1/sessions/{session_id}/messages?limit=40`

Recent transcript messages, oldest first in the array (the last `limit` lines). `limit` defaults to 40 and is clamped to 1…200. A user message kod checker typed has `"source": "kod checker"`. Other messages omit `source`.

```bash
curl -sS "http://127.0.0.1:$KOD_PORT/v1/sessions/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/messages?limit=40" \
  -H "Authorization: Bearer $KOD_TOKEN"
```

```json
{
  "messages": [
    {
      "at": "2026-11-05T23:29:00Z",
      "id": "…",
      "role": "user",
      "source": "kod checker",
      "text": "Please review the last change."
    },
    {
      "at": "2026-11-05T23:30:00Z",
      "id": "…",
      "role": "assistant",
      "text": "The change looks consistent."
    }
  ],
  "session_id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
}
```

`role` is `user`, `assistant`, `tool`, or `system`.

### `POST /v1/sessions/{session_id}/messages`

Types `text` into that session and presses Return, the same way ClaudeDeck types a message you wrote. If the session is not running, ClaudeDeck resumes it and types the message when the prompt is ready. If a permission or a question is on screen, the call is refused so it cannot answer that prompt by accident.

```bash
curl -sS -X POST "http://127.0.0.1:$KOD_PORT/v1/sessions/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/messages" \
  -H "Authorization: Bearer $KOD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"text":"Please review the last change."}'
```

```json
{"ok": true, "session_id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"}
```

### `POST /v1/projects/{project_id}/sessions`

Starts a new Claude session in the project and selects it. `prompt` is optional; when it is set, ClaudeDeck types it once the session is ready.

```bash
curl -sS -X POST "http://127.0.0.1:$KOD_PORT/v1/projects/11111111-2222-3333-4444-555555555555/sessions" \
  -H "Authorization: Bearer $KOD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"prompt":"Look at the failing test."}'
```

An empty body starts a session and types nothing.

```json
{"ok": true, "session_id": "BBBBBBBB-BBBB-CCCC-DDDD-EEEEEEEEEEEE"}
```

## Errors

JSON body `{"error":"<code>"}`.

| Status | `error` | When |
|---|---|---|
| 400 | `bad_request` | The HTTP request could not be parsed |
| 400 | `invalid_json` | The JSON body is missing or not the expected object |
| 400 | `empty_message` | `text` is empty |
| 401 | `unauthorized` | Missing or wrong bearer token |
| 404 | `not_found` | Unknown path, project, or session |
| 404 | `not_claude` | That session is a shell, or messages were asked from one |
| 405 | `method_not_allowed` | The path exists but the method does not |
| 409 | `blocked` | A permission or question is on screen |
| 413 | `too_large` | Body larger than 1 MiB |
| 503 | `unavailable` | The bridge is stopping |
