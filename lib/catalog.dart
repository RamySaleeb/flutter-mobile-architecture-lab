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
  Future<List<CatalogItem>> fetch(String query);
}

abstract interface class CatalogRepository {
  CatalogSnapshot? cached(String query);
  bool isFresh(CatalogSnapshot snapshot);
  Future<CatalogSnapshot> refresh(String query);
}

class CatalogUnavailable implements Exception {
  const CatalogUnavailable();
}

String normalizeQuery(String query) => query.trim().toLowerCase();
