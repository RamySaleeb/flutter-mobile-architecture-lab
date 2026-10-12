# Pocket Catalog

### A Flutter architecture lab for dependable mobile experiences

**[Try the live demo →](https://ramysaleeb.github.io/flutter-mobile-architecture-lab/)** · Runs in your browser; no installation or sign-in required.

An original, runnable demo by [Ramy Saleeb](https://github.com/RamySaleeb), built around one question: **what should the user see when a request is slow, fails, or finishes out of order?**

Pocket Catalog browses fictional products through a simulated service. It keeps useful content visible during refresh, reuses fresh cached results, and prevents older requests from replacing a newer search. No API keys, backend deployment, or private source code required.

**Flutter · Dart · Repository pattern · Immutable state · Stale-while-revalidate · Behavioral tests**

![Pocket Catalog running in a browser](preview.jpg)

## Start here

For a quick look, [open Pocket Catalog in your browser](https://ramysaleeb.github.io/flutter-mobile-architecture-lab/). Search the fictional catalog, trigger a failed refresh, and try the offline simulation. The cache lasts for the current app session; reloading resets it. Initial loading requires an internet connection.

To explore the source locally:

```bash
git clone https://github.com/RamySaleeb/flutter-mobile-architecture-lab.git
cd flutter-mobile-architecture-lab
flutter pub get
flutter test
# Generate standard platform hosts; the architecture source stays in lib/.
flutter create --platforms=android,ios,web --project-name=pocket_catalog --no-pub .
flutter run -d chrome
```

Tested with **Flutter 3.47.7 / Dart 3.13.5**. Use `flutter devices` and `flutter run -d <device-id>` for an Android emulator or iOS simulator. Native runs require the usual Android SDK or Xcode setup; they have not been device-tested for this initial release. Platform scaffolding is generated, not maintained in this repository. The optional HTTP adapter uses `http` 1.6.0; the default demo still constructs only the simulated service.

## A two-minute walkthrough

[Open the live demo](https://ramysaleeb.github.io/flutter-mobile-architecture-lab/) and start with a fresh page. Scroll below the results to find the simulation controls. Submit searches with Enter or the arrow button; typing alone does not start a request.

| Step | Try this | What you should see | What it demonstrates |
| --- | --- | --- | --- |
| 1. Browse | Wait for the initial load. | Six fictional products and **Fresh from demo service**. | Loading becomes useful content. |
| 2. Search and reuse | Submit `outdoor`, then submit it again within 30 seconds. | Trail notebook and Ridge water bottle; the second submission shows **Session cache**. | A fresh query cache avoids another service call. |
| 3. Fail safely | With those results loaded, click **Fail next refresh**. | An error with **Retry**, while both products remain visible. | A failed refresh preserves the last good snapshot. This button starts the refresh itself. |
| 4. Recover | Click **Retry** with simulation offline switched off. | The error clears and **Fresh from demo service** returns. | Recovery does not require reloading the page. |
| 5. Try an uncached failure | Switch on **Simulate offline**, then submit `workspace` for the first time. | A recoverable load error, without the unrelated outdoor results. | Cache entries belong to a specific query. |
| 6. Recover and explore empty results | Switch simulation off and click **Retry**; then submit `zzzz`. | Two workspace products, then an empty-results state for `zzzz`. | Empty results and failures are different states. |

**One more experiment:** reload `outdoor`, wait at least 30 seconds, and submit it again. Cached content appears immediately while it revalidates. **Refresh** always requests new data, even if the cache is fresh.

The controls simulate service behavior; they do not inspect or alter device connectivity. Availability is sampled when a request starts, and ordinary simulated requests take 750 ms (the race scenario below uses two different delays). Reloading the page resets the session cache and controls; the initial page load requires internet access.

### Watch the latest search win

Near the search field, choose **Run request race**. No fast typing is needed:

1. A fresh demo session starts an **Outdoor** request with a 3-second delay, then a **Workspace** request with a 0.75-second delay.
2. Workspace finishes first. Orbit desk lamp and Fold laptop stand appear while Outdoor is still pending.
3. Outdoor finishes last. The screen keeps Workspace results; the older response only warms its own query cache.

Choose **Run with older failure** to repeat the sequence with the older request failing. Workspace remains visible, and the obsolete error does not replace the current screen. The status text explains each stage.

Both scenarios force new requests in an isolated session, so repeats work even after those queries were cached. Search and failure controls pause during a race; **Reset demo** is always available and restores normal browsing, an empty cache, and default simulation settings. Reset cancels the old session’s simulated timers; late completions cannot update the screen or its cache. After a completed race, ordinary requests use the normal 750 ms delay again.

These are deterministic simulated delays, not a network benchmark. Request deduplication and completion ordering are also covered by controlled tests.

## Keyboard and accessibility

Use **Tab** and **Shift+Tab** to move between controls. Search accepts the keyboard search action; buttons support **Enter**, and the offline switch supports **Space**. Focused buttons show a strong green outline. Controls below the results remain in the focus order and scroll into view when focused.

The search field and submit icon have accessible names. Loading, error, empty-result, and race messages expose live regions. Browser semantics are enabled at startup. Status text wraps, buttons retain at least 48-pixel minimum dimensions, and decorative product icons are omitted in narrow or enlarged-text layouts to leave room for content.

Automated checks in [accessibility_test.dart](test/accessibility_test.dart) cover a **320 logical-pixel viewport with 2x text**, scrolling to recovery controls, keyboard search/Refresh/offline/Retry, reverse traversal, focus styling, and control/status semantics. The existing cache and race tests also run.

Manual verification uses the **Codex in-app browser on macOS** for keyboard navigation and the exposed browser accessibility tree. No external screen reader or native Android/iOS accessibility service has been tested; this is not a WCAG compliance claim. If you find a barrier, include your browser, OS, assistive technology, text size, and reproduction steps in an issue.

## Architecture

```mermaid
flowchart TD
  View[Flutter view] --> Controller[CatalogController]
  Controller --> Contract[CatalogRepository contract]
  Repo[CachedCatalogRepository] -. implements .-> Contract
  Repo --> Cache[Bounded session cache]
  Repo --> Service[CatalogService contract]
  Demo[DemoCatalogService] -. implements .-> Service
  Demo --> Data[Fictional catalog]
```

| Boundary | Responsibility | Read the code |
| --- | --- | --- |
| Model and contracts | Immutable snapshots; query normalization; transport/repository interfaces | [catalog.dart](lib/catalog.dart) |
| Data | Query-keyed cache, TTL, LRU eviction, in-flight request sharing | [catalog_data.dart](lib/catalog_data.dart) |
| Presentation | Cache-first display, refresh policy, error state, latest-request protection | [catalog_controller.dart](lib/catalog_controller.dart) |
| UI and composition | Material UI, lifecycle, explicit dependency construction, demo controls | [main.dart](lib/main.dart) |
| Verification | Deterministic service fakes and a widget journey | [widget_test.dart](test/widget_test.dart) |

The model and data layer do not import Flutter. The controller depends only on Flutter's lightweight notifier and a repository interface. The view constructs dependencies at its composition boundary; individual product widgets do not access services.

## Behavior under pressure

| Situation | Result |
| --- | --- |
| First load, no cache | Loading state, then content, empty results, or a retryable error |
| Same query, fresh cache | Immediate cached content; no service call |
| Same query, expired cache | Immediate cached content while revalidation runs |
| Manual refresh | Service call even if the cache is fresh |
| Failed refresh | Last good snapshot survives; error and retry are shown |
| Duplicate concurrent query | One shared in-flight service call |
| Older search completes last | Its result may populate its own cache entry, but cannot replace the current screen |
| Screen disposed during a request | No later notifier update |
| More than 20 cached queries | Least recently used entry is evicted |

Freshness is checked when loading, not by a background timer. At exactly 30 seconds an entry is stale. Queries are trimmed and lowercased; the cache never substitutes results from a different query.

## Decisions and tradeoffs

- **Small interfaces over a framework stack.** Constructor injection makes dependencies visible. A container, code generation, and a separate use-case class would add indirection without enough behavior to justify it here.
- **Latest-result protection plus owner-controlled cancellation.** A generation counter protects the screen. Changing searches allows older requests to warm their own cache; resetting or disposing the owning session cancels its work. Disposing one controller never cancels another consumer’s shared request.
- **Bounded in-memory cache over a database.** Twenty query snapshots keep the example readable and bounded. The cache is lost on restart. This is a resilient-read demo, not a durable offline-first sync engine.
- **Manual retry over hidden retry loops.** The UI preserves context and gives the user control. Production policies need bounded backoff, connectivity handling, observability, and error classification.
- **Explicit search submission.** There is no request per keystroke and no debounce timer to manage. Concurrent calls are nevertheless protected and tested.

## Optional HTTP adapter

[`HttpCatalogService`](lib/catalog_http.dart) implements the same service boundary with typed timeout, connectivity, HTTP-status, invalid-response, and cancellation failures. Each shared HTTP operation has one 8-second deadline covering headers, body streaming, and decoding. Strict JSON validation and response-size limits prevent partial or unbounded results. Failures retain the last good snapshot; retries remain manual.

The repository owns cancellation. A controller changing queries or disposing does not abort a request another caller needs. Resetting the owning session cancels pending work, clears timers/streams, and blocks late cache writes. The injected HTTP client belongs to its composition owner, which closes it at shutdown.

**The public live demo remains simulated, with no API keys or catalog network requests.** HTTP is opt-in code, not a mode visitors can accidentally enable. See the [design and implementation notes](docs/decisions/0001-optional-http-catalog-adapter.md) for wire format, ownership, and limits.

To exercise real HTTP locally without credentials, run this fictional fixture server from the repository root:

```bash
python3 tool/fixture_server.py
```

In another terminal:

```bash
dart run tool/http_smoke.dart
# Optional browser check: compile, then open http://127.0.0.1:8767/smoke.html
dart compile js tool/http_smoke.dart -o build/http_smoke.js
```

The probe checks success, typed failures, cancellation and deadlines before headers/mid-body, redirect refusal, and client reuse. It prints `HTTP SMOKE PASSED` on success. Stop the local server with Ctrl+C. HTTP requires explicit loopback opt-in; external endpoints must use HTTPS. Redirects are refused: native HTTP exposes their status, while browser fetch reports a connectivity failure. Browser CORS failures cannot reliably be distinguished from other connectivity failures.

Verified on the Dart VM and Codex in-app browser on macOS; Android/iOS device transports have not been tested. [`catalog_http_test.dart`](test/catalog_http_test.dart) runs deterministic injected-client and fake-time checks without starting a server or contacting the internet.

## Verification

```bash
dart format --output=none --set-exit-if-changed lib test tool
flutter analyze
flutter test --coverage
flutter create --platforms=web --project-name=pocket_catalog --no-pub .
flutter build web --release
```

Tests cover shared in-flight requests, TTL boundaries, immutable snapshots, LRU eviction, failure retention, retries after synchronous adapter failures, out-of-order results, stale-cache revalidation, disposal, initial errors, the browse/search/failed-refresh widget journey, and race scenarios covering late success, late failure, repeat runs, reset, and disposal. A [GitHub Actions workflow](.github/workflows/ci.yml) runs formatting, analysis, tests, and a release web build. Successful changes on `main` deploy to GitHub Pages; pull requests run checks without publishing.

## Contribute and explore the roadmap

Want to improve the example? Start with the [contribution guide](CONTRIBUTING.md): setup, design boundaries, verification, and what to include in a pull request. Bug reports, walkthrough feedback, and accessibility checks are welcome too.

| Opportunity | Starting point | Scope |
| --- | --- | --- |
| [Test clock rollback and cache freshness (#1)](https://github.com/RamySaleeb/flutter-mobile-architecture-lab/issues/1) | Good first issue | A deterministic regression test; no production change. |
| [Keyboard access and large-text layouts (#2)](https://github.com/RamySaleeb/flutter-mobile-architecture-lab/issues/2) | Implemented | Keyboard traversal, readable status text, and focused accessibility regression tests. |
| [Request-race demo (#3)](https://github.com/RamySaleeb/flutter-mobile-architecture-lab/issues/3) | Implemented | Try late success, late failure, and reset in the live demo. |
| [Design an optional HTTP adapter (#4)](https://github.com/RamySaleeb/flutter-mobile-architecture-lab/issues/4) | Implemented | Optional adapter, typed failures, deadlines, owner cancellation, and [tests](test/catalog_http_test.dart); public demo stays simulated. |

Each issue includes starting files and acceptance criteria. Check the [issue tracker](https://github.com/RamySaleeb/flutter-mobile-architecture-lab/issues) for current status and comment before starting to avoid duplicate work. These are proposed contributions, not delivery commitments.

## Scope and next steps

This is a focused architecture showcase, not a shopping product or production template. The public demo has no payments, authentication, catalog network requests, persistence, background sync, analytics, or deployment credentials. Real HTTP is available only through the separately constructed optional adapter. All product names and descriptions are fictional. No private, client, employer, or startup source is included.

Natural extensions are a durable store with migrations and native device integration tests. Each should preserve the existing repository contract and observable UI behavior.

## About

Created as a standalone public engineering example for [Ramy Saleeb's GitHub profile](https://github.com/RamySaleeb). For professional background and contact, see [LinkedIn](https://www.linkedin.com/in/ramy-saleeb/).

The separation of view, presentation state, repository, and service is consistent with the [Flutter architecture guide](https://docs.flutter.dev/app-architecture/guide). The implementation and fictional demo content in this repository are original.

## License

[MIT](LICENSE).
