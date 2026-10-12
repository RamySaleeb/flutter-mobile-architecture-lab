import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_catalog/catalog.dart';
import 'package:pocket_catalog/catalog_http.dart';
import 'package:pocket_catalog/catalog_data.dart';
import 'package:pocket_catalog/catalog_controller.dart';

final endpoint = Uri.https('catalog.example', '/catalog', {'version': '1'});
final fixture = File('test/fixtures/catalog/success.json').readAsStringSync();
const jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

class ScriptedClient extends http.BaseClient {
  final requests = <http.AbortableRequest>[];
  final responses = <Completer<http.StreamedResponse>>[];
  int aborts = 0;
  int closes = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final abortable = request as http.AbortableRequest;
    requests.add(abortable);
    unawaited(abortable.abortTrigger!.then((_) => aborts++));
    final response = Completer<http.StreamedResponse>();
    responses.add(response);
    return response.future;
  }

  void succeed([String body = '{"items":[]}']) => responses.last.complete(
    http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      200,
      headers: jsonHeaders,
    ),
  );
  @override
  void close() => closes++;
}

HttpCatalogService service(
  http.Client client, {
  Duration Function()? elapsed,
}) => HttpCatalogService(client: client, endpoint: endpoint, elapsed: elapsed);

void main() {
  test(
    'encodes one normalized query and preserves configured parameters',
    () async {
      final client = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.headers['Accept'], 'application/json');
        expect(request.url.queryParametersAll['q'], ['lamp & mug+?é']);
        expect(request.url.queryParameters['version'], '1');
        expect(request.followRedirects, isFalse);
        return http.Response(fixture, 200, headers: jsonHeaders);
      });
      addTearDown(client.close);
      final items = await service(client).fetch('  LAMP & mug+?É ');
      expect(items.single.id, 'trail');
      expect(() => items.clear(), throwsUnsupportedError);
    },
  );

  test('empty query, ordered items, unknown fields, and empty list', () async {
    final client = MockClient((request) async {
      expect(request.url.queryParametersAll['q'], ['']);
      return http.Response(
        '{"items":[],"extra":true}',
        200,
        headers: jsonHeaders,
      );
    });
    addTearDown(client.close);
    expect(await service(client).fetch(' '), isEmpty);
    final item =
        ((jsonDecode(fixture) as Map<String, dynamic>)['items'] as List).first
            as Map<String, dynamic>;
    final parsed = parseCatalog({
      'items': [
        {...item, 'id': 'b', 'extra': true},
        item,
      ],
    });
    expect(parsed.map((item) => item.id), ['b', 'trail']);
  });

  for (final url in [
    'http://example.com/catalog',
    'https://user:pass@example.com',
    'https://example.com/#fragment',
    '/catalog',
    'file:///catalog',
  ]) {
    test('rejects endpoint $url before send', () {
      final client = ScriptedClient();
      expect(
        () => HttpCatalogService(client: client, endpoint: Uri.parse(url)),
        throwsArgumentError,
      );
      expect(client.requests, isEmpty);
    });
  }
  test('loopback HTTP requires explicit opt in; deadline must be positive', () {
    final client = ScriptedClient();
    final uri = Uri.parse('http://127.0.0.1:8080/catalog');
    expect(
      () => HttpCatalogService(client: client, endpoint: uri),
      throwsArgumentError,
    );
    HttpCatalogService(client: client, endpoint: uri, allowLoopbackHttp: true);
    expect(
      () => HttpCatalogService(
        client: client,
        endpoint: endpoint,
        timeout: Duration.zero,
      ),
      throwsArgumentError,
    );
  });

  for (final code in [204, 301, 304, 400, 401, 404, 429, 500, 503]) {
    test('status $code wins over HTML body; no automatic retry', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response('<html>unusable</html>', code);
      });
      addTearDown(client.close);
      await expectLater(
        service(client).fetch(''),
        throwsA(
          isA<CatalogHttpFailure>().having(
            (error) => error.statusCode,
            'status',
            code,
          ),
        ),
      );
      expect(calls, 1);
    });
  }

  final badBodies = <String, InvalidResponseReason>{
    '': InvalidResponseReason.json,
    '{': InvalidResponseReason.json,
    '[]': InvalidResponseReason.schema,
    '{}': InvalidResponseReason.schema,
    '{"items":null}': InvalidResponseReason.schema,
    '{"items":[null]}': InvalidResponseReason.schema,
    '{"items":[{"id":1}]}': InvalidResponseReason.schema,
    '{"items":[{"id":"x","title":" ","category":"a","description":"b"}]}':
        InvalidResponseReason.schema,
  };
  for (final entry in badBodies.entries) {
    test('rejects malformed response ${entry.key}', () async {
      final client = MockClient(
        (_) async => http.Response(entry.key, 200, headers: jsonHeaders),
      );
      addTearDown(client.close);
      await expectLater(
        service(client).fetch(''),
        throwsA(
          isA<CatalogInvalidResponse>().having(
            (e) => e.reason,
            'reason',
            entry.value,
          ),
        ),
      );
    });
  }
  test('invalid UTF-8 and content type are typed failures', () async {
    for (final response in [
      http.Response.bytes([0xff], 200, headers: jsonHeaders),
      http.Response(fixture, 200, headers: {'content-type': 'text/html'}),
      http.Response(
        fixture,
        200,
        headers: {'content-type': 'application/json; charset=latin1'},
      ),
    ]) {
      final client = MockClient((_) async => response);
      addTearDown(client.close);
      await expectLater(
        service(client).fetch(''),
        throwsA(isA<CatalogInvalidResponse>()),
      );
    }
  });

  test('schema, unique IDs, item and Unicode scalar length limits', () {
    final item = {'id': 'x', 'title': 'T', 'category': 'C', 'description': 'D'};
    for (final field in item.keys) {
      for (final bad in [null, 1, '', ' ']) {
        expect(
          () => parseCatalog({
            'items': [
              {...item, field: bad},
            ],
          }),
          throwsA(isA<CatalogInvalidResponse>()),
        );
      }
    }
    expect(
      () => parseCatalog({
        'items': [item, item],
      }),
      throwsA(isA<CatalogInvalidResponse>()),
    );
    for (final entry in {
      'id': 128,
      'title': 200,
      'category': 200,
      'description': 2000,
    }.entries) {
      expect(
        parseCatalog({
          'items': [
            {...item, entry.key: '😀' * entry.value},
          ],
        }),
        hasLength(1),
      );
      expect(
        () => parseCatalog({
          'items': [
            {...item, entry.key: '😀' * (entry.value + 1)},
          ],
        }),
        throwsA(isA<CatalogInvalidResponse>()),
      );
    }
    final items = List.generate(200, (i) => {...item, 'id': '$i'});
    expect(parseCatalog({'items': items}), hasLength(200));
    expect(
      () => parseCatalog({
        'items': [
          ...items,
          {...item, 'id': '201'},
        ],
      }),
      throwsA(isA<CatalogInvalidResponse>()),
    );
  });

  test(
    'exact byte limit succeeds; exceeding limit aborts while streaming',
    () async {
      final body = '{"items":[]}${' ' * (HttpCatalogService.maxBytes - 12)}';
      final client = MockClient(
        (_) async => http.Response(body, 200, headers: jsonHeaders),
      );
      addTearDown(client.close);
      expect(await service(client).fetch(''), isEmpty);
      final scripted = ScriptedClient();
      var cancelled = false;
      final stream = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );
      final pending = service(scripted).fetch('');
      final check = expectLater(
        pending,
        throwsA(isA<CatalogInvalidResponse>()),
      );
      scripted.responses.single.complete(
        http.StreamedResponse(stream.stream, 200, headers: jsonHeaders),
      );
      stream.add(List.filled(HttpCatalogService.maxBytes + 1, 32));
      await check;
      expect(cancelled, isTrue);
      await scripted.requests.single.abortTrigger;
      await Future<void>.delayed(Duration.zero);
      expect(scripted.aborts, 1);
      await stream.close();
    },
  );

  for (final bodyStarted in [false, true]) {
    test(
      'deadline during ${bodyStarted ? 'body' : 'headers'} cleans up and ignores late completion',
      () {
        fakeAsync((async) {
          final client = ScriptedClient();
          Object? outcome;
          final api = service(client, elapsed: () => async.elapsed);
          api
              .fetch('')
              .then(
                (_) {
                  outcome = 'success';
                },
                onError: (Object e) {
                  outcome = e;
                },
              );
          final stream = StreamController<List<int>>();
          if (bodyStarted)
            client.responses.single.complete(
              http.StreamedResponse(stream.stream, 200, headers: jsonHeaders),
            );
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 8));
          expect(outcome, isA<CatalogTimeout>());
          expect(client.aborts, 1);
          expect(async.pendingTimers, isEmpty);
          if (!bodyStarted) client.succeed();
          stream.addError(http.ClientException('late private details'));
          unawaited(stream.close());
          async.flushMicrotasks();
          expect(outcome, isA<CatalogTimeout>());
          expect(client.closes, 0);
        });
      },
    );
  }

  test(
    'success just before deadline; synchronous parsing budget is checked',
    () {
      fakeAsync((async) {
        final client = ScriptedClient();
        Object? outcome;
        service(
          client,
          elapsed: () => async.elapsed,
        ).fetch('').then((v) => outcome = v);
        async.elapse(const Duration(milliseconds: 7999));
        client.succeed();
        async.flushMicrotasks();
        expect(outcome, isEmpty);
        expect(async.pendingTimers, isEmpty);
      });
      fakeAsync((async) {
        final client = ScriptedClient();
        var elapsed = Duration.zero;
        Object? error;
        service(client, elapsed: () => elapsed).fetch('').catchError((
          Object e,
        ) {
          error = e;
          return <CatalogItem>[];
        });
        elapsed = const Duration(seconds: 8);
        client.succeed();
        async.flushMicrotasks();
        expect(error, isA<CatalogTimeout>());
      });
    },
  );

  test('pre-cancelled signal never sends', () async {
    final source = CatalogCancellationSource()..cancel();
    final client = ScriptedClient();
    await expectLater(
      service(client).fetch('', cancellation: source.signal),
      throwsA(isA<CatalogCancelled>()),
    );
    expect(client.requests, isEmpty);
  });
  for (final bodyStarted in [false, true]) {
    test(
      'cancellation ${bodyStarted ? 'mid-body' : 'before headers'} is idempotent',
      () {
        fakeAsync((async) {
          final source = CatalogCancellationSource();
          final client = ScriptedClient();
          Object? outcome;
          service(client, elapsed: () => async.elapsed)
              .fetch('', cancellation: source.signal)
              .then(
                (_) {
                  outcome = 'success';
                },
                onError: (Object e) {
                  outcome = e;
                },
              );
          var streamCancelled = false;
          final stream = StreamController<List<int>>(
            onCancel: () => streamCancelled = true,
          );
          if (bodyStarted)
            client.responses.single.complete(
              http.StreamedResponse(stream.stream, 200, headers: jsonHeaders),
            );
          async.flushMicrotasks();
          source.cancel();
          source.cancel();
          async.flushMicrotasks();
          expect(outcome, isA<CatalogCancelled>());
          expect(client.aborts, 1);
          if (!bodyStarted)
            client.responses.single.complete(
              http.StreamedResponse(stream.stream, 200, headers: jsonHeaders),
            );
          async.flushMicrotasks();
          expect(streamCancelled, isTrue);
          unawaited(stream.close());
          async.elapse(const Duration(seconds: 9));
          expect(outcome, isA<CatalogCancelled>());
          expect(async.pendingTimers, isEmpty);
          expect(client.closes, 0);
        });
      },
    );
  }

  test(
    'connectivity before headers and mid-body; programming errors not relabelled',
    () async {
      for (final midBody in [false, true]) {
        final client = ScriptedClient();
        final check = expectLater(
          service(client).fetch(''),
          throwsA(isA<CatalogConnectivityFailure>()),
        );
        if (midBody) {
          client.responses.single.complete(
            http.StreamedResponse(
              Stream.error(http.ClientException('secret')),
              200,
              headers: jsonHeaders,
            ),
          );
        } else {
          client.responses.single.completeError(http.ClientException('secret'));
        }
        await check;
      }
      final client = MockClient((_) => throw StateError('bug'));
      addTearDown(client.close);
      await expectLater(service(client).fetch(''), throwsStateError);
    },
  );

  test('shared callers inherit deadline and can retry after timeout', () {
    fakeAsync((async) {
      final client = ScriptedClient();
      final repository = CachedCatalogRepository(
        service(client, elapsed: () => async.elapsed),
      );
      final first = repository.refresh(' Outdoor ');
      Object? failure;
      first.catchError((Object e) {
        failure = e;
        return CatalogSnapshot([], DateTime(2026));
      });
      async.elapse(const Duration(seconds: 7));
      expect(repository.refresh('outdoor'), same(first));
      async.elapse(const Duration(seconds: 1));
      expect(failure, isA<CatalogTimeout>());
      final retry = repository.refresh('outdoor');
      CatalogSnapshot? result;
      retry.then((v) => result = v);
      client.responses.first.completeError(http.ClientException('late'));
      client.succeed(fixture);
      async.flushMicrotasks();
      expect(result!.items.single.id, 'trail');
      expect(repository.cached('outdoor'), same(result));
      repository.dispose();
    });
  });

  test(
    'controller detaches without cancelling another consumer; owner disposal cancels all',
    () async {
      final client = ScriptedClient();
      final repository = CachedCatalogRepository(service(client));
      final a = CatalogController(repository);
      final b = CatalogController(repository);
      final first = a.load('outdoor');
      final second = b.load('OUTDOOR');
      a.dispose();
      expect(client.requests, hasLength(1));
      expect(client.aborts, 0);
      client.succeed(fixture);
      await Future.wait([first, second]);
      expect(b.state.snapshot!.items.single.id, 'trail');
      final pending = repository.refresh('next');
      expect(repository.refresh('next'), same(pending));
      final check = expectLater(pending, throwsA(isA<CatalogCancelled>()));
      final other = repository.refresh('different');
      final otherCheck = expectLater(other, throwsA(isA<CatalogCancelled>()));
      b.dispose();
      repository.dispose();
      repository.dispose();
      await Future.wait([check, otherCheck]);
      await expectLater(
        repository.refresh('later'),
        throwsA(isA<CatalogCancelled>()),
      );
      expect(repository.cached('outdoor'), isNull);
      expect(client.aborts, 2);
      client.responses[1].complete(
        http.StreamedResponse(
          Stream.value(utf8.encode(fixture)),
          200,
          headers: jsonHeaders,
        ),
      );
      client.responses[2].completeError(http.ClientException('late'));
      await Future<void>.delayed(Duration.zero);
      expect(repository.cached('next'), isNull);
      expect(client.closes, 0);
    },
  );

  for (final failure in [
    const CatalogTimeout(),
    const CatalogConnectivityFailure(),
    const CatalogHttpFailure(503),
    const CatalogHttpFailure(400),
    const CatalogInvalidResponse(InvalidResponseReason.schema),
    StateError('SECRET'),
  ]) {
    test(
      'safe presentation and cache retention for ${failure.runtimeType}',
      () async {
        var shouldFail = false;
        final client = MockClient((_) async {
          if (shouldFail) throw failure;
          return http.Response(fixture, 200, headers: jsonHeaders);
        });
        addTearDown(client.close);
        final repo = CachedCatalogRepository(service(client));
        final controller = CatalogController(repo);
        await controller.load('');
        final original = controller.state.snapshot;
        shouldFail = true;
        await controller.load('', force: true);
        expect(controller.state.snapshot, same(original));
        expect(controller.state.error, contains('saved session results'));
        expect(controller.state.error, isNot(contains('SECRET')));
        expect(repo.cached(''), same(original));
        shouldFail = false;
        await controller.load('', force: true);
        expect(controller.state.error, isNull);
        controller.dispose();
        repo.dispose();
      },
    );
  }
  test(
    'demo cancellation clears delay; cancellation is silent in presentation',
    () {
      fakeAsync((async) {
        final repo = CachedCatalogRepository(DemoCatalogService());
        final controller = CatalogController(repo);
        unawaited(controller.load(''));
        repo.dispose();
        async.flushMicrotasks();
        expect(controller.state.loading, isFalse);
        expect(controller.state.error, isNull);
        expect(async.pendingTimers, isEmpty);
        controller.dispose();
      });
    },
  );
}
