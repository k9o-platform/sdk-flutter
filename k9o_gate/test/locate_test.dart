// The locate door: password sign-in asks the project which region holds the address, and sends the credential only to
// an origin that passes the rule in `locate.dart`.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:k9o_gate/k9o_gate.dart';
import 'package:k9o_gate/src/locate.dart';

const base = 'https://acme.api-de01.k9o.io';

void main() {
  group('chooseLocatedOrigin', () {
    final ok = <String, List<Object>>{
      'a sibling region of the same org, family and apex': [
        'https://acme.api-us01.k9o.io',
        {'region': 'us01', 'origin': 'https://acme.api-us01.k9o.io'},
      ],
      "the base's own region": [
        base,
        {'region': 'de01', 'origin': base},
      ],
      'a trailing slash': [
        'https://acme.api-us01.k9o.io',
        {'region': 'us01', 'origin': 'https://acme.api-us01.k9o.io/'},
      ],
    };
    ok.forEach((name, c) {
      test('uses $name', () => expect(chooseLocatedOrigin(base, c[1]), c[0]));
    });

    final refused = <String, Object?>{
      'null origin (single host, self-hosted)': {'region': 'de01', 'origin': null},
      'a missing answer': null,
      'http': {'region': 'us01', 'origin': 'http://acme.api-us01.k9o.io'},
      'userinfo': {'region': 'us01', 'origin': 'https://u:p@acme.api-us01.k9o.io'},
      'a port': {'region': 'us01', 'origin': 'https://acme.api-us01.k9o.io:8443'},
      'a path': {'region': 'us01', 'origin': 'https://acme.api-us01.k9o.io/x'},
      'a query': {'region': 'us01', 'origin': 'https://acme.api-us01.k9o.io/?a=1'},
      'a fragment': {'region': 'us01', 'origin': 'https://acme.api-us01.k9o.io/#x'},
      'another org': {'region': 'us01', 'origin': 'https://evil.api-us01.k9o.io'},
      'another apex': {'region': 'us01', 'origin': 'https://acme.api-us01.evil.io'},
      'another family': {'region': 'us01', 'origin': 'https://acme.api-staging-us01.k9o.io'},
      'a code that differs from region': {'region': 'us01', 'origin': 'https://acme.api-fr01.k9o.io'},
      'a region that is not a code': {'region': 'usa', 'origin': 'https://acme.api-usa.k9o.io'},
      'a host with no region': {'region': 'us01', 'origin': 'https://acme.api.k9o.io'},
      'a region as a subdomain': {'region': 'us01', 'origin': 'https://us01.acme.api-de01.k9o.io'},
      'a look-alike apex': {'region': 'us01', 'origin': 'https://acme.api-us01.k9o.io.evil.io'},
      'an origin that is not a string': {'region': 'us01', 'origin': 5},
    };
    refused.forEach((name, answer) {
      test('falls back to the base for $name', () => expect(chooseLocatedOrigin(base, answer), base));
    });

    test('allows http only when the base is http on loopback, and then only the same host', () {
      expect(
        chooseLocatedOrigin('http://localhost:8080', {'region': 'de01', 'origin': 'http://localhost:8080'}),
        'http://localhost:8080',
      );
      expect(
        chooseLocatedOrigin('http://localhost:8080', {'region': 'de01', 'origin': 'http://evil.localhost:8080'}),
        'http://localhost:8080',
      );
      expect(
        chooseLocatedOrigin('https://localhost', {'region': 'de01', 'origin': 'http://localhost'}),
        'https://localhost',
      );
      expect(
        chooseLocatedOrigin('http://localhost', {'region': 'de01', 'origin': 'http://localhost'}),
        'http://localhost',
      );
    });

    test('uses the base when the base is not a gateway host shape', () {
      expect(
        chooseLocatedOrigin('https://gw.internal.example', {'region': 'us01', 'origin': 'https://gw-us01.internal.example'}),
        'https://gw.internal.example',
      );
    });
  });

  group('password sign-in through the locate door', () {
    final session = {'accessToken': 'a', 'refreshToken': 'r-1', 'expiresAt': '2099-01-01T00:00:00Z'};
    final user = {
      'id': 'eu_1',
      'email': 'a@b.co',
      'status': 'active',
      'createdAt': '2026-01-01T00:00:00Z',
      'updatedAt': null,
      'lastSigninAt': null,
      'roles': <String>[],
      'groups': <String>[],
    };
    http.Response json(int status, Object body) =>
        http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

    ({List<http.Request> seen, GateClient client}) harness(http.Response Function(http.Request) answer) {
      final seen = <http.Request>[];
      final client = MockClient((req) async {
        seen.add(req);
        return answer(req);
      });
      final gate = GateClient(
        orgBaseUrl: base,
        projectSlug: 'portal',
        tokenStore: _Store(),
        httpClient: client,
      );
      return (seen: seen, client: gate);
    }

    bool isDoor(http.Request r) => r.url.path.endsWith('/gate/locate');
    http.Response located(String region, String? origin) =>
        json(200, {'data': {'region': region, 'origin': origin}, 'meta': {}});
    http.Response signedIn() => json(200, {'data': {'user': user, 'session': session}, 'meta': {}});

    test('sends only the email to the door, then the password to the located origin', () async {
      final h = harness((r) => isDoor(r) ? located('us01', 'https://acme.api-us01.k9o.io') : signedIn());
      await h.client.signIn(email: 'a@b.co', password: 'pw');
      expect(h.seen.map((r) => r.url.toString()), [
        '$base/@portal/gate/locate',
        'https://acme.api-us01.k9o.io/@portal/gate/signin',
      ]);
      expect(jsonDecode(h.seen[0].body), {'email': 'a@b.co'});
      expect(h.seen[0].headers.keys.map((k) => k.toLowerCase()), isNot(contains('authorization')));
    });

    test('never sends the password to an origin that fails the rule', () async {
      final h = harness((r) => isDoor(r) ? located('us01', 'https://evil.example') : signedIn());
      await h.client.signIn(email: 'a@b.co', password: 'pw');
      expect(h.seen[1].url.toString(), '$base/@portal/gate/signin');
      expect(h.seen.any((r) => r.url.host.contains('evil.example')), isFalse);
    });

    test('uses the base when the door answers origin null', () async {
      final h = harness((r) => isDoor(r) ? located('de01', null) : signedIn());
      await h.client.signIn(email: 'a@b.co', password: 'pw');
      expect(h.seen[1].url.toString(), '$base/@portal/gate/signin');
    });

    test('uses the base when the door answers 2xx with a malformed body', () async {
      for (final bad in ['not-json', '{}', 'null']) {
        final h = harness((r) => isDoor(r) ? http.Response(bad, 200) : signedIn());
        await h.client.signIn(email: 'a@b.co', password: 'pw');
        expect(h.seen.map((r) => r.url.toString()), ['$base/@portal/gate/locate', '$base/@portal/gate/signin']);
      }
    });

    test('sends nothing to sign-in when the door is down (503) or rate-limited (429), and raises the door\'s error', () async {
      for (final c in [(503, 'K9O_GATE_REGION_UNAVAILABLE'), (429, 'K9O_RATE_LIMITED')]) {
        final h = harness((_) => json(c.$1, {'code': c.$2, 'message': 'x', 'context': {}, 'recommendation': null}));
        await expectLater(
          h.client.signIn(email: 'a@b.co', password: 'pw'),
          throwsA(c.$1 == 503
              ? isA<GateError>().having((e) => e.toString(), 'toString', startsWith('GateError.regionUnavailable'))
              : isA<GateError>().having((e) => e.toString(), 'toString', startsWith('GateError.rateLimited'))),
        );
        expect(h.seen, hasLength(1));
      }
    });

    test('raises any other door failure as the usual error, with no retry', () async {
      final h = harness((_) => json(500, {'code': 'K9O_INTERNAL_ERROR', 'message': 'x', 'context': {}, 'recommendation': null}));
      await expectLater(
        h.client.signIn(email: 'a@b.co', password: 'pw'),
        throwsA(isA<GateError>().having((e) => e.toString(), 'toString', startsWith('GateError.unknown'))),
      );
      expect(h.seen, hasLength(1));
    });

    test('uses the base when the door answers 404', () async {
      for (final body in [
        {'code': 'K9O_NOT_FOUND', 'message': 'x', 'context': {}, 'recommendation': null},
        <String, Object>{},
      ]) {
        final h = harness((r) => isDoor(r) ? json(404, body) : signedIn());
        await h.client.signIn(email: 'a@b.co', password: 'pw');
        expect(h.seen.map((r) => r.url.toString()), ['$base/@portal/gate/locate', '$base/@portal/gate/signin']);
      }
    });

    test('still raises when the door answers 404 and then sign-in answers 404', () async {
      final h = harness((r) => json(404, {'code': 'K9O_NOT_FOUND', 'message': 'x', 'context': {}, 'recommendation': null}));
      await expectLater(
        h.client.signIn(email: 'a@b.co', password: 'pw'),
        throwsA(isA<GateError>().having((e) => e.toString(), 'toString', startsWith('GateError.unknown: HTTP 404'))),
      );
      expect(h.seen.map((r) => r.url.toString()), ['$base/@portal/gate/locate', '$base/@portal/gate/signin']);
    });

    test('does not cache the located origin: the next sign-in asks again', () async {
      var n = 0;
      final h = harness((r) {
        if (!isDoor(r)) return signedIn();
        final region = n++ == 0 ? 'us01' : 'fr01';
        return located(region, 'https://acme.api-$region.k9o.io');
      });
      await h.client.signIn(email: 'a@b.co', password: 'pw');
      await h.client.signIn(email: 'a@b.co', password: 'pw');
      expect(h.seen.where(isDoor), hasLength(2));
      expect(h.seen.map((r) => r.url.toString()).where((u) => u.endsWith('/signin')), [
        'https://acme.api-us01.k9o.io/@portal/gate/signin',
        'https://acme.api-fr01.k9o.io/@portal/gate/signin',
      ]);
    });

    test('sends refresh and sign-out to the origin that issued the session', () async {
      final h = harness((r) {
        if (isDoor(r)) return located('us01', 'https://acme.api-us01.k9o.io');
        if (r.url.path.endsWith('/signin')) return signedIn();
        return json(200, {'data': {'revoked': true, 'accessToken': 'n', 'refreshToken': 'r-2', 'expiresAt': '2099-01-01T00:00:00Z'}, 'meta': {}});
      });
      await h.client.signIn(email: 'a@b.co', password: 'pw');
      await h.client.refreshToken(refreshToken: 'r-1');
      // The refresh answered the next token; the session's origin follows it.
      await h.client.signOut(refreshToken: 'r-2');
      final urls = h.seen.map((r) => r.url.toString()).toList();
      expect(urls, contains('https://acme.api-us01.k9o.io/@portal/gate/refresh'));
      expect(urls, contains('https://acme.api-us01.k9o.io/@portal/gate/signout'));
      await h.client.refreshToken(refreshToken: 'r-2');
      expect(h.seen.last.url.toString(), '$base/@portal/gate/refresh');
    });

    test('keeps at most 64 session hints, dropping the oldest', () async {
      var n = 0;
      final h = harness((r) {
        if (isDoor(r)) return located('us01', 'https://acme.api-us01.k9o.io');
        if (r.url.path.endsWith('/signin')) {
          return json(200, {
            'data': {'user': user, 'session': {...session, 'refreshToken': 'cap-${n++}'}},
            'meta': {},
          });
        }
        return json(200, {'data': {'accessToken': 'n', 'refreshToken': 'n-next', 'expiresAt': '2099-01-01T00:00:00Z'}, 'meta': {}});
      });
      for (var i = 0; i < 65; i++) {
        await h.client.signIn(email: 'a@b.co', password: 'pw');
      }
      await h.client.refreshToken(refreshToken: 'cap-0');
      expect(h.seen.last.url.toString(), '$base/@portal/gate/refresh');
      await h.client.refreshToken(refreshToken: 'cap-64');
      expect(h.seen.last.url.toString(), 'https://acme.api-us01.k9o.io/@portal/gate/refresh');
    });
  });
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
