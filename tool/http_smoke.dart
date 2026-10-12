// Console output is the smoke probe result, not application logging.
// ignore_for_file: avoid_print
// Run against tool/fixture_server.py on VM or compile to JavaScript for browser.
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:pocket_catalog/catalog.dart';
import 'package:pocket_catalog/catalog_http.dart';

Future<void> main() async {
  final client = http.Client();
  final base = Uri.parse(
    const String.fromEnvironment(
      'CATALOG_URL',
      defaultValue: 'http://127.0.0.1:8767/catalog',
    ),
  );
  HttpCatalogService adapter(String path, {Duration? timeout}) =>
      HttpCatalogService(
        client: client,
        endpoint: base.replace(path: path),
        allowLoopbackHttp: true,
        timeout: timeout ?? const Duration(seconds: 8),
      );
  Future<void> fails(
    String name,
    Future<Object?> pending,
    bool Function(Object) matches,
  ) async {
    try {
      await pending;
      throw StateError('$name unexpectedly succeeded');
    } catch (error) {
      if (!matches(error)) rethrow;
      print('PASS $name');
    }
  }

  try {
    final items = await adapter('/catalog').fetch('outdoor');
    if (items.length != 1 || items.single.id != 'trail')
      throw StateError('fixture mismatch');
    print('PASS real HTTP success and query');
    await fails(
      'HTTP status',
      adapter('/status').fetch(''),
      (e) => e is CatalogHttpFailure && e.statusCode == 503,
    );
    await fails(
      'invalid JSON',
      adapter('/malformed').fetch(''),
      (e) => e is CatalogInvalidResponse,
    );
    for (final path in ['/slow-headers', '/slow-body']) {
      await fails(
        'timeout $path',
        adapter(path, timeout: const Duration(milliseconds: 150)).fetch(''),
        (e) => e is CatalogTimeout,
      );
      final source = CatalogCancellationSource();
      final pending = adapter(path).fetch('', cancellation: source.signal);
      final timer = Timer(const Duration(milliseconds: 150), source.cancel);
      try {
        await fails(
          'cancellation $path',
          pending,
          (e) => e is CatalogCancelled,
        );
      } finally {
        timer.cancel();
      }
    }
    // Redirect refusal differs by platform: native exposes 302, browser fetch errors.
    await fails(
      'redirect refused',
      adapter('/redirect').fetch(''),
      (e) =>
          (e is CatalogHttpFailure && e.statusCode == 302) ||
          e is CatalogConnectivityFailure,
    );
    if ((await adapter('/catalog').fetch('')).length != 1)
      throw StateError('client not reusable');
    print('PASS borrowed client still reusable');
    print('HTTP SMOKE PASSED');
  } finally {
    client.close();
  }
}
