import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:k9o_core/k9o_core.dart';
import 'package:test/test.dart';

String urlOf({String? baseUrl, String? orgSlug}) =>
    K9oCore(baseUrl: baseUrl, orgSlug: orgSlug, projectSlug: 'p').baseUrl;

void main() {
  group('orgSlug', () {
    test('a full org URL is used as given, with or without a slug', () {
      expect(urlOf(baseUrl: 'https://acme.api.k9o.io'), 'https://acme.api.k9o.io');
      expect(urlOf(baseUrl: 'https://acme.api.k9o.io/'), 'https://acme.api.k9o.io');
      expect(urlOf(baseUrl: 'https://acme.api.k9o.io', orgSlug: 'other'), 'https://acme.api.k9o.io');
    });

    test('a custom domain, localhost and an IP are used as given', () {
      for (final u in ['https://auth.example.com', 'http://localhost:3000', 'http://127.0.0.1:8080']) {
        expect(urlOf(baseUrl: u), u);
        expect(urlOf(baseUrl: u, orgSlug: 'acme'), u);
      }
    });

    test('the platform host plus a slug composes the org host', () {
      expect(urlOf(baseUrl: 'https://api.k9o.io', orgSlug: 'acme'), 'https://acme.api.k9o.io');
      expect(urlOf(baseUrl: 'https://api.k9o.io:8443', orgSlug: 'acme'), 'https://acme.api.k9o.io:8443');
      expect(urlOf(baseUrl: 'https://api.corp.internal', orgSlug: 'acme'), 'https://acme.api.corp.internal');
    });

    test('a regional platform host is used as given', () {
      expect(urlOf(baseUrl: 'https://api-de01.k9o.io', orgSlug: 'acme'), 'https://api-de01.k9o.io');
    });

    test('a slug alone gives https://<slug>.api.k9o.io', () {
      expect(urlOf(orgSlug: 'acme'), 'https://acme.api.k9o.io');
    });

    test('a bad slug raises K9O_INVALID_FIELD_VALUE', () {
      for (final s in ['Acme', 'acme-', 'a', 'a' * 64]) {
        expect(
          () => urlOf(orgSlug: s),
          throwsA(isA<KError>()
              .having((e) => e.code, 'code', 'K9O_INVALID_FIELD_VALUE')
              .having((e) => e.context, 'context', {'field': 'orgSlug', 'slug': s})),
          reason: s,
        );
        expect(
          () => urlOf(baseUrl: 'https://api.k9o.io', orgSlug: s),
          throwsA(isA<KError>()
              .having((e) => e.code, 'code', 'K9O_INVALID_FIELD_VALUE')
              .having((e) => e.context, 'context', {'field': 'orgSlug', 'slug': s})),
          reason: s,
        );
      }
    });

    test('neither raises K9O_INVALID_BASE_URL, never the bare apex', () {
      expect(
        () => urlOf(),
        throwsA(isA<KError>()
            .having((e) => e.code, 'code', 'K9O_INVALID_BASE_URL')
            .having((e) => e.context, 'context', {'field': 'baseUrl'})),
      );
    });

    test('a request goes to the composed host', () async {
      final seen = <Uri>[];
      final client = MockClient.streaming((req, body) async {
        seen.add(req.url);
        return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode({'data': <String, dynamic>{}, 'meta': {}}))),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final core = K9oCore(orgSlug: 'acme', projectSlug: 'portal', accessToken: 't', httpClient: client);
      try {
        await core.query('select 1');
      } catch (_) {}
      expect(seen, isNotEmpty);
      expect(seen.every((u) => u.host == 'acme.api.k9o.io'), isTrue, reason: '$seen');
    });
  });
}
