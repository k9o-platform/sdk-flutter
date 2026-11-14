import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:k9o_core/k9o_core.dart';
import 'package:test/test.dart';

class Rec {
  final List<http.BaseRequest> reqs = [];
  final List<String> bodies = [];
}

K9oCore mk(
  Rec rec, {
  String baseUrl = 'https://acme.api.k9o.io',
  String? location = 'https://acme.api-de01.k9o.io/',
  int headStatus = 308,
  bool failFirstHead = false,
}) {
  var heads = 0;
  final client = MockClient.streaming((req, body) async {
    rec.reqs.add(req);
    rec.bodies.add(utf8.decode(await body.toBytes()));
    if (req.method == 'HEAD') {
      heads++;
      if (failFirstHead && heads == 1) throw http.ClientException('offline');
      return http.StreamedResponse(
        const Stream.empty(),
        headStatus,
        headers: {if (location != null) 'location': location},
      );
    }
    return http.StreamedResponse(
      Stream.value(
        utf8.encode(
          jsonEncode({
            'data': {
              'modelId': 'm',
              'content': 'x',
              'finishReason': 'stop',
              'usage': {
                'promptTokens': 1,
                'completionTokens': 1,
                'totalTokens': 2,
              },
              'usageType': 'chat',
            },
            'meta': {},
          }),
        ),
      ),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
  return K9oCore(
    baseUrl: baseUrl,
    projectSlug: 'portal',
    accessToken: 'secret-token',
    httpClient: client,
  );
}

int heads(Rec r) => r.reqs.where((q) => q.method == 'HEAD').length;

void main() {
  test(
    'probes credential-free, then sends the call to the regional host',
    () async {
      final rec = Rec();
      await mk(rec).ai.generate('hi');
      expect(rec.reqs[0].method, 'HEAD');
      expect(rec.reqs[0].url.toString(), 'https://acme.api.k9o.io/');
      expect(
        rec.reqs[0].headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('authorization')),
      );
      expect(
        rec.reqs[1].url.toString(),
        'https://acme.api-de01.k9o.io/@portal/ai/generate',
      );
      expect(rec.reqs[1].headers['authorization'], 'Bearer secret-token');
    },
  );

  test('staging address resolves to api-staging-<rgn> and is cached', () async {
    final rec = Rec();
    final c = mk(
      rec,
      baseUrl: 'https://acme.api-staging.k9o.io',
      location: 'https://acme.api-staging-de01.k9o.io/',
    );
    await c.ai.generate('a');
    await c.ai.generate('b');
    expect(heads(rec), 1);
    expect(
      rec.reqs[2].url.toString(),
      'https://acme.api-staging-de01.k9o.io/@portal/ai/generate',
    );
  });

  test('already-regional and non-gateway addresses are not probed', () async {
    for (final base in [
      'https://acme.api-de01.k9o.io',
      'https://api.example.com',
      'http://localhost:6000',
    ]) {
      final rec = Rec();
      await mk(
        rec,
        baseUrl: base,
        location: 'https://evil.example/',
      ).ai.generate('hi');
      expect(heads(rec), 0, reason: base);
      expect(rec.reqs.single.url.toString().startsWith(base), isTrue);
    }
  });

  test('a hostile or missing redirect keeps the configured host', () async {
    for (final loc in [
      'https://evil.example/',
      'https://other.api-de01.k9o.io/',
      'http://acme.api-de01.k9o.io/',
      'https://acme.api-de01.k9o.io:8443/',
      'https://acme.api-de01.evil.example/',
    ]) {
      final rec = Rec();
      await mk(rec, location: loc).ai.generate('hi');
      expect(rec.reqs[1].url.host, 'acme.api.k9o.io', reason: loc);
    }
    final rec = Rec();
    await mk(rec, location: null, headStatus: 200).ai.generate('hi');
    expect(rec.reqs[1].url.host, 'acme.api.k9o.io');
  });

  test('a network failure of the probe is not cached', () async {
    final rec = Rec();
    final c = mk(rec, failFirstHead: true);
    await c.ai.generate('a');
    await c.ai.generate('b');
    expect(heads(rec), 2);
    expect(rec.reqs.last.url.host, 'acme.api-de01.k9o.io');
  });

  test('generate sends usageType on the wire, omitted when null', () async {
    final rec = Rec();
    final c = mk(rec, baseUrl: 'https://acme.api-de01.k9o.io');
    await c.ai.generate('hi', usageType: 'summarise');
    expect(jsonDecode(rec.bodies.last)['usageType'], 'summarise');
    await c.ai.generate('hi');
    expect(jsonDecode(rec.bodies.last).containsKey('usageType'), isFalse);
  });
}
