# Agents

ClaudeDeck can ask other models about a Claude Code session: a bot running on this Mac (for
example a Grok Bot routine) behind a webhook, or a system prompt and model it calls through the
xAI API. An agent never types into Claude Code on its own: its answers arrive as purple notes
beside the session (on the Mac and the phone), and the user sends them on, or queues them for the
next turn. The one exception is an agent the user explicitly allows to send directly (below).

## Setup

Settings › Agents:

1. **Add Agent…** and pick where it runs:
   - **xAI API (Grok):** a new bot made of the instructions (system prompt) and a model picked from
     the API's list. Needs the xAI API key (stored in the keychain). It knows nothing beyond what
     ClaudeDeck sends.
   - **Webhook:** your existing bot. `https://…`, or `http://` only to this Mac (`127.0.0.1`,
     `localhost`). An optional `Authorization` header value is stored in the keychain and sent as typed.
2. **Asynchronous** (webhook only): the webhook just acknowledges (`200`/`202`) and answers later
   through the local API (`POST /v1/notes` with the `request_id`).
3. **Asks by itself…**: the agent is asked automatically when a session finishes a turn, or waits on
   a permission or a question, **only in the projects you tick** (none ticked: never). Once per turn;
   after 3 automatic rounds in a row without a message from the user it pauses (ask by hand, or write
   to Claude, to go on).
4. **May type into Claude through the local API**: off by default. Off, texts the agent sends to
   `/sessions/{id}/prompt` become notes.
5. **Local API for agents on this Mac**: on/off, port (default **47647**; the remote port 47821 is
   refused), the bearer token (Copy, Regenerate…).
6. **Activity Log…** lists everything sent to and received from agents.

Ask by hand from a session's menu (**Ask Agent**) or on the phone (**Ask** above the message field;
what's typed there is the request). **Ask Agent › Preview What's Sent…** shows the exact text first.
Notes are kept on disk (Application Support/agent-notes.json) and come back after a restart; notes
that were sent, queued or dismissed stay in **Past Reviews…** (the session's menu, last 50).

Before anything goes out, key- and token-looking strings in the messages, the diff and new files are
replaced with `[redacted]` (API keys with known prefixes, private key blocks, JWTs, bearer values,
`password=` / `secret:` style assignments). It's a safety net, not a guarantee: review what you send.

## What a webhook receives

`POST` with `Content-Type: application/json`. Every key is always present (`null` when unknown).

```json
{
  "request_id": "6F1C2A0E-0C55-4D2B-9C5A-2B0F6C7D8E91",
  "event": "session.idle",
  "agent": "Kod Checker",
  "system": "You review Swift code…",
  "model": "",
  "async": true,
  "project": { "id": "B0000000-0000-0000-0000-000000000003", "name": "mobile-app", "path": "/Users/me/Projects/mobile-app" },
  "session_id": "C0000000-0000-0000-0000-000000000005",
  "session_name": "mobile-app",
  "session_state": "idle",
  "user_request": "",
  "last_user_message": "add pull-to-refresh to the feed",
  "last_assistant_message": "Done — added pull-to-refresh…",
  "git_diff": "diff --git a/…",
  "untracked_files": [{ "path": "Sources/Feed/Refresh.swift", "content": "import SwiftUI…" }],
  "transcript_path": "/Users/me/.claude/projects/…/….jsonl",
  "timestamp": "2026-11-06T12:00:00Z",
  "message": "Review the latest work in this Claude Code session.\n\nProject: …",
  "callback": { "notes_url": "http://127.0.0.1:47647/v1/notes", "request_id": "6F1C2A0E-…" }
}
```

- `event`: `manual` (asked by the user), `session.idle`, `session.permission`, `session.question`,
  `agent.test` (Settings' Test button).
- `session_state`: `idle`, `running`, `needsPermission`, `needsAnswer`, `starting`, `stopped`.
- `git_diff` is `git diff HEAD` (cut at 60 000 characters). `untracked_files` are new files git
  doesn't ignore: text only, at most 25 files, 16 000 characters each, 48 000 in all; `.env*`, keys,
  certificates and files named like secrets/tokens/credentials are never sent.
- `message` is the same context as one readable text (what an xAI agent gets).
- `callback` is `null` while the local API is off.

**Synchronous** webhooks answer with `{"reply": "…"}` or plain text (at most 1 MB; an empty reply
is an error). **Asynchronous** ones acknowledge, then post the answer to `callback.notes_url`.

## Local API

`http://127.0.0.1:<port>` (this Mac only). Every request needs `Authorization: Bearer <token>`
(compared in constant time); bodies are at most 1 MB, JSON with snake_case keys.

| Method | Path | Body | Does |
|---|---|---|---|
| GET | `/v1/projects` | | Projects and their sessions, with state |
| GET | `/v1/sessions/{id}/messages?limit=N` | | The last N transcript entries (1–200, default 20) |
| POST | `/v1/notes` | `{request_id?, session_id, agent, text}` | A note on the session; with the `request_id` of a request, its answer |
| POST | `/v1/sessions/{id}/prompt` | `{agent, text}` | Types into Claude if the agent may send directly, else a note; `409` while a permission or question is on screen |
| POST | `/v1/projects/{id}/sessions` | `{agent, name?, prompt?}` | A new Claude session; `prompt` goes in once Claude is up |

Errors are `{"error": "…"}`: `400 bad_request`, `401 unauthorized`, `403 not_registered_by_api`,
`404 not_found` / `unknown_session` / `unknown_project` / `unknown_agent`, `405 method_not_allowed`,
`409 blocked` / `not_running` / `not_started` / `name_taken`, `413 too_large`, `429 too_many_pending` /
`rejected_recently`. Agents registering themselves: [below](#agents-signing-themselves-up).

```sh
TOKEN=…   # Settings › Agents › Copy
API=http://127.0.0.1:47647

curl -H "Authorization: Bearer $TOKEN" $API/v1/projects
curl -H "Authorization: Bearer $TOKEN" "$API/v1/sessions/$SESSION/messages?limit=10"

# The answer to a request ClaudeDeck sent (asynchronous webhook):
curl -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"request_id":"'"$REQUEST"'","session_id":"'"$SESSION"'","agent":"Kod Checker","text":"Looks good, one nit: …"}' \
  $API/v1/notes

# Straight to Claude (only if the agent may send directly; otherwise a note):
curl -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"agent":"Kod Checker","text":"Please add a test for the empty feed."}' \
  $API/v1/sessions/$SESSION/prompt

curl -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"agent":"Kod Checker","name":"Review fixes","prompt":"Fix the issues in REVIEW.md"}' \
  $API/v1/projects/$PROJECT/sessions
```

## Agents signing themselves up

A bot can add itself instead of being typed into Settings: it registers through the local API
(same token), then waits until you approve it. Until then it gets **no** webhook, isn't in
**Ask Agent** (Mac or phone) and can't type into Claude.

| Method | Path | Body | Does |
|---|---|---|---|
| POST | `/v1/agents` | `{name, kind: "webhook", url, auth_header?, async?, description?}` | Registers it as pending: `201 {agent_id, status: "pending"}` |
| GET | `/v1/agents` | | Every agent: `[{id, name, kind, url_host, status, async, registered}]` |
| GET | `/v1/agents/{id}` | | One agent (poll it to see whether you approved it) |
| DELETE | `/v1/agents/{id}` | | Removes an agent that registered itself (`403` for ones added in Settings) |

- `name`: 1–40 characters, not blank, one line. `kind`: only `"webhook"`. `url`: `https://…`, or
  `http://` only to this Mac (`127.0.0.1`, `localhost`). `description` (at most 500 characters) is
  shown when you decide; it's never sent anywhere.
- `auth_header` goes to the keychain, like the header of a webhook agent added by hand; it's never
  written to deck.json or the activity log, and no endpoint returns it. Listings show the URL's host
  only (`url_host`), never its path or query. `kind` is `xai` for Grok bots made in Settings.
- `status`: `pending`, `approved` or `rejected`. `registered` is `true` for agents that signed
  themselves up (only those can be deleted through the API).
- **Idempotent:** the same name (case-insensitively) and URL again answers `200` with the agent
  already there and its status. The same name with another URL is `409 name_taken`.
- Bodies are at most 16 KB (`413 too_large`); bad JSON is `400 bad_request`. Other `400`s:
  `bad_name`, `bad_kind`, `bad_url`, `insecure_url`, `bad_auth_header`, `bad_description`.
- At most 10 agents wait at once (`429 too_many_pending`). A rejected name and URL can't register
  again for 24 hours (`429 rejected_recently`); `GET /v1/agents/{id}` says `rejected` meanwhile, and
  `DELETE` refuses it (`429 rejected_recently`) so the wait can't be skipped.

**Approval.** A new registration shows a notification on the Mac (with **Approve** / **Reject**),
an **Agents Waiting for Approval** section in Settings › Agents (name, URL host, description), and
the same section at the top of the phone's session list. Approved, it's an ordinary webhook agent:
it gets requests, shows in Ask Agent, and you can edit it in Settings. **May type into Claude** stays
off and no project is ticked for automatic requests until you change them. Registrations,
approvals, rejections and deletions are in the **Activity Log…**.

```sh
# Register (once; running it again is harmless):
curl -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"Kod Checker","kind":"webhook","url":"https://bots.example.com/kod-checker",
       "auth_header":"Bearer '"$BOT_SECRET"'","async":true,"description":"Reviews Swift diffs"}' \
  $API/v1/agents
# → {"agent_id":"9A3F…","status":"pending"}

# Approved yet?
curl -H "Authorization: Bearer $TOKEN" $API/v1/agents/$AGENT_ID
# → {"id":"9A3F…","name":"Kod Checker","kind":"webhook","url_host":"bots.example.com","status":"approved",…}

# Leave:
curl -X DELETE -H "Authorization: Bearer $TOKEN" $API/v1/agents/$AGENT_ID
```

The agent name in API calls is matched (case-insensitively) against the agents in Settings; only
those can send directly. A name that isn't there still gets its texts in as notes.
