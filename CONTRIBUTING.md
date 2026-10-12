# Contributing to Pocket Catalog

Thanks for helping make dependable mobile behavior easier to understand. Documentation, reproducible bug reports, accessibility feedback, and focused tests are as useful as new features.

## Pick a useful starting point

Read the [walkthrough and architecture](README.md), then browse the [open issues](https://github.com/RamySaleeb/flutter-mobile-architecture-lab/issues). Issues marked **good first issue** have deliberately narrow scope; **help wanted** identifies contributions that are welcome. Comment with your approach before starting a roadmap item to avoid duplicate work. Small typo fixes can go straight to a pull request.

For a larger feature or a new dependency, open an issue explaining the user-visible problem, proposed scope, alternatives, and how it will be tested. Roadmap issues are invitations to collaborate, not promised delivery dates.

## Set up your fork

Use Flutter **3.47.7** (the version pinned in CI), Git, and Chrome for the browser demo. Fork the repository to your own account, clone your fork, then create a branch:

```bash
git clone https://github.com/YOUR-USERNAME/flutter-mobile-architecture-lab.git
cd flutter-mobile-architecture-lab
git switch -c improve-catalog
flutter pub get
flutter test
flutter create --platforms=web --project-name=pocket_catalog --no-pub .
flutter run -d chrome
```

Replace `YOUR-USERNAME` with your GitHub username. Platform hosts are generated locally and ignored by Git. Do not commit `web/`, native host folders, build outputs, coverage output, IDE files, or SDK-generated metadata. Keep changes to package configuration and the lockfile intentional; inspect `git diff` after scaffolding.

## Keep the architecture readable

- Models and data code stay independent of Flutter widgets.
- Inject services and clocks so tests can control failures, time, and completion order.
- Preserve query isolation, bounded caching, failed-refresh retention, and latest-result protection.
- Prefer a small interface or function when it solves the problem. Explain why a new package or abstraction is needed.
- Keep the default demo runnable without API keys or a backend. Use fictional fixtures and code you have the right to share; never submit private client, employer, or startup code.

See the [architecture map](README.md#architecture) for the relevant files. Existing tests live in `test/widget_test.dart`, `test/accessibility_test.dart`, and `test/catalog_http_test.dart`; additional focused `*_test.dart` files are welcome. Use controlled futures and injected clocks rather than real waits for race and TTL tests.

## Verify a code change

```bash
dart format lib test tool
flutter analyze
flutter test --coverage
flutter create --platforms=web --project-name=pocket_catalog --no-pub .
flutter build web --release --base-href /flutter-mobile-architecture-lab/
```

CI also checks that formatting produces no diff. Add a regression test for changed behavior, and run the README walkthrough for UI changes. Include screenshots for visible changes and name the browser/device you actually checked. Native device verification remains separate from widget tests and the web build.

For documentation-only changes, preview the Markdown and check links, commands, and claims against the code; a new test is not needed. CI still runs automatically. Pull requests do not deploy the public site; publishing happens after changes land on `main`.

## Submit a focused pull request

Target `main` in this repository from your fork. Include:

- The problem and resulting behavior, plus `Closes #number` when it resolves an issue.
- Relevant design choices or tradeoffs, including any dependency change.
- Checks performed and their results; clearly state checks you could not run.
- Screenshots or a short reproduction sequence when the UI changes.

Keep unrelated cleanup in separate pull requests. Contributions are reviewed for behavior, clarity, tests, and fit with this small teaching example. Be respectful and specific when discussing alternatives. Submitted code should be compatible with the repository's [MIT license](LICENSE).

## Report a bug or suggest an improvement

Search existing issues first. For a bug, include the demo URL or commit, browser/OS or Flutter version, exact steps, expected behavior, actual behavior, and a minimal screenshot or log when useful. Remove credentials and personal data from attachments. For an idea, describe the problem it solves and the smallest useful change; a feature list alone is harder to evaluate.
