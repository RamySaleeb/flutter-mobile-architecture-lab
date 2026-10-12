# 0001 — Optional HTTP catalog adapter

**Status: Accepted and implemented — 2026-10-12.**  
Date: 2026-10-12 · [Roadmap issue #4](https://github.com/RamySaleeb/flutter-mobile-architecture-lab/issues/4)

## Implementation record

The owner authorized implementation after reviewing this proposal. The original design below is retained as rationale; its future-tense statements describe the design at proposal time.

- Implemented in [`catalog_http.dart`](../../lib/catalog_http.dart), with domain failures/signals in [`catalog.dart`](../../lib/catalog.dart), owner disposal in the repository, and safe presentation messages in the controller.
- `http` 1.6.0 is resolved in the lockfile; `fake_async` is a direct test dependency. The public `main.dart` still constructs only `DemoCatalogService`.
- All 63 regression tests pass, including HTTP contracts, cache sharing/retention, race/reset, keyboard, and large text. The release web build passes.
- The local [fixture server](../../tool/fixture_server.py) and [HTTP smoke probe](../../tool/http_smoke.dart) pass on the Dart VM and Codex in-app browser on macOS. They check real-client deadlines/abort before headers and mid-body, redirect refusal, and client reuse. This does not claim remote server computation always stops. Android/iOS device transports remain unverified.
- Redirect policy is explicit: `followRedirects = false`; native exposes redirect status and the browser maps fetch's refused redirect to connectivity failure. Both were checked locally. The repository always rejects late writes even if a service ignores cancellation.
- Timers and a monotonic elapsed-time callback are injectable. Fake-time unit tests stay separate from the opt-in real-I/O smoke probe. Cache timestamps still use the independently injected wall clock.

## Decision in brief

Add an optional `HttpCatalogService` behind the existing catalog boundary. Use typed failures, one bounded request deadline, and repository-owned cancellation. Preserve query isolation, shared requests, cached results after failure, and the controller's latest-result guard.

**The public Pocket Catalog demo continues to construct `DemoCatalogService`.** No API keys, backend, endpoint availability, or new setup steps are required to run it. The optional implementation is now available; default demo setup is unchanged.

## Current behavior and constraints

- [`CatalogService.fetch(query)`](../../lib/catalog.dart) returns catalog items; there is no cancellation parameter today. `CatalogUnavailable` is the simulated failure.
- [`CachedCatalogRepository`](../../lib/catalog_data.dart) normalizes keys, shares the exact in-flight future for each key, retains old snapshots on failure, and clears in-flight entries in `finally`. Successful older searches may warm their own cache.
- [`CatalogController`](../../lib/catalog_controller.dart) rejects obsolete results with a generation counter. It currently maps every exception to generic display text. Disposing a controller prevents notifications; it does not stop transport work.
- [`main.dart`](../../lib/main.dart) explicitly constructs the simulated service. The race walkthrough depends on older requests completing, and must remain intact.

Request cancellation saves work; the generation guard protects correctness. Keep both responsibilities separate.

## Proposed wire contract

Inject a complete catalog endpoint URI and an HTTP client. The adapter issues a single `GET` with `Accept: application/json`. Build query parameters through Dart `Uri`, never string interpolation. Normalize the query with the existing `normalizeQuery`; set exactly one `q` parameter, including `q=` for the full catalog. Preserve any explicitly configured, non-secret endpoint parameters. A query such as `lamp & mug` must arrive as one parameter, not create a second parameter.

For example, a locally supplied endpoint might be `/catalog?q=outdoor`. This is a contract example, not a promised public API. The server owns filtering; matching is case-insensitive substring search over title and category, consistent with the demo. The adapter preserves response order and does not silently re-filter or paginate.

Successful responses use status **200**, UTF-8 JSON, and the media type `application/json` (an optional UTF-8 charset parameter is allowed):

```json
{
  "items": [
    {
      "id": "trail",
      "title": "Trail notebook",
      "category": "Outdoor",
      "description": "A fictional notebook for the catalog architecture demo."
    }
  ]
}
```

Proposed validation rules:

- The top-level value is an object and `items` is a list. `{"items": []}` is valid empty data; an empty body or 204 is not.
- Every item is an object with string `id`, `title`, `category`, and `description`. All must contain non-whitespace text. Do not coerce numbers, nulls, or other types into strings; retain valid field text as supplied.
- IDs must be unique within the response. Reject the entire response on any invalid item rather than silently dropping products. Unknown object fields are ignored for additive compatibility.
- Bound decoded response bytes to 256 KiB while consuming the stream, not after collecting an unlimited body. Accept at most 200 items; maximum string lengths are 128 Unicode scalar values for `id`, 200 for `title`/`category`, and 2,000 for `description`. These are teaching-example limits, configurable only through an intentional contract revision.
- Invalid UTF-8, malformed JSON, unsupported media type, invalid schema, duplicate IDs, or exceeded limits become a typed invalid-response failure. No partial result reaches the repository.
- Only the repository creates `CatalogSnapshot` and stamps its injected clock after full success. Server timestamps cannot change local TTL semantics.

Use fictional JSON fixtures in `test/fixtures/catalog/`; no production payloads. Endpoint construction rejects fragments, embedded credentials, and unsupported schemes. Use HTTPS except an explicit loopback HTTP endpoint for local development. Do not configure authentication headers. Redirect behavior must be explicitly tested for supported clients before HTTP mode is documented; do not claim portable redirect blocking from client flags alone.

## Typed failure boundary

Propose a Dart sealed `CatalogFailure implements Exception` hierarchy in the model/contract layer. These names describe future types, not existing code:

| Type | Trigger | Presentation policy |
| --- | --- | --- |
| `CatalogTimeout` | The operation's deadline expires | Explain that the request took too long; allow manual retry. |
| `CatalogConnectivityFailure` | Client transport failure without a usable HTTP response | Explain that the service could not be reached; allow manual retry. Never assert the device is offline. |
| `CatalogHttpFailure(statusCode)` | Any final status other than 200, including 204 and 304 | Map to safe service-unavailable or rejected-request copy. Preserve status for diagnostics, not raw widget display. |
| `CatalogInvalidResponse(reason)` | Successful status with invalid content or limits | Explain that the service returned unusable data. Keep old results; avoid automatic retry. `reason` is a bounded enum. |
| `CatalogCancelled` | Owning repository/session shuts down | Lifecycle control flow; do not present an error banner to a disposed screen. |

Browser network failures can hide whether the underlying cause was CORS, DNS, TLS, or connectivity. Keep these in the same connectivity category rather than inventing certainty. Non-200 status takes precedence over body decoding: an HTML 503 page is an HTTP failure, not invalid JSON. Stop consuming its body and release request resources.

The adapter translates known client, timeout, and decoding exceptions. Do not reclassify arbitrary programming errors as network failures. The controller retains a safe generic fallback for unexpected exceptions, with optional sanitized diagnostics outside widgets. No response bodies, URLs containing queries, credentials, or raw exception strings appear in public error messages.

Move simulated `CatalogUnavailable` behavior to `CatalogConnectivityFailure` when this contract is implemented, updating its callers and tests together. The controller maps types to immutable presentation state/text; widgets never import the HTTP library. With a cached snapshot, every failure message also says saved session results remain available. No failure mutates that snapshot or its timestamp.

Retries remain explicit user actions. There is no `RetryClient`, hidden retry loop, or immediate retry on 429/503. A retry uses a new operation after cleanup; failure of one query must not poison another.

## Deadline and cleanup

Propose a constructor-injected deadline of **8 seconds** per underlying request. This is a lab default, not a measured production service objective. Start once before sending; include waiting for headers, reading the entire body, and validation. A later consumer joining an in-flight request inherits its remaining time rather than resetting the deadline.

Use an injected timer/scheduler and monotonic elapsed-time source for deterministic tests. The repository's wall clock still controls cache TTL; clock rollback must not alter request deadlines. Check elapsed time before committing a decoded result because synchronous JSON parsing cannot be preempted by a Dart timer; byte/item limits bound that work.

At the deadline, settle the operation as `CatalogTimeout`, trigger per-request abort, cancel stream consumption, and clear the timer/listeners. Dart's [`Future.timeout`](https://api.dart.dev/dart-async/Future/timeout.html) alone does not cancel its source future. Keep a terminal-state guard so completion, timeout, and cancellation can settle the result only once; whichever terminal transition wins is retained. An abort exception caused by the deadline remains a timeout, not a cancellation or connectivity error.

Handle errors from both `send` and the response stream, including late errors after settlement. Late completion cannot write a cache entry. Clean up on success, error, timeout, cancellation, synchronous client throw, and validation failure. Remove an in-flight entry only if it still belongs to that operation, so an old finalizer cannot remove a replacement retry.

## Cancellation ownership without breaking shared requests

For the first implementation, **consumers do not own transport cancellation**. Keep `CatalogRepository.refresh(query)` returning a shared future; do not attach a widget's cancellation token directly to the shared request.

1. The repository creates one cancellation source for each underlying normalized-query operation. Extend `CatalogService.fetch` with an optional transport-independent cancellation signal; the default is never cancelled. Update every service fake/implementation in the same change.
2. If consumers A and B refresh the same query, both join one operation. A switching searches or disposing its controller only stops A from applying results through the existing generation guard. B still receives the result. Even with no remaining visible consumer, the bounded request may finish and warm its own cache; this preserves the current race behavior.
3. Add explicit repository/session disposal to the repository contract. Its owner, not an arbitrary consumer, cancels all owned requests, clears session state, and rejects later refresh calls as cancelled. Pending callers settle with `CatalogCancelled`; there are no late cache writes. Document ownership at construction. Sharing a repository means disposing one controller must never dispose that repository.
4. At **Reset demo**, invalidate/dispose the old controller before disposing its exclusively owned repository, then create the new session. Simulated delays must honor the signal on reset; ordinary race runs still allow the older request to finish.
5. The adapter aborts individual requests, not the shared client. The composition owner closes its client once the session ends. An adapter receiving a borrowed client never closes it. Cancellation is idempotent, and an already-cancelled signal prevents sending.

This deliberately avoids reference counting or a new subscription/lease API. If future requirements demand aborting as soon as the last consumer leaves, introduce explicit consumer leases in a separate design: cancelling A detaches only A, and only zero active leases can abort the request. Do not infer consumer counts from a `Future`, and do not change the current exact-future sharing contract accidentally.

## Dependency and composition choice

Prefer `package:http` with an injected `Client` and per-request `AbortableRequest` through `send`. Its [official documentation](https://pub.dev/packages/http#aborting-requests) describes abort support for `BrowserClient` and `IOClient`, including abort errors during body streaming. Pin a compatible minimum supporting these APIs and commit the resolved lockfile in the implementation PR; verify the actual resolved version on web and VM. No dependency is added by this proposal.

Keep a thin adapter rather than building a networking framework. Direct `dart:io` would exclude the browser; a larger client stack such as Dio adds features this one-endpoint example does not currently need. Injecting the client supports simple response fakes; use a scripted streaming client for deadline/abort tests instead of assuming `MockClient` proves real transport cancellation.

`main.dart` remains the simulated entry point for GitHub Pages, CI's standard web build, and README quick start. A future separate opt-in example entry point may construct the HTTP adapter with a developer-supplied local fixture server. No automatic switch, runtime endpoint input, secret build variable, browser-stored key, or fallback masking a broken HTTP endpoint. Browser CORS configuration belongs to the optional local server documentation; mock tests cannot establish CORS behavior.

## Test plan and acceptance gate

All new unit/contract tests run without internet, API keys, or wall-clock sleeps. Inject the client, cancellation signal, deadline scheduler, and repository clock. Use controlled futures/streams and fictional fixtures.

| Area | Required scenarios and observable assertions |
| --- | --- |
| Request construction | GET/Accept header; normalized query; empty query; spaces, `&`, `+`, `?`, and Unicode remain one decoded `q` value; invalid endpoint rejected before send. |
| Success | Valid ordered items and empty list; unknown fields tolerated; repository stamps completion time once and returns immutable snapshots. |
| Invalid response | Invalid UTF-8/JSON, missing/wrong fields, duplicate IDs, unsupported media type, byte/item/string limits; entire response rejected and old cache retained. Test exact limits and one beyond. |
| Status/connectivity | 204, 304, 400, 401, 404, 429, 500, 503; HTML error body stays HTTP failure; client errors before headers and mid-body map to connectivity. No automatic retries. |
| Deadline | Hung headers and stalled body; just-before success, exact-deadline expiry, late success/error; one terminal outcome, abort signal, stream/timer cleanup, no late cache write. Joining caller does not extend deadline. |
| Cancellation | Signal already cancelled; cancellation before headers and mid-body; repeated cancellation; cancellation racing success/timeout; disposed repository rejects new work; borrowed client stays open. |
| Shared ownership | A+B same normalized query produce one request/shared future; disposing A's controller does not abort B; owner disposal cancels both; other queries remain independent unless the whole owner is disposed. |
| Cache/recovery | Seed successful cache, fail each category, retain original snapshot/time; next refresh sends again and can succeed; old completion/finalizer cannot replace/remove a newer operation. |
| Presentation | Typed load/refresh messages, cached content visible, Retry recoverable, stale errors ignored, no notifications after controller disposal, no raw transport text in semantics or widgets. |
| Existing demo | All existing tests, request-race success/failure/reset, keyboard navigation, and 320-pixel/2x-text checks stay green. Standard web build starts with no network catalog calls or configuration. |

Add a separate loopback integration suite for real client abort before headers and during streaming, on VM and a supported browser. Verify server disconnect where observable and no late result delivery; do not claim remote server work is guaranteed to stop. Keep these integration tests isolated from fast unit tests and public endpoints. Browser smoke checks cover the opt-in local endpoint/CORS and the unchanged key-free public demo. Record platforms actually tested; a web build alone does not prove native transport behavior.

Suggested future files: `lib/catalog_http.dart`, `test/catalog_http_test.dart`, `test/catalog_cancellation_test.dart`, and `test/fixtures/catalog/`. Keep model failure/signal types free of Flutter and HTTP imports. Run formatting, analysis, existing/new tests, and the release web build before merging implementation.

## Review and follow-up scope

The owner accepted the 8-second budget, strict response limits, and owner-only cancellation by authorizing implementation. The implementation pull request records code, tests, and validation and closes [#4](https://github.com/RamySaleeb/flutter-mobile-architecture-lab/issues/4). Future consumer leases or native device coverage should be separate, focused follow-ups.

Out of scope: authentication, API keys, payments, background sync, durable storage, pagination, automatic retries, production hosting, a public backend commitment, and production observability. All fixtures and example code remain original and fictional; no private, employer, client, or startup source is used.
