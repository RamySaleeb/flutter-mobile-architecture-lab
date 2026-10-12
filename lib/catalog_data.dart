import 'dart:collection';
import 'dart:async';
import 'catalog.dart';

/// A bounded, query-keyed session cache. There is no disk persistence.
class CachedCatalogRepository implements CatalogRepository {
  CachedCatalogRepository(
    this.service, {
    DateTime Function()? clock,
    this.ttl = const Duration(seconds: 30),
    this.capacity = 20,
  }) : assert(capacity > 0),
       _clock = clock ?? DateTime.now;

  final CatalogService service;
  final DateTime Function() _clock;
  final Duration ttl;
  final int capacity;
  final _cache = LinkedHashMap<String, CatalogSnapshot>();
  final _inFlight = <String, _CatalogRequest>{};
  bool _disposed = false;

  @override
  CatalogSnapshot? cached(String query) {
    if (_disposed) return null;
    final key = normalizeQuery(query);
    final snapshot = _cache.remove(key);
    if (snapshot != null) _cache[key] = snapshot;
    return snapshot;
  }

  @override
  bool isFresh(CatalogSnapshot snapshot) {
    final age = _clock().difference(snapshot.fetchedAt);
    return !age.isNegative && age < ttl;
  }

  @override
  Future<CatalogSnapshot> refresh(String query) {
    if (_disposed) return Future.error(const CatalogCancelled());
    final key = normalizeQuery(query);
    final existing = _inFlight[key];
    if (existing != null) return existing.future;
    final request = _CatalogRequest();
    _inFlight[key] = request;
    request.future = _fetch(key, request);
    return request.future;
  }

  Future<CatalogSnapshot> _fetch(String key, _CatalogRequest request) async {
    try {
      // Future.sync also normalizes adapters that throw before returning a Future.
      final items = await request.source.signal.bind(
        Future<List<CatalogItem>>.sync(
          () => service.fetch(key, cancellation: request.source.signal),
        ),
      );
      if (_disposed || request.source.signal.isCancelled) {
        throw const CatalogCancelled();
      }
      final snapshot = CatalogSnapshot(items, _clock());
      _cache.remove(key);
      _cache[key] = snapshot;
      while (_cache.length > capacity) {
        _cache.remove(_cache.keys.first);
      }
      return snapshot;
    } finally {
      // Failures do not overwrite the last good snapshot or poison retries.
      if (identical(_inFlight[key], request)) _inFlight.remove(key);
    }
  }

  /// Called by the session owner, never by an individual shared consumer.
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final request in _inFlight.values.toList()) {
      request.source.cancel();
    }
    _inFlight.clear();
    _cache.clear();
  }
}

class _CatalogRequest {
  final source = CatalogCancellationSource();
  late final Future<CatalogSnapshot> future;
}

/// Deliberately simulated transport: no network, credentials, or analytics.
class DemoCatalogService implements CatalogService {
  DemoCatalogService({this.delayForQuery, this.failsForQuery});
  Duration Function(String query)? delayForQuery;
  bool Function(String query)? failsForQuery;
  bool offline = false;
  bool failNext = false;
  static const items = [
    CatalogItem(
      'trail',
      'Trail notebook',
      'Outdoor',
      'A pocket notebook for routes, sketches, and ideas along the way.',
    ),
    CatalogItem(
      'lamp',
      'Orbit desk lamp',
      'Workspace',
      'A compact light for a quiet, focused workspace.',
    ),
    CatalogItem(
      'bottle',
      'Ridge water bottle',
      'Outdoor',
      'A reusable companion for a walk around the neighborhood.',
    ),
    CatalogItem(
      'stand',
      'Fold laptop stand',
      'Workspace',
      'A simple stand that makes room for the work in front of you.',
    ),
    CatalogItem(
      'pouch',
      'Canvas cable pouch',
      'Travel',
      'A small home for the cables that always disappear in your bag.',
    ),
    CatalogItem(
      'mug',
      'Morning ceramic mug',
      'Home',
      'A little ritual before the first task of the day.',
    ),
  ];

  @override
  Future<List<CatalogItem>> fetch(
    String query, {
    CatalogCancellation? cancellation,
  }) async {
    if (cancellation?.isCancelled ?? false) throw const CatalogCancelled();
    final key = normalizeQuery(query);
    final shouldFail =
        offline || failNext || (failsForQuery?.call(key) ?? false);
    failNext = false;
    final ready = Completer<void>();
    final timer = Timer(
      delayForQuery?.call(key) ?? const Duration(milliseconds: 750),
      () => ready.complete(),
    );
    final unsubscribe = cancellation?.listen(() {
      timer.cancel();
      if (!ready.isCompleted) ready.completeError(const CatalogCancelled());
    });
    try {
      await ready.future;
      if (cancellation?.isCancelled ?? false) throw const CatalogCancelled();
    } finally {
      timer.cancel();
      unsubscribe?.call();
    }
    if (shouldFail) throw const CatalogConnectivityFailure();
    return items
        .where(
          (item) =>
              '${item.title} ${item.category}'.toLowerCase().contains(key),
        )
        .toList();
  }
}
