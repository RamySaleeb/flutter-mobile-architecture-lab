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
    } catch (error) {
      if (!_isCurrent(generation)) return;
      _emit(
        CatalogState(
          query: key,
          snapshot: cached,
          fromCache: cached != null,
          error: error is CatalogCancelled
              ? null
              : _message(error, cached != null),
        ),
      );
    }
  }

  String _message(Object error, bool hasCache) {
    final message = switch (error) {
      CatalogTimeout() => 'The catalog request took too long. Try again.',
      CatalogConnectivityFailure() =>
        'Could not reach the catalog service. Try again.',
      CatalogHttpFailure(statusCode: 429 || >= 500) =>
        'The catalog service is unavailable. Try again later.',
      CatalogHttpFailure() =>
        'The catalog service could not accept this request.',
      CatalogInvalidResponse() => 'The catalog service returned unusable data.',
      _ => 'Could not load this catalog. Try again.',
    };
    return hasCache
        ? '$message Your saved session results are still available.'
        : message;
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
