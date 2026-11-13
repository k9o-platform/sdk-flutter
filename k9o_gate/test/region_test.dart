import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:k9o_gate/k9o_gate.dart';

class Rec {
  final List<http.BaseRequest> reqs = [];
  final List<String> bodies = [];
}

class _Store implements TokenStore {
  String? _t;
  @override
  Future<void> save(String token) async => _t = token;
  @override
  Future<String?> load() async => _t;
  @override
  Future<void> delete() async => _t = null;
}

final String _signedIn = jsonEncode({
  'data': {
    'user': {
      'id': 'eu_1',
      'email': 'alice@example.com',
      'status': 'active',
      'createdAt': '2026-01-01T00:00:00Z',
      'updatedAt': null,
      'lastSigninAt': null,
      'roles': <String>[],
      'groups': <String>[],
    },
    'session': {
      'accessToken': 'a.b.c',
      'refreshToken': 'rt_1',
      'expiresAt': '2099-01-01T00:00:00Z',
    },
  },
  'meta': {},
});

GateClient mk(
  Rec rec, {
  String baseUrl = 'https://acme.api.k9o.io',
  String? location = 'https://acme.api-de01.k9o.io/',
  int headStatus = 308,
  bool failFirstHead = false,
}) {
  var heads = 0;
  final client = MockClient.streaming((req, body) async {
    // Sign-in asks the locate door first; these tests are about the calls around it (locate_test.dart covers the door).
    if (req.url.path.endsWith('/gate/locate')) {
      return http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode({
          'data': {'region': 'de01', 'origin': null},
          'meta': {},
        }))),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
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
      Stream.value(utf8.encode(_signedIn)),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
  return GateClient(
    orgBaseUrl: baseUrl,
    projectSlug: 'portal',
    tokenStore: _Store(),
    httpClient: client,
  );
}

Future<void> signIn(GateClient g) =>
    g.signIn(email: 'alice@example.com', password: 'pw').then((_) {});

int heads(Rec r) => r.reqs.where((q) => q.method == 'HEAD').length;

void main() {
  test('probes credential-free, then signs in on the regional host', () async {
    final rec = Rec();
    await signIn(mk(rec));
    expect(rec.reqs[0].method, 'HEAD');
    expect(rec.reqs[0].url.toString(), 'https://acme.api.k9o.io/');
    expect(rec.bodies[0], isEmpty);
    expect(
      rec.reqs[0].headers.keys.map((k) => k.toLowerCase()),
      everyElement(isNot(anyOf('authorization', 'content-type', 'user-agent'))),
    );
    expect(rec.reqs[0].followRedirects, isFalse);
    expect(
      rec.reqs[1].url.toString(),
      'https://acme.api-de01.k9o.io/@portal/gate/signin',
    );
    expect(jsonDecode(rec.bodies[1]), {
      'email': 'alice@example.com',
      'password': 'pw',
    });
  });

  test('staging address resolves to api-staging-<rgn> and is cached', () async {
    final rec = Rec();
    final g = mk(
      rec,
      baseUrl: 'https://acme.api-staging.k9o.io',
      location: 'https://acme.api-staging-de01.k9o.io/',
    );
    await signIn(g);
    await signIn(g);
    expect(heads(rec), 1);
    expect(
      rec.reqs[2].url.toString(),
      'https://acme.api-staging-de01.k9o.io/@portal/gate/signin',
    );
  });

  test('already-regional and non-gateway addresses are not probed', () async {
    for (final base in [
      'https://acme.api-de01.k9o.io',
      'https://api.example.com',
      'http://localhost:6000',
    ]) {
      final rec = Rec();
      await signIn(mk(rec, baseUrl: base, location: 'https://evil.example/'));
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
      'https://user@acme.api-de01.k9o.io/',
      'https://acme.api-de01.evil.example/',
    ]) {
      final rec = Rec();
      await signIn(mk(rec, location: loc));
      expect(rec.reqs[1].url.host, 'acme.api.k9o.io', reason: loc);
    }
    final rec = Rec();
    await signIn(mk(rec, location: null, headStatus: 200));
    expect(rec.reqs[1].url.host, 'acme.api.k9o.io');
  });

  test('a network failure of the probe is not cached', () async {
    final rec = Rec();
    final g = mk(rec, failFirstHead: true);
    await signIn(g);
    await signIn(g);
    expect(heads(rec), 2);
    expect(rec.reqs[1].url.host, 'acme.api.k9o.io');
    expect(rec.reqs.last.url.host, 'acme.api-de01.k9o.io');
  });
}
