import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'catalog.dart';

typedef CatalogTimerFactory = Timer Function(Duration, void Function());

/// Optional adapter. The composition owner owns and closes the injected client.
/// The public main.dart never constructs this service.
final class HttpCatalogService implements CatalogService {
  HttpCatalogService({
    required this.client,
    required this.endpoint,
    this.timeout = const Duration(seconds: 8),
    bool allowLoopbackHttp = false,
    CatalogTimerFactory? schedule,
    Duration Function()? elapsed,
  }) : _schedule = schedule ?? Timer.new {
    final loopback = const {
      'localhost',
      '127.0.0.1',
      '::1',
    }.contains(endpoint.host);
    if (!endpoint.hasAuthority ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasFragment ||
        (endpoint.scheme != 'https' &&
            !(allowLoopbackHttp && loopback && endpoint.scheme == 'http'))) {
      throw ArgumentError('Use HTTPS or explicitly enabled loopback HTTP.');
    }
    if (timeout <= Duration.zero) throw ArgumentError.value(timeout, 'timeout');
    final watch = Stopwatch()..start();
    _elapsed = elapsed ?? () => watch.elapsed;
  }

  final http.Client client;
  final Uri endpoint;
  final Duration timeout;
  final CatalogTimerFactory _schedule;
  late final Duration Function() _elapsed;
  static const maxBytes = 256 * 1024;
  static const maxItems = 200;

  @override
  Future<List<CatalogItem>> fetch(
    String query, {
    CatalogCancellation? cancellation,
  }) {
    final uri = endpoint.replace(
      queryParameters: {
        ...endpoint.queryParametersAll,
        'q': [normalizeQuery(query)],
      },
    );
    return _HttpOperation(this, uri, cancellation).start();
  }
}

class _HttpOperation {
  _HttpOperation(this.service, this.uri, this.cancellation);
  final HttpCatalogService service;
  final Uri uri;
  final CatalogCancellation? cancellation;
  final result = Completer<List<CatalogItem>>();
  final abort = Completer<void>();
  final bytes = BytesBuilder(copy: false);
  // Every terminal path calls cleanup/cancelStream, including late headers.
  // ignore: cancel_subscriptions
  StreamSubscription<List<int>>? subscription;
  Timer? timer;
  void Function()? unsubscribe;
  late Duration started;
  bool get done => result.isCompleted;

  Future<List<CatalogItem>> start() {
    started = service._elapsed();
    unsubscribe = cancellation?.listen(() => fail(const CatalogCancelled()));
    if (done) return result.future;
    timer = service._schedule(
      service.timeout,
      () => fail(const CatalogTimeout()),
    );
    final request =
        http.AbortableRequest('GET', uri, abortTrigger: abort.future)
          ..headers['Accept'] = 'application/json'
          ..followRedirects = false;
    // A synchronous client throw and errors after cancellation are both observed.
    unawaited(
      Future<http.StreamedResponse>.sync(() => service.client.send(request))
          .then(headers, onError: transportError)
          .catchError((Object error, StackTrace stack) {
            fail(error, stack);
          }),
    );
    return result.future;
  }

  bool expired() {
    if (done) return true;
    if (service._elapsed() - started >= service.timeout) {
      fail(const CatalogTimeout());
      return true;
    }
    return false;
  }

  void headers(http.StreamedResponse response) {
    if (expired()) {
      discard(response.stream);
      return;
    }
    if (response.statusCode != 200) {
      fail(CatalogHttpFailure(response.statusCode));
      discard(response.stream);
      return;
    }
    final type = response.headers['content-type']?.toLowerCase().split(';');
    if (type == null ||
        type.first.trim() != 'application/json' ||
        type
            .skip(1)
            .any(
              (part) =>
                  !RegExp(r'^\s*charset\s*=\s*"?utf-8"?\s*$').hasMatch(part),
            )) {
      fail(const CatalogInvalidResponse(InvalidResponseReason.mediaType));
      discard(response.stream);
      return;
    }
    subscription = response.stream.listen(
      (chunk) {
        if (expired()) return;
        if (bytes.length + chunk.length > HttpCatalogService.maxBytes) {
          fail(const CatalogInvalidResponse(InvalidResponseReason.limit));
          return;
        }
        bytes.add(chunk);
      },
      onError: transportError,
      onDone: decode,
    );
    // Also covers synchronous streams which terminate during listen.
    if (done) cancelStream();
  }

  void decode() {
    if (expired()) return;
    try {
      String text;
      try {
        text = utf8.decode(bytes.takeBytes());
      } on FormatException {
        throw const CatalogInvalidResponse(InvalidResponseReason.encoding);
      }
      Object? value;
      try {
        value = jsonDecode(text);
      } on FormatException {
        throw const CatalogInvalidResponse(InvalidResponseReason.json);
      }
      final items = parseCatalog(value);
      // Parsing is synchronous; check the budget before publishing its result.
      if (expired()) return;
      result.complete(List.unmodifiable(items));
      cleanup();
    } catch (error, stack) {
      fail(error, stack);
    }
  }

  void transportError(Object error, StackTrace stack) {
    if (expired()) return;
    fail(
      error is http.RequestAbortedException
          ? const CatalogCancelled()
          : error is http.ClientException
          ? const CatalogConnectivityFailure()
          : error,
      stack,
    );
  }

  void fail(Object error, [StackTrace? stack]) {
    if (done) return;
    result.completeError(error, stack);
    if (!abort.isCompleted) abort.complete();
    cleanup();
  }

  void cleanup() {
    timer?.cancel();
    unsubscribe?.call();
    cancelStream();
    bytes.clear();
  }

  void cancelStream() {
    final current = subscription;
    subscription = null;
    if (current != null) unawaited(current.cancel().catchError((Object _) {}));
  }

  void discard(Stream<List<int>> stream) {
    final pending = stream.listen(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    unawaited(pending.cancel().catchError((Object _) {}));
  }
}

List<CatalogItem> parseCatalog(Object? value) {
  Never invalid(InvalidResponseReason reason) =>
      throw CatalogInvalidResponse(reason);
  if (value is! Map<String, dynamic> || value['items'] is! List) {
    invalid(InvalidResponseReason.schema);
  }
  final entries = value['items'] as List;
  if (entries.length > HttpCatalogService.maxItems)
    invalid(InvalidResponseReason.limit);
  final ids = <String>{};
  String field(Map<String, dynamic> item, String name, int maximum) {
    final value = item[name];
    if (value is! String || value.trim().isEmpty)
      invalid(InvalidResponseReason.schema);
    if (value.runes.length > maximum) invalid(InvalidResponseReason.limit);
    return value;
  }

  return entries.map((entry) {
    if (entry is! Map<String, dynamic>) invalid(InvalidResponseReason.schema);
    final id = field(entry, 'id', 128);
    if (!ids.add(id)) invalid(InvalidResponseReason.schema);
    return CatalogItem(
      id,
      field(entry, 'title', 200),
      field(entry, 'category', 200),
      field(entry, 'description', 2000),
    );
  }).toList();
}
