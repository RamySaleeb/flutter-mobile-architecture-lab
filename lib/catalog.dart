import 'dart:async';

/// Framework-independent contracts and immutable data.
class CatalogItem {
  const CatalogItem(this.id, this.title, this.category, this.description);
  final String id;
  final String title;
  final String category;
  final String description;
}

class CatalogSnapshot {
  CatalogSnapshot(List<CatalogItem> items, this.fetchedAt)
    : items = List.unmodifiable(items);
  final List<CatalogItem> items;
  final DateTime fetchedAt;
}

abstract interface class CatalogService {
  Future<List<CatalogItem>> fetch(
    String query, {
    CatalogCancellation? cancellation,
  });
}

abstract interface class CatalogRepository {
  CatalogSnapshot? cached(String query);
  bool isFresh(CatalogSnapshot snapshot);
  Future<CatalogSnapshot> refresh(String query);
  void dispose();
}

sealed class CatalogFailure implements Exception {
  const CatalogFailure();
}

final class CatalogTimeout extends CatalogFailure {
  const CatalogTimeout();
}

final class CatalogConnectivityFailure extends CatalogFailure {
  const CatalogConnectivityFailure();
}

final class CatalogHttpFailure extends CatalogFailure {
  const CatalogHttpFailure(this.statusCode);
  final int statusCode;
}

enum InvalidResponseReason { encoding, json, mediaType, schema, limit }

final class CatalogInvalidResponse extends CatalogFailure {
  const CatalogInvalidResponse(this.reason);
  final InvalidResponseReason reason;
}

final class CatalogCancelled extends CatalogFailure {
  const CatalogCancelled();
}

/// Read-only cancellation signal. Only the session's source can cancel it.
final class CatalogCancellation {
  CatalogCancellation._();
  bool _cancelled = false;
  final _listeners = <void Function()>{};
  bool get isCancelled => _cancelled;

  /// Returns an unsubscribe function. Already-cancelled signals notify inline.
  void Function() listen(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
    return () => _listeners.remove(listener);
  }

  /// Settles even if a service ignores cancellation; late errors are consumed.
  Future<T> bind<T>(Future<T> future) {
    final result = Completer<T>();
    final unsubscribe = listen(() {
      if (!result.isCompleted) result.completeError(const CatalogCancelled());
    });
    future.then(
      (value) {
        unsubscribe();
        if (!result.isCompleted) result.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        unsubscribe();
        if (!result.isCompleted) result.completeError(error, stack);
      },
    );
    return result.future;
  }
}

final class CatalogCancellationSource {
  final signal = CatalogCancellation._();
  void cancel() {
    if (signal._cancelled) return;
    signal._cancelled = true;
    final listeners = signal._listeners.toList();
    signal._listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }
}

String normalizeQuery(String query) => query.trim().toLowerCase();
