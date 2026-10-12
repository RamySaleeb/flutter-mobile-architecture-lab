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
  Future<List<CatalogItem>> fetch(String query) {
    final request = Completer<List<CatalogItem>>();
    (requests[query] ??= []).add(request);
    return request.future;
  }

  void succeed(String query, [List<CatalogItem> items = const [item]]) =>
      requests[query]!.last.complete(items);
  void fail(String query) =>
      requests[query]!.last.completeError(const CatalogUnavailable());
}

class SynchronousFailureService implements CatalogService {
  int calls = 0;
  @override
  Future<List<CatalogItem>> fetch(String query) {
    calls++;
    throw const CatalogUnavailable();
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
    now = now.add(const Duration(seconds: 30));
    expect(repository.isFresh(snapshot), isFalse);
  });

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
    final failure = expectLater(pending, throwsA(isA<CatalogUnavailable>()));
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
        throwsA(isA<CatalogUnavailable>()),
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

  testWidgets('browse, search, and failed refresh retain useful UI', (
    tester,
  ) async {
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
