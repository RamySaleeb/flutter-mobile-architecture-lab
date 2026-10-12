import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_catalog/catalog.dart';
import 'package:pocket_catalog/catalog_data.dart';
import 'package:pocket_catalog/catalog_controller.dart';
import 'package:pocket_catalog/main.dart';
import 'package:flutter/material.dart';

const item = CatalogItem('1', 'Notebook', 'Outdoor', 'Fictional test item');

class ControlledService implements CatalogService {
  final requests = <String, List<Completer<List<CatalogItem>>>>{};
  int get calls => requests.values.fold(0, (n, list) => n + list.length);
  @override
  Future<List<CatalogItem>> fetch(
    String query, {
    CatalogCancellation? cancellation,
  }) {
    final request = Completer<List<CatalogItem>>();
    (requests[query] ??= []).add(request);
    return request.future;
  }

  void succeed(String query, [List<CatalogItem> items = const [item]]) =>
      requests[query]!.last.complete(items);
  void fail(String query) =>
      requests[query]!.last.completeError(const CatalogConnectivityFailure());
}

class SynchronousFailureService implements CatalogService {
  int calls = 0;
  @override
  Future<List<CatalogItem>> fetch(
    String query, {
    CatalogCancellation? cancellation,
  }) {
    calls++;
    throw const CatalogConnectivityFailure();
  }
}

void main() {
  test('same normalized query shares a single in-flight request', () async {
    final service = ControlledService();
    final repository = CachedCatalogRepository(service);
    final first = repository.refresh(' Outdoor ');
    final second = repository.refresh('outdoor');
    expect(identical(first, second), isTrue);
    expect(service.calls, 1);
    service.succeed('outdoor');
    await first;
    expect(repository.cached('OUTDOOR')!.items, [item]);
  });

  test('cache is immutable and expires exactly at TTL', () async {
    var now = DateTime.utc(2026);
    final service = ControlledService();
    final repository = CachedCatalogRepository(service, clock: () => now);
    final pending = repository.refresh('');
    final source = [item];
    service.succeed('', source);
    final snapshot = await pending;
    source.clear();
    expect(snapshot.items, [item]);
    expect(() => snapshot.items.clear(), throwsUnsupportedError);
    expect(repository.isFresh(snapshot), isTrue);
    now = snapshot.fetchedAt.add(
      const Duration(seconds: 30) - const Duration(microseconds: 1),
    );
    expect(repository.isFresh(snapshot), isTrue);
    now = snapshot.fetchedAt.add(const Duration(seconds: 30));
    expect(repository.isFresh(snapshot), isFalse);
    now = now.add(const Duration(microseconds: 1));
    expect(repository.isFresh(snapshot), isFalse);
  });

  test(
    'clock rollback marks cache stale without erasing it; recovery restores freshness',
    () async {
      final fetchedAt = DateTime.utc(2026, 10, 12, 12);
      var now = fetchedAt;
      final service = ControlledService();
      final repository = CachedCatalogRepository(service, clock: () => now);
      addTearDown(repository.dispose);
      final pending = repository.refresh('outdoor');
      service.succeed('outdoor');
      final snapshot = await pending;
      expect(snapshot.fetchedAt, fetchedAt);
      expect(repository.isFresh(snapshot), isTrue);

      // Both a minimal negative age and a larger rollback must be stale.
      for (final rollback in [
        const Duration(microseconds: 1),
        const Duration(hours: 1),
      ]) {
        now = fetchedAt.subtract(rollback);
        expect(
          repository.isFresh(snapshot),
          isFalse,
          reason: '$rollback rollback',
        );
        expect(repository.cached('OUTDOOR'), same(snapshot));
        expect(snapshot.items, [item]);
        expect(snapshot.fetchedAt, fetchedAt);
      }

      // Clock correction restores freshness without refetching or replacing data.
      for (final age in [Duration.zero, const Duration(seconds: 15)]) {
        now = fetchedAt.add(age);
        expect(
          repository.isFresh(snapshot),
          isTrue,
          reason: 'restored age $age',
        );
        expect(repository.cached('outdoor'), same(snapshot));
        expect(snapshot.fetchedAt, fetchedAt);
      }
      expect(service.calls, 1);
    },
  );

  test(
    'least recently used entry is evicted when capacity is reached',
    () async {
      final service = ControlledService();
      final repository = CachedCatalogRepository(service, capacity: 2);
      for (final key in ['a', 'b']) {
        final pending = repository.refresh(key);
        service.succeed(key);
        await pending;
      }
      repository.cached('a');
      final pending = repository.refresh('c');
      service.succeed('c');
      await pending;
      expect(repository.cached('b'), isNull);
      expect(repository.cached('a'), isNotNull);
    },
  );

  test('failure retains last good cache and allows a later retry', () async {
    final service = ControlledService();
    final repository = CachedCatalogRepository(service);
    var pending = repository.refresh('');
    service.succeed('');
    final original = await pending;
    pending = repository.refresh('');
    final failure = expectLater(
      pending,
      throwsA(isA<CatalogConnectivityFailure>()),
    );
    service.fail('');
    await failure;
    expect(repository.cached(''), same(original));
    pending = repository.refresh('');
    service.succeed('', []);
    expect((await pending).items, isEmpty);
    expect(service.calls, 3);
  });

  test('synchronously throwing adapters do not poison retries', () async {
    final service = SynchronousFailureService();
    final repository = CachedCatalogRepository(service);
    for (var i = 0; i < 2; i++) {
      await expectLater(
        repository.refresh(''),
        throwsA(isA<CatalogConnectivityFailure>()),
      );
    }
    expect(service.calls, 2);
  });

  test('latest query wins even when older request completes last', () async {
    final service = ControlledService();
    final repository = CachedCatalogRepository(service);
    final controller = CatalogController(repository);
    addTearDown(controller.dispose);
    final older = controller.load('old');
    final newer = controller.load('new');
    service.succeed('new', []);
    await newer;
    service.succeed('old');
    await older;
    expect(controller.state.query, 'new');
    expect(controller.state.snapshot!.items, isEmpty);
    expect(repository.cached('old'), isNotNull);
  });

  test(
    'fresh cache avoids a request; forced failure keeps content visible',
    () async {
      final service = ControlledService();
      final controller = CatalogController(CachedCatalogRepository(service));
      addTearDown(controller.dispose);
      final initial = controller.load('');
      service.succeed('');
      await initial;
      await controller.load('');
      expect(service.calls, 1);
      final refresh = controller.load('', force: true);
      expect(controller.state.loading, isTrue);
      expect(controller.state.snapshot!.items, [item]);
      service.fail('');
      await refresh;
      expect(controller.state.error, isNotNull);
      expect(controller.state.snapshot!.items, [item]);
    },
  );

  test('stale cache appears immediately while revalidation runs', () async {
    var now = DateTime.utc(2026);
    final service = ControlledService();
    final controller = CatalogController(
      CachedCatalogRepository(service, clock: () => now),
    );
    addTearDown(controller.dispose);
    final initial = controller.load('');
    service.succeed('');
    await initial;
    now = now.add(const Duration(minutes: 1));
    final refresh = controller.load('');
    expect(controller.state.fromCache, isTrue);
    expect(controller.state.loading, isTrue);
    expect(controller.state.snapshot!.items, [item]);
    service.succeed('', []);
    await refresh;
    expect(controller.state.fromCache, isFalse);
  });

  test('completion after disposal does not notify listeners', () async {
    final service = ControlledService();
    final controller = CatalogController(CachedCatalogRepository(service));
    var notifications = 0;
    controller.addListener(() => notifications++);
    final pending = controller.load('');
    controller.dispose();
    service.succeed('');
    await pending;
    expect(notifications, 1);
  });

  test('uncached failure produces a recoverable empty error state', () async {
    final service = ControlledService();
    final controller = CatalogController(CachedCatalogRepository(service));
    addTearDown(controller.dispose);
    final pending = controller.load('missing');
    service.fail('missing');
    await pending;
    expect(controller.state.snapshot, isNull);
    expect(controller.state.loading, isFalse);
    expect(controller.state.error, contains('Try again'));
  });

  test('older failure cannot overwrite newer content or error state', () async {
    final service = ControlledService();
    final repository = CachedCatalogRepository(service);
    final controller = CatalogController(repository);
    addTearDown(controller.dispose);
    final older = controller.load('outdoor');
    final newer = controller.load('workspace');
    service.succeed('workspace', [item]);
    await newer;
    final latest = controller.state;
    service.fail('outdoor');
    await older;
    expect(controller.state, same(latest));
    expect(controller.state.error, isNull);
    expect(repository.cached('outdoor'), isNull);
    expect(repository.cached('workspace')!.items, [item]);
  });

  for (final olderFails in [false, true]) {
    testWidgets('race shows latest results; older failure=$olderFails', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1000, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const PocketCatalogApp());
      await tester.pump(const Duration(seconds: 1));
      final button = find.text(
        olderFails ? 'Run with older failure' : 'Run request race',
      );
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump();
      expect(find.textContaining('Outdoor started first'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.text('Orbit desk lamp'), findsOneWidget);
      expect(find.text('Trail notebook'), findsNothing);
      expect(find.textContaining('Outdoor is still pending'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 2300));
      expect(find.text('Orbit desk lamp'), findsOneWidget);
      expect(find.text('Trail notebook'), findsNothing);
      expect(
        find.textContaining(
          olderFails
              ? 'Older Outdoor request failed'
              : 'Older Outdoor request finished',
        ),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsNothing);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
      // Re-running must start real requests, even with the same query names.
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump();
      expect(find.textContaining('Outdoor started first'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Reset demo'));
      await tester.tap(find.text('Reset demo'));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('Trail notebook'), findsOneWidget);
      expect(find.textContaining('4. Older'), findsNothing);
    });
  }

  testWidgets(
    'reset during race isolates late completions and restores normal search',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const PocketCatalogApp());
      await tester.pump(const Duration(seconds: 1));
      await tester.ensureVisible(find.text('Run with older failure'));
      await tester.tap(find.text('Run with older failure'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Reset demo'));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Trail notebook'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(find.textContaining('4. Older'), findsNothing);
      expect(find.text('Retry'), findsNothing);
      await tester.ensureVisible(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'outdoor');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.text('Trail notebook'), findsOneWidget);
      expect(find.text('Orbit desk lamp'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('disposing a running race ignores late callbacks', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const PocketCatalogApp());
    await tester.ensureVisible(find.text('Run request race'));
    await tester.tap(find.text('Run request race'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('browse, search, and failed refresh retain useful UI', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const PocketCatalogApp());
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('Trail notebook'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'outdoor');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('Trail notebook'), findsOneWidget);
    expect(find.text('Orbit desk lamp'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('Fail next refresh'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Fail next refresh'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Retry'),
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Trail notebook'), findsOneWidget);
  });
}
