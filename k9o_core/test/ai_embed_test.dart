import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:k9o_core/k9o_core.dart';
import 'package:test/test.dart';

const ok = {
  'data': {
    'embeddings': [
      [0.1, 0.2],
    ],
    'model': 'nomic-embed-text-v1.5',
    'dimensions': 2,
  },
  'meta': {},
};

class Cap {
  http.Request? req;
  int count = 0;
}

K9oCore mk(
  Cap cap, {
  Object body = ok,
  int status = 200,
  String? slug = 'member-portal',
  bool fail = false,
  String? raw,
}) {
  final client = MockClient((r) async {
    cap.req = r;
    cap.count++;
    if (fail) throw http.ClientException('connection refused to secret-host');
    return http.Response(
      raw ?? jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );
  });
  return K9oCore(
    baseUrl: 'https://acme.api.k9o.io/',
    projectSlug: slug,
    accessToken: 'tok_abc',
    httpClient: client,
  );
}

void main() {
  group('ai.embed', () {
    test(
      'POSTs /@slug/ai/embeddings with bearer and returns vectors',
      () async {
        final cap = Cap();
        final r = await mk(cap).ai.embed(input: 'hello');
        expect(cap.req!.method, 'POST');
        expect(
          cap.req!.url.toString(),
          'https://acme.api.k9o.io/@member-portal/ai/embeddings',
        );
        expect(cap.req!.headers['authorization'], 'Bearer tok_abc');
        expect(jsonDecode(cap.req!.body), {'input': 'hello'});
        expect(r.data.embeddings, [
          [0.1, 0.2],
        ]);
        expect(r.data.dimensions, 2);
        expect(r.meta, isEmpty);
      },
    );

    test('sends list input and model as given', () async {
      final cap = Cap();
      await mk(cap).ai.embed(
        model: 'nomic-embed-text-v1.5',
        input: ['search_document: a', 'search_document: b'],
      );
      expect(jsonDecode(cap.req!.body), {
        'model': 'nomic-embed-text-v1.5',
        'input': ['search_document: a', 'search_document: b'],
      });
    });

    test('omits model when not given', () async {
      final cap = Cap();
      await mk(cap).ai.embed(input: ['x']);
      expect((jsonDecode(cap.req!.body) as Map).containsKey('model'), isFalse);
    });

    test('missing projectSlug refused before any request', () async {
      final cap = Cap();
      await expectLater(
        mk(cap, slug: null).ai.embed(input: 'x'),
        throwsA(
          isA<KError>().having(
            (e) => e.code,
            'code',
            'K9O_MISSING_PROJECT_CONTEXT',
          ),
        ),
      );
      expect(cap.count, 0);
    });

    test('4xx flat KError surfaces without the input text', () async {
      final cap = Cap();
      const secret = 'the-secret-document-body';
      final err = {
        'code': 'K9O_MODEL_NOT_DECLARED',
        'message': 'model is not a declared embedding model',
        'context': {
          'declared': ['nomic-embed-text-v1.5'],
        },
        'recommendation': null,
      };
      try {
        await mk(
          cap,
          body: err,
          status: 400,
        ).ai.embed(model: 'other', input: secret);
        fail('expected KError');
      } on KError catch (e) {
        expect(e.code, 'K9O_MODEL_NOT_DECLARED');
        expect(e.status, 400);
        expect(e.toString(), isNot(contains(secret)));
        expect(e.message, isNot(contains(secret)));
      }
    });

    test('network failure maps to K9O_UPSTREAM_UNAVAILABLE', () async {
      final cap = Cap();
      await expectLater(
        mk(cap, fail: true).ai.embed(input: 'x'),
        throwsA(
          isA<KError>().having(
            (e) => e.code,
            'code',
            'K9O_UPSTREAM_UNAVAILABLE',
          ),
        ),
      );
    });

    test('non-JSON error body maps to K9O_INTERNAL_ERROR', () async {
      final cap = Cap();
      await expectLater(
        mk(
          cap,
          raw: '<html>bad gateway</html>',
          status: 502,
        ).ai.embed(input: 'x'),
        throwsA(
          isA<KError>().having((e) => e.code, 'code', 'K9O_INTERNAL_ERROR'),
        ),
      );
    });
  });
}
