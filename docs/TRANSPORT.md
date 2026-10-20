# How the watch talks to a Grok Bot

There is no documented public REST API for the Grok Bot app. This client does not invent one. It uses the four routes already called by `@cursor/bdk` 0.2.27, extension `cursor-grokbot-agents` (`GrokBotAgentsBackend` in `lib/backend.js`).

That extension is the supported way for a program on your Cursor account to reach the Grok Bot agents that already exist on that account. The watch speaks the same routes, with the same bearer token, and reads the same transcript entries.

## Host

`https://api.cursor.com`

The package names this `DEFAULT_CURSOR_EXTERNAL_API_URL`. The same comment says these routes 404 on `api2.cursor.sh`. A `CURSOR_API_BASE_URL` override exists for local development. The watch accepts an https host, or `http://127.0.0.1` / `http://localhost` only. Anything else is rejected so the API key is not sent in the clear.

## Auth

`Authorization: Bearer <Cursor user API key>`

The key is the same secret `bdk` uses (`CURSOR_API_KEY`, or the key minted by `bdk login`). The official client also sends:

- `x-cursor-client-type: agent-serve`
- `x-request-id: <uuid>`
- `content-type: application/json` when there is a body

The watch sends those headers. The key is stored in the watch Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronizable). It is never written into the repository, the complication snapshot, or a log line.

Revoke the key from the Cursor dashboard if the watch is lost.

## Routes

| Action | Request | Response the client reads |
| --- | --- | --- |
| Resolve a bot by the name shown in the Grok Bot app | `POST /v0/grokbot/sessions` body `{ "name" }` | `{ "id", "name", "createdAtMs", "latestUpdatedSeq" }` |
| Send a message | `POST /v0/grokbot/sessions/{id}/messages` body `{ "text", "messageId" }` | `{ "messageId", "delivery" }` |
| Read the transcript and turn | `GET /v0/grokbot/sessions/{id}/entries?afterUpdatedSeq=` | `{ "entries", "latestUpdatedSeq", "turn" }` |
| Stop the active turn | `POST /v0/grokbot/sessions/{id}/interrupt` body `{ "reason" }` | body ignored |

`delivery` must be `accepted_temporal` or `duplicate`. Any other value is a failure. Reusing `messageId` is how the official client makes a retry safe; the offline queue keeps that id until one of those two deliveries comes back.

`turn` is `{ "idle", "inFlight", "queued" }`. That is the activity signal. The official client says internal tool traffic never appears in the transcript. Only entries with `kind == "send-message"` are spoken. Any other entry that happens to include text is shown as a note and is not spoken.

`POST /v0/grokbot/sessions` get-or-creates. A misspelled name can create an empty bot. The watch warns when `latestUpdatedSeq` is `-1`, `createdAtMs` is within 60 seconds, and this watch had no contact for that name. The same rule is in `conversation.js`.

There is no list-all-bots route in that client. The roster is the names you add. `grokbot__list` only returns the extension's allowlist plus contacts that caller already stored; it does not enumerate the account.

## Why this path

- The BDK session API (`POST /v1/session` and the NDJSON stream) talks to a BDK agent you host. Cursor-managed hosting does not expose that API to external clients: a custom channel returns an empty `202`, and the caller never receives a session id or a stream. See the deployment docs.
- Email and a routine webhook do not give a transcript cursor or turn status, so the watch could not start speaking at the first sentence.
- A home relay would still have to call these same four routes. The watch calls them directly.

## Latency

The API does not stream tokens. The official client polls `entries` (default every 750 ms) until the turn settles, and it waits through four idle polls if the turn never reported busy, so a slow start is not mistaken for a finished empty reply. This app uses that same wait.

What it adds: each `send-message` is split into sentences on the watch, and the first sentence is handed to `AVSpeechSynthesizer` before later messages arrive and before the idle confirmation finishes. Device TTS then starts while the rest of the reply is still being polled. Language, rate, and voice are watch settings. They are not fields on the API.

The poll interval is clamped to 0.4–2 seconds. The BDK guide says not to poll in a tight loop. Roster refresh, when you are not in a call, is every 5 seconds.

## Offline queue

If the watch is offline, or the send fails with a network error, HTTP 408, 429, or 5xx, the utterance is stored on the watch with its `messageId`. When the network returns, queued messages send in order. A flush will not send while that bot's last known turn is busy, so a reconnect does not talk over a bot that is still working. Speaking during a live call does interrupt first, then send, because a call barges in. The interrupt route is the documented one.

## Complication

The watch writes an activity snapshot into the App Group `group.com.grokbot.watch`. The WidgetKit complication reads that file. It does not hold the API key. A free Apple ID cannot provision App Groups; use the `.free.entitlements` files in that case. The complication then stays on "Open Grok Bot". Calls, the queue, and the shortcut still work. State for those is stored in the app's documents directory, which does not need an App Group.
