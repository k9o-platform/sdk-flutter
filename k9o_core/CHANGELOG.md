# k9o_core Flutter SDK — Changelog

## 1.5.2

### Changed

- `K9O_TIER_FEATURE_GATED` is no longer documented as an error to expect: the platform no longer gates features by plan.
- README: Architecture at a glance, illustrations, and the package table lists only the packages for that SDK.

## 1.5.0

### Fixed

- A gateway error whose `recommendation` is an object no longer escapes as a raw `TypeError`. It arrives as a `KError` with the code, message and context intact, and `recommendation` holds the object's `action` text (or its `note`).
- `KError.requestId` is now filled from the gateway's `x-k9o-request-id` response header when the error body carries no request id (a body value still wins). It is `null` when neither is present.

### Added

- `realtime.subscribe(topic, {filter, onResync, retryDelay, idleTimeout, dedupeMax})`: a reconnecting change feed over `GET /@<slug>/realtime/subscribe`. It reopens with `Last-Event-ID`, delivers each `eventId` once, retries a 5xx answer or a broken connection, ends on a 4xx answer with a `KError`, and calls `onResync` when the gateway cannot resume. `realtime.replay(topic, {fromSequence, untilSequence, limit, afterAuditEventId})`: one page of a topic's ledger (`POST /@<slug>/realtime/replay`) answering `topic`, `events`, `nextCursor`, `hasMore` and, for a topic that keeps no ledger (only `audit.project.*` topics do), `resync: 'reread-source'`. The client checks the topic, sequences, `limit` and `afterAuditEventId` before sending.
- `orgSlug` as an alternative to `baseUrl`: `K9oCore(orgSlug: 'acme', ...)` uses `https://acme.api.k9o.io`, and `baseUrl: 'https://api.k9o.io'` with `orgSlug` gives the same. A full organization `baseUrl`, a regional address or a custom domain is used as given. With neither, the constructor throws a `KError` with code `K9O_INVALID_BASE_URL` and context `{field: 'baseUrl'}`; a malformed slug throws a `KError` with code `K9O_INVALID_FIELD_VALUE` and context `{field: 'orgSlug', slug}`.
- `core.rampart` (`classify`, `jwks`, `verifyReceipt`) and `Moat`, the local prompt-pinning guard, with the platform's canonical JSON form (`canonicalize`). The receipt signature is checked in pure Dart (RFC 8032 Ed25519), so signature checking needs no extra dependency and no minimum OS version. A long input is scored in overlapping windows and the highest injection score decides; past 16 windows (about 6,000 tokens) the answer is 413 `K9O_RAMPART_INPUT_TOO_LONG` with no verdict. 503 `K9O_RAMPART_CLASSIFIER_UNAVAILABLE` still means the classifier could not answer. The thresholds are a starting calibration and may move. `RampartVerified.windows` reports how many windows were scored (1 when the receipt has no such claim).
- `metadata.*`: `filter`, `set`, `search`, `vectors.nearest`, `index.get` and `index.declare` for the columns you declare on a collection. Column names in `where`, `search` and `nearest` get the `metadata.` prefix when you leave it out; `set` writes declared columns only. The client checks the surface grammar, limits, cursor rule and the 64-column limit before sending. Gateway codes such as `K9O_METADATA_FIELD_NOT_INDEXED`, `K9O_UNKNOWN_SURFACE` and `K9O_QUERY_RESULT_TOO_LARGE` arrive as `KError`. There is no `subscribe` in this client.
- `Moat` matches role markers after Unicode NFKC, removal of combining marks (NFKD), removal of invisible and format characters, mapping of a small set of Cyrillic and Greek look-alikes of the marker letters to Latin, case-folding and whitespace collapsing, using the new pinned dependency `unorm_dart` 0.3.3 (MIT) instead of a hand-written folding table; it passes the shared marker vectors.
- `vectorSearch` on the select builder sends the embedding in the request body.
- `KError.retryAfterSec`: seconds the gateway asks you to wait, when the error carries it.
- `requireApproval()` on single-record `insert`, `update` and `delete` (`core.from('orders').insert({...}).requireApproval()`): the write is queued for approval (HTTP 202) instead of applied. The result is a `QueuedWrite` carrying the `QueuedChange` or, when an `auto_approve` policy applies the write at once, an `AppliedWrite`. Upserts and bulk writes do not take it.
- `ai.generate` takes an optional `usageType`, a label recorded with the call.
- `vectors.nearest` and `vectors.upsert`: search an embedding collection with the vector in the request body, and store rows in it.

### Changed

- `insert()` returns a builder that you can `await` as before; call `requireApproval()` on it to queue the write.

### Fixed

- The client follows the region-free address. Against `https://<org>.api.<host>` it asks once, without credentials, which regional host serves the org, remembers the answer and sends every request there. Calls with credentials no longer answer `400 K9O_INVALID_REQUEST_SHAPE`. A regional address, `localhost` or any other host is used as given.

## 1.4.0 — 2026-10-26

### Added

- `query`: run one read-only SQL statement with named (`:name`) or positional (`$1`) parameters.
- `search`: full-text search over one text column of a collection.
- `from(collection)`: select, insert, update and delete records, with filters, paging, count, `textSearch` and `vectorSearch`.
- `storage`: create, read, change and delete buckets; upload, list, sign and remove objects.
- `streams`: create, list, get and delete streams; publish, replay and subscribe (a `Stream` of events that reconnects by itself).
- `ai.generate`: generate text from a prompt (the org's default model unless `model` is given) and read the generated text, finish reason and token usage.

### Changed

- README description.

## 1.3.0 — 2026-10-26

### Changed

- The README is rewritten with install steps, a runnable example with its expected output and a reference appendix.
- Version aligned with the other SDKs. `ai.embed` is the only call.

## 1.0.0 First public release

First public release. See the README for the full API overview.
