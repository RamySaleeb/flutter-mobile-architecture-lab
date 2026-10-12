import 'dart:collection';
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
  final _inFlight = <String, Future<CatalogSnapshot>>{};

  @override
  CatalogSnapshot? cached(String query) {
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
    final key = normalizeQuery(query);
    return _inFlight[key] ??= _fetch(key);
  }

  Future<CatalogSnapshot> _fetch(String key) async {
    try {
      // Future.sync also normalizes adapters that throw before returning a Future.
      final items = await Future<List<CatalogItem>>.sync(
        () => service.fetch(key),
      );
      final snapshot = CatalogSnapshot(items, _clock());
      _cache.remove(key);
      _cache[key] = snapshot;
      while (_cache.length > capacity) {
        _cache.remove(_cache.keys.first);
      }
      return snapshot;
    } finally {
      // Failures do not overwrite the last good snapshot or poison retries.
      final _ = _inFlight.remove(key);
    }
  }
}

/// Deliberately simulated transport: no network, credentials, or analytics.
class DemoCatalogService implements CatalogService {
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
  Future<List<CatalogItem>> fetch(String query) async {
    final shouldFail = offline || failNext;
    failNext = false;
    await Future<void>.delayed(const Duration(milliseconds: 750));
    if (shouldFail) throw const CatalogUnavailable();
    final key = normalizeQuery(query);
    return items
        .where(
          (item) =>
              '${item.title} ${item.category}'.toLowerCase().contains(key),
        )
        .toList();
  }
}
