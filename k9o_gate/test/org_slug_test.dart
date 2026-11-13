import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:k9o_gate/k9o_gate.dart';

class _Store implements TokenStore {
  @override
  Future<void> save(String token) async {}
  @override
  Future<String?> load() async => null;
  @override
  Future<void> delete() async {}
}

/// The origin (scheme://host[:port]) the first request goes to.
Future<String> originOf({String? orgBaseUrl, String? orgSlug}) async {
  final seen = <Uri>[];
  final client = MockClient((req) async {
    seen.add(req.url);
    return http.Response('{}', 200, headers: {'content-type': 'application/json'});
  });
  final gate = GateClient(
    orgBaseUrl: orgBaseUrl,
    orgSlug: orgSlug,
    projectSlug: 'tasks-app',
    tokenStore: _Store(),
    httpClient: client,
  );
  try {
    await gate.refreshToken(refreshToken: 'rt_1');
  } catch (_) {}
  expect(seen, isNotEmpty);
  return seen.first.origin;
}

void main() {
  group('orgSlug', () {
    test('a full org URL is used as given, with or without a slug', () async {
      expect(await originOf(orgBaseUrl: 'https://acme.api.k9o.io'), 'https://acme.api.k9o.io');
      expect(await originOf(orgBaseUrl: 'https://acme.api.k9o.io/'), 'https://acme.api.k9o.io');
      expect(await originOf(orgBaseUrl: 'https://acme.api.k9o.io', orgSlug: 'other'), 'https://acme.api.k9o.io');
    });

    test('a custom domain, localhost and an IP are used as given', () async {
      for (final u in ['https://auth.example.com', 'http://localhost:3000', 'http://127.0.0.1:8080']) {
        expect(await originOf(orgBaseUrl: u), u);
        expect(await originOf(orgBaseUrl: u, orgSlug: 'acme'), u);
      }
    });

    test('the platform host plus a slug composes the org host', () async {
      expect(await originOf(orgBaseUrl: 'https://api.k9o.io', orgSlug: 'acme'), 'https://acme.api.k9o.io');
      expect(await originOf(orgBaseUrl: 'https://api.k9o.io:8443', orgSlug: 'acme'), 'https://acme.api.k9o.io:8443');
    });

    test('a regional platform host is used as given', () async {
      expect(await originOf(orgBaseUrl: 'https://api-de01.k9o.io', orgSlug: 'acme'), 'https://api-de01.k9o.io');
    });

    test('a slug alone gives https://<slug>.api.k9o.io', () async {
      expect(await originOf(orgSlug: 'acme'), 'https://acme.api.k9o.io');
    });

    Matcher configError(String code, Map<String, Object?> context) => throwsA(
          isA<K9OGateConfigError>()
              .having((e) => e.code, 'code', code)
              .having((e) => e.context, 'context', context)
              .having((e) => e, 'is ArgumentError', isA<ArgumentError>()),
        );

    test('a bad slug raises K9O_INVALID_FIELD_VALUE with the field and slug', () {
      for (final s in ['Acme', 'acme-', 'a', 'a' * 64]) {
        final ctx = {'field': 'orgSlug', 'slug': s};
        expect(
          () => GateClient(orgSlug: s, projectSlug: 'tasks-app', tokenStore: _Store()),
          configError('K9O_INVALID_FIELD_VALUE', ctx),
          reason: s,
        );
        expect(
          () => GateClient(orgBaseUrl: 'https://api.k9o.io', orgSlug: s, projectSlug: 'tasks-app', tokenStore: _Store()),
          configError('K9O_INVALID_FIELD_VALUE', ctx),
          reason: s,
        );
      }
    });

    test('neither raises K9O_INVALID_BASE_URL with field baseUrl', () {
      expect(
        () => GateClient(projectSlug: 'tasks-app', tokenStore: _Store()),
        configError('K9O_INVALID_BASE_URL', {'field': 'baseUrl'}),
      );
    });
  });
}
