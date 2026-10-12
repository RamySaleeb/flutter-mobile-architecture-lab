import 'package:flutter/foundation.dart';
import 'catalog.dart';

class CatalogState {
  const CatalogState({
    this.query = '',
    this.snapshot,
    this.loading = false,
    this.fromCache = false,
    this.error,
  });
  final String query;
  final CatalogSnapshot? snapshot;
  final bool loading;
  final bool fromCache;
  final String? error;
}

/// Owns presentation policy, but never creates a service or touches widgets.
class CatalogController extends ChangeNotifier {
  CatalogController(this.repository);
  final CatalogRepository repository;
  CatalogState _state = const CatalogState();
  CatalogState get state => _state;
  int _generation = 0;
  bool _disposed = false;

  Future<void> load(String query, {bool force = false}) async {
    if (_disposed) return;
    final generation = ++_generation;
    final key = normalizeQuery(query);
    final cached = repository.cached(key);
    final needsRefresh = force || cached == null || !repository.isFresh(cached);
    _emit(
      CatalogState(
        query: key,
        snapshot: cached,
        loading: needsRefresh,
        fromCache: cached != null,
      ),
    );
    if (!needsRefresh) return;
    try {
      final snapshot = await repository.refresh(key);
      if (!_isCurrent(generation)) return;
      _emit(CatalogState(query: key, snapshot: snapshot));
    } catch (_) {
      if (!_isCurrent(generation)) return;
      _emit(
        CatalogState(
          query: key,
          snapshot: cached,
          fromCache: cached != null,
          error: cached == null
              ? 'Could not load this catalog. Try again.'
              : 'Refresh failed. Your saved session results are still available.',
        ),
      );
    }
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;
  void _emit(CatalogState value) {
    _state = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    super.dispose();
  }
}
