# CompEditor usage ingestion contract (schema 1)

This is the integration contract for the desktop client and the separately hosted statistics service. Sites has deployed the receiver at `https://compeditor-usage-ingestion.moton9.chatgpt.site` and the owner-only dashboard at `https://compeditor-usage-admin.moton9.chatgpt.site`. `COMPEDITOR_USAGE_ENDPOINT` resolves to `https://compeditor-usage-ingestion.moton9.chatgpt.site/v1/usage` in the prepared native builds. The receiver accepts collection with `INGESTION_ENABLED=1`.

A configured native build creates a local installation UUID and queue and attempts background delivery when launched. This change has not been distributed in an app release. An isolated native QA build has completed a live request to the public receiver: HTTP 204, a persisted synthetic row, and owner-dashboard counts were verified. The synthetic row remains stored and its reserved installation ID is excluded from product aggregates. Production desktop builds have not been distributed. An empty or invalid endpoint still disables the native client before identity creation or storage access. Setting the receiver to `INGESTION_ENABLED=0` returns 503 and prevents storage of usage, but does not disable the native client's attempts.

## Request and acknowledgement

`POST /v1/usage` accepts `Content-Type: application/json`. No administrator credential, private-Site bypass token, cookies, or user account data belongs in the client. An unauthenticated write-only endpoint receives untrusted self-reported counts; it cannot prove that a request came from an unmodified CompEditor installation.

```json
{
  "schema_version": 1,
  "install_id": "caebf0ab-5fd4-4ce2-9388-47e81ed45744",
  "batches": [
    {
      "batch_id": "dfcfe995-9158-4b5a-a059-7aa234c58a94",
      "day": "2026-10-15",
      "app_version": "0.2.2",
      "launches": 1,
      "features": {
        "semantic_completion_accepted": 2,
        "copilot_completion_accepted": 1,
        "definition_requested": 0
      }
    }
  ]
}
```

The UUIDs above are synthetic examples. Dates are UTC calendar days, not exact event timestamps. An empty `features` object and zero launches represent foreground activity on a new day. Completion counters count successful acceptance operations; accepting a Copilot suggestion word by word can count multiple operations. Definition counters count explicit eligible requests, including requests that find no result.

Return **204 No Content** only after the entire request is durably committed. A lost response causes an identical retry. The client retains immutable batches until this acknowledgement; events that occur during a request are added to a different batch. A successful response must never acknowledge only part of a request.

Use a unique `(install_id, batch_id)` database key. The same key with identical fields is an idempotent success, including duplicate keys within one request. The same key with different fields is **409 Conflict** and must not mutate the stored row. Validate and commit the complete request atomically, including deduplication and any derived aggregates.

## Receiver validation and resource controls

Enforce a 16 KiB body limit while streaming, before parsing JSON; do not trust `Content-Length`. Permit 1–31 batches. Require schema version 1, UUIDs, valid UTC calendar days, semantic version strings of at most 64 ASCII bytes, integer counters in 0–10,000, and exactly the documented fields. Accept only the current UTC day and the preceding 30 days. Reject duplicate JSON member names, duplicate conflicting batch IDs, unknown fields, arbitrary feature names, noninteger/nonfinite numbers, and impossible dates. Normalize UUID case before using it as a database key.

The client persists at most 31 entries and at most 16 KiB, including pending counts, and retains no day older than the preceding 30 UTC days. It drops the oldest entries when limits are reached. Counters saturate at 10,000 per batch. Attempts are at least one hour apart across relaunches; the timestamp is persisted before sending. If the system clock moves backward, the next attempt waits until one hour after that timestamp. Each HTTPS attempt has a five-second deadline, disallows redirects, and ignores response bodies. Only 204 acknowledges receipt; other status codes retain the bounded queue for a later attempt.

The local queue is stored in Application Support/CompEditor/usage-metrics.json with owner-only file permissions. A separate nonblocking process lock prevents simultaneous instances from overwriting retry state or bypassing the throttle. An instance that cannot acquire the lock disables its statistics for that session. No termination-time upload is awaited. Foreground activity is checked at UTC midnight as well as at intervals of at most 60 seconds; sleep/inactive days are not backfilled.

The only feature keys are `semantic_completion_accepted`, `copilot_completion_accepted`, and `definition_requested`. Do not accept free-form dimensions, OS fingerprint fields, document information, or arbitrary diagnostic payloads. Parameterize SQL statements and escape displayed values. Do not reflect submitted values in errors or request logs.

Return **400 Bad Request** for invalid fields, **413 Content Too Large** for an oversized body, **415 Unsupported Media Type** for other content types, and **429 Too Many Requests** when a limit is exceeded. Reject unsupported methods. A CORS policy is not authorization: native clients and scripts can call the endpoint independently of browsers.

The receiver applies global and per-installation request/write limits and a hard 100,000-row capacity. Random installation IDs can be forged, so per-ID limits alone are insufficient. Additional provider-edge rate limits are optional hardening, not a prerequisite for building the app. Do not claim an embedded shared client token prevents abuse.

The dashboard aggregates the current and previous UTC calendar months. Stored usage rows expire when their `day` is earlier than UTC today minus 61 days. Each valid POST or authorized aggregate GET deletes at most 1,000 expired rows, including their batch deduplication records. This request-triggered cleanup does not guarantee physical deletion by a fixed deadline during inactivity or a cleanup backlog. Provider IP/access logs and backups follow the provider's own policies; a Sites-specific retention period has not been established and must not be invented in the release notice.

## Aggregation and owner access

DAU is the distinct installation count for one UTC day. MAU is the distinct installation count in a named UTC calendar month; label a rolling 30-day count separately. Never sum daily distinct counts to obtain monthly distinct counts. Sum launch and feature counts only after deduplication. If an installation reports several app versions on a day, version-group distinct counts can overlap and their sum can exceed total DAU.

These are estimates of active installations, not counts of individual people. One person can have several installations, several people can share one installation, and resetting or copying preferences changes the relationship between an ID and an installation. Offline use, bounded queues, counter caps, clock errors, forged requests, and unavailable service reduce accuracy. The dashboard must state these limitations and must distinguish no received data from zero observed usage.

Keep the management Site owner-private. Sites authentication protects every private route and therefore also blocks anonymous desktop POSTs. Do not distribute a private-Site bypass bearer. A separately approved public ingress service can own the D1 data and expose an aggregate-only read API authenticated by a server-only secret held by the private management Site. Keep identity checks on all management read routes; a service token must not become browser or native administrator access. Cross-Site D1 sharing is not assumed.

## Verification and release operations

The receiver and native client use isolated fixtures, which are removed after hosted verification. Verification covers the cases below; results from real owner accounts or an executed native app must be recorded separately:

- An unauthenticated caller can submit only valid bounded usage requests and cannot read raw rows, installation IDs, aggregates, or administration routes.
- Only the owner can view the dashboard; a signed-out browser, another account, and an ingestion credential cannot access management data.
- Duplicate retries, conflicting IDs, concurrent requests, transaction failures, and lost responses never double count or acknowledge a partial commit.
- Oversized streaming bodies, malformed JSON, unknown fields, forged IDs, rate bursts, and exhausted storage/write budgets fail within the configured limits.
- UTC midnight, month boundaries, multiple versions, and delayed arrival produce the documented distinct counts.
- Expiry rules, bounded deletion, and the absence of a fixed physical-deletion deadline are reflected in the privacy notice, together with the hosting provider's access to IP addresses and any limits of the available log/backup retention information.
- The compiled app contains only the intended public HTTPS endpoint, no management secret, and its network payload matches this contract. Offline editing remains responsive and failures produce no dialogs.

The Sites are published and the server-only aggregate-read credential and owner ID are configured. Preparing the native endpoint requires no administrator token, owner ID, private-Site bypass credential, or CORS change in the app. Build configurations expand the two URL slashes separately so xcconfig comment parsing cannot truncate the URL. `zsh Scripts/test-usage-metrics.sh PATH_TO_COMPILED_INFO_PLIST...` checks the exact URL and native configuration policy without launching an app or using live transport.

The operator is the CompEditor project (`KDU-i/CompEditor`), with support through [GitHub Issues](https://github.com/KDU-i/CompEditor/issues). The release must publish the usage notice on GitHub with this contact and the actual retention and deletion behavior above; support requests do not require installation IDs or personal data. Building an unsigned local app requires no additional administrator credential or server setting. A prepared build and a receiving service do not mean that an app release has been published. Signed appcast/archive preparation, versioning, and release publication remain the separate distribution steps documented in [UPDATES.md](UPDATES.md); optional provider hardening must not be presented as an unfinished native feature.
