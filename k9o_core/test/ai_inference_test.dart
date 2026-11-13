import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:k9o_core/k9o_core.dart';
import 'package:test/test.dart';

const ok = {
  'data': {
    'modelId': 'llama-3.1-8b',
    'content': 'Hello there',
    'finishReason': 'stop',
    'usage': {'promptTokens': 3, 'completionTokens': 2, 'totalTokens': 5},
    'usageType': 'chat',
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
}) {
  final client = MockClient((r) async {
    cap.req = r;
    cap.count++;
    return http.Response(
      jsonEncode(body),
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
  group('ai.generate', () {
    test(
      'POSTs flat body to the generate path and parses the response',
      () async {
        final cap = Cap();
        final r = await mk(cap).ai.generate(
          'hi',
          model: 'llama-3.1-8b',
          maxTokens: 10,
          temperature: 0.2,
        );
        expect(cap.req!.method, 'POST');
        expect(
          cap.req!.url.toString(),
          'https://acme.api.k9o.io/@member-portal/ai/generate',
        );
        expect(cap.req!.headers['authorization'], 'Bearer tok_abc');
        expect(jsonDecode(cap.req!.body), {
          'prompt': 'hi',
          'model': 'llama-3.1-8b',
          'maxTokens': 10,
          'temperature': 0.2,
        });
        expect(r.data.modelId, 'llama-3.1-8b');
        expect(r.data.content, 'Hello there');
        expect(r.data.finishReason, 'stop');
        expect(r.data.usage.totalTokens, 5);
        expect(r.data.usage.promptTokens, 3);
      },
    );

    test('omits optional params when not given', () async {
      final cap = Cap();
      await mk(cap).ai.generate('p');
      expect(jsonDecode(cap.req!.body), {'prompt': 'p'});
    });

    test('missing projectSlug refused before any request', () async {
      final cap = Cap();
      await expectLater(
        mk(cap, slug: null).ai.generate('p'),
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

    test('501 not implemented surfaces as KError without the prompt', () async {
      final cap = Cap();
      const secret = 'the-secret-prompt';
      final err = {
        'code': 'K9O_NOT_IMPLEMENTED',
        'message': 'external provider not built',
        'context': {},
        'recommendation': null,
      };
      try {
        await mk(
          cap,
          body: err,
          status: 501,
        ).ai.generate(secret, model: 'gpt-4o');
        fail('expected KError');
      } on KError catch (e) {
        expect(e.code, 'K9O_NOT_IMPLEMENTED');
        expect(e.status, 501);
        expect(e.toString(), isNot(contains(secret)));
      }
    });

    test(
      '400 no default model surfaces as KError and sends no model',
      () async {
        final cap = Cap();
        final err = {
          'code': 'K9O_INVALID_FIELD_VALUE',
          'message': 'Name a model: this org has no default LLM',
          'context': {'field': 'model'},
          'recommendation': null,
        };
        try {
          await mk(cap, body: err, status: 400).ai.generate('hi');
          fail('expected KError');
        } on KError catch (e) {
          expect(e.code, 'K9O_INVALID_FIELD_VALUE');
          expect(e.status, 400);
        }
        expect(jsonDecode(cap.req!.body), {'prompt': 'hi'});
      },
    );
  });
}
