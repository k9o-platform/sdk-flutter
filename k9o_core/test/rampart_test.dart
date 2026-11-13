import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:k9o_core/k9o_core.dart';
import 'package:k9o_core/src/sha256.dart';
import 'package:test/test.dart';

import 'ed_sign.dart';
import 'helpers.dart';

const projectId = 'proj_01hxyz';
const issuer = 'https://api.k9o.io/rampart';
final now = DateTime.utc(2026, 10, 27, 12);
final nowS = now.millisecondsSinceEpoch ~/ 1000;
final input = <String, dynamic>{
  'text': 'hello',
  'n': 1,
  'nested': {'b': [1, 2], 'a': null},
};

String b64u(List<int> b) => base64Url.encode(b).replaceAll('=', '');
String b64uJson(Object o) => b64u(utf8.encode(jsonEncode(o)));

class Signer {
  final String kid;
  final List<int> seed;
  Signer(this.kid, int n) : seed = List<int>.generate(32, (i) => (i * 11 + n) & 0xff);
  RampartJwk get jwk => RampartJwk(
    kid: kid,
    kty: 'OKP',
    crv: 'Ed25519',
    x: b64u(edPublicKey(seed)),
    raw: {'kty': 'OKP', 'crv': 'Ed25519', 'x': b64u(edPublicKey(seed)), 'kid': kid},
  );
  Map<String, dynamic> get jwkJson => {...jwk.raw, 'alg': 'EdDSA', 'use': 'sig'};
}

String sign(
  Signer s, {
  Map<String, dynamic> header = const {},
  Map<String, dynamic> claims = const {},
  Object? over,
}) {
  final h = <String, dynamic>{
    'alg': 'EdDSA', 'kid': s.kid, 'typ': 'k9o.rampart.classify.v1', ...header, //
  };
  final c = <String, dynamic>{
    'iss': issuer,
    'iat': nowS,
    'exp': nowS + 3600,
    'input_sha256': sha256Hex(canonicalize(over ?? input)),
    'classification': 'suspicious',
    'risk_bp': 6200,
    'confidence_bp': 8100,
    'categories': ['prompt_injection'],
    'project_id': projectId,
    'calibration_version': 'cal-1',
    ...claims,
  };
  h.removeWhere((_, v) => v == null);
  c.removeWhere((_, v) => v == null);
  final signingInput = '${b64uJson(h)}.${b64uJson(c)}';
  return '$signingInput.${b64u(edSign(s.seed, utf8.encode(signingInput)))}';
}

http.StreamedResponse resp(int status, Object body) => http.StreamedResponse(
  Stream.value(utf8.encode(jsonEncode(body))),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> feed(List<Signer> keys) => {
  'keys': keys.map((k) => k.jwkJson).toList(),
  'issuer': issuer,
  'meta': {'context': {'requestId': 'r'}},
};

int jwksFetches(Cap cap) =>
    cap.reqs.where((r) => r.url.path == '/rampart/jwks').length;

Future<RampartReceiptReason> reasonOf(Future<Object?> f) async {
  try {
    await f;
  } on RampartReceiptError catch (e) {
    return e.reason;
  }
  throw StateError('expected a refusal');
}

const verdictJson = {
  'classification': 'suspicious',
  'riskScore': 6200,
  'confidence': 8100,
  'categories': ['prompt_injection'],
  'calibrationVersion': 'cal-1',
  'classificationReceipt': 'a.b.c',
};

void main() {
  group('rampart.classify', () {
    test('posts to /@<slug>/rampart/classify and returns the verdict as received', () async {
      final cap = Cap();
      final core = mk(cap, data: {...verdictJson, 'projectId': projectId});
      final r = await core.rampart.classify({'text': 'hi'}, label: 'chat');
      expect(cap.plain.method, 'POST');
      expect(cap.plain.url.path, '/@member-portal/rampart/classify');
      expect(cap.plain.headers['authorization'], 'Bearer tok_abc');
      expect(cap.json, {'input': {'text': 'hi'}, 'label': 'chat'});
      expect(r.data.classification, 'suspicious');
      expect(r.data.riskScore, 6200);
      expect(r.data.confidence, 8100);
      expect(r.data.categories, ['prompt_injection']);
      expect(r.data.calibrationVersion, 'cal-1');
      expect(r.data.classificationReceipt, 'a.b.c');
      expect(r.data.projectId, projectId);
    });

    test('omits label when none is given, and projectId may be absent', () async {
      final cap = Cap();
      final core = mk(cap, data: verdictJson);
      final r = await core.rampart.classify({'text': 'hi'});
      expect(cap.json, {'input': {'text': 'hi'}});
      expect(r.data.projectId, isNull);
    });

    test('surfaces the 503 as a KError with the gateway code and no verdict', () async {
      final cap = Cap();
      final core = mk(
        cap,
        status: 503,
        errorBody: {
          'code': 'K9O_RAMPART_CLASSIFIER_UNAVAILABLE',
          'message': 'down',
          'context': {'cause': 'no_endpoint_configured'},
          'recommendation': null,
        },
      );
      final e = await kerrorOf(() => core.rampart.classify({'text': 'hi'}));
      expect(e.code, 'K9O_RAMPART_CLASSIFIER_UNAVAILABLE');
      expect(e.status, 503);
    });

    test('surfaces the 413 as a typed KError with the code and no verdict', () async {
      final cap = Cap();
      final core = mk(
        cap,
        status: 413,
        errorBody: {
          'code': 'K9O_RAMPART_INPUT_TOO_LONG',
          'message': 'too long',
          'context': {'reason': 'rampart_input_too_long'},
          'recommendation': null,
        },
      );
      final e = await kerrorOf(() => core.rampart.classify({'text': 'hi'}));
      expect(e.code, 'K9O_RAMPART_INPUT_TOO_LONG');
      expect(e.status, 413);
      expect(e.context['reason'], 'rampart_input_too_long');
    });

    test('checks its arguments before sending', () async {
      final cap = Cap();
      final core = mk(cap, data: verdictJson);
      await expectLater(core.rampart.classify({}, label: ''), throwsArgumentError);
      await expectLater(core.rampart.classify({}, label: 'x' * 129), throwsArgumentError);
      expect(cap.count, 0);
      final none = mk(Cap(), data: verdictJson, slug: null);
      final e = await kerrorOf(() => none.rampart.classify({}));
      expect(e.code, 'K9O_MISSING_PROJECT_CONTEXT');
    });

    test('does not pre-validate the input; the server decides', () async {
      final cap = Cap();
      final core = mk(
        cap,
        status: 400,
        errorBody: {'code': 'K9O_VALIDATION_FAILED', 'message': 'bad input', 'context': {}},
      );
      await kerrorOf(() => core.rampart.classify({'x': 1.5}));
      expect(cap.count, 1);
    });

    test('an answer without the verdict fields is an internal error', () async {
      final core = mk(Cap(), data: {'classification': 'clear'});
      final e = await kerrorOf(() => core.rampart.classify({}));
      expect(e.code, 'K9O_INTERNAL_ERROR');
    });
  });

  group('rampart.jwks', () {
    test('reads GET /rampart/jwks with no project prefix and no credentials', () async {
      final s = Signer('k1', 1);
      final cap = Cap();
      final core = mk(cap, handler: (req, n) async => resp(200, feed([s])));
      final r = await core.rampart.jwks();
      expect(cap.plain.method, 'GET');
      expect(cap.plain.url.toString(), 'https://acme.api.k9o.io/rampart/jwks');
      expect(cap.plain.headers.containsKey('authorization'), isFalse);
      expect(r.keys.single.kid, 'k1');
      expect(r.keys.single.x, s.jwk.x);
      expect(r.issuer, issuer);
    });

    test('issuer is null when the feed advertises none', () async {
      final s = Signer('k1', 1);
      final core = mk(Cap(), handler: (req, n) async => resp(200, {'keys': [s.jwkJson]}));
      expect((await core.rampart.jwks()).issuer, isNull);
    });

    test('refuses a body that is not a key feed', () async {
      final core = mk(Cap(), handler: (req, n) async => resp(200, {'data': []}));
      final e = await kerrorOf(() => core.rampart.jwks());
      expect(e.code, 'K9O_INTERNAL_ERROR');
    });
  });

  group('rampart.verifyReceipt', () {
    K9oCore bare() => mk(Cap(), handler: (req, n) async => resp(500, {}));
    RampartJwks keysOf(Signer s, {String? iss = issuer}) => RampartJwks([s.jwk], issuer: iss);
    Future<RampartVerified> verify(
      K9oCore c,
      Object r,
      Object? inp,
      RampartJwks keys, {
      String? pid = projectId,
      String? iss,
      int skew = 60,
    }) => c.rampart.verifyReceipt(
      r, inp,
      keys: keys, projectId: pid, issuer: iss, clockSkewSeconds: skew, now: () => now,
    );

    test('accepts a good receipt and returns the verified claims', () async {
      final s = Signer('k1', 1);
      final v = await verify(bare(), sign(s), input, keysOf(s));
      expect(v.classification, 'suspicious');
      expect(v.riskScore, 6200);
      expect(v.confidence, 8100);
      expect(v.categories, ['prompt_injection']);
      expect(v.calibrationVersion, 'cal-1');
      expect(v.projectId, projectId);
      expect(v.inputSha256, sha256Hex(canonicalize(input)));
      expect(v.issuer, issuer);
      expect(v.issuedAt, nowS);
      expect(v.expiresAt, nowS + 3600);
      expect(v.kid, 'k1');
    });

    test('matches the input by its canonical form, not by key order', () async {
      final s = Signer('k1', 1);
      final reordered = {
        'nested': {'a': null, 'b': [1, 2]},
        'n': 1,
        'text': 'hello',
      };
      expect((await verify(bare(), sign(s), reordered, keysOf(s))).classification, 'suspicious');
    });

    test('accepts the classify result (envelope or data) and compares its projectId', () async {
      final s = Signer('k1', 1);
      final receipt = sign(s);
      RampartVerdict verdict(String pid) => RampartVerdict(
        classification: 'suspicious', riskScore: 1, confidence: 1, categories: const [],
        calibrationVersion: 'x', classificationReceipt: receipt, projectId: pid,
      );
      final c = bare();
      final env = Envelope(verdict(projectId), <String, dynamic>{});
      expect((await verify(c, env, input, keysOf(s), pid: null)).projectId, projectId);
      expect((await verify(c, verdict(projectId), input, keysOf(s), pid: null)).projectId, projectId);
      expect(
        await reasonOf(verify(c, Envelope(verdict('proj_other'), {}), input, keysOf(s), pid: null)),
        RampartReceiptReason.project,
      );
      // The projectId option wins over the one the result carries.
      expect((await verify(c, verdict('proj_other'), input, keysOf(s))).projectId, projectId);
    });

    test('verifies what classify returned, end to end', () async {
      final s = Signer('k1', 1);
      final receipt = sign(s);
      final cap = Cap();
      final core = mk(cap, handler: (req, n) async => req.url.path.endsWith('/classify')
          ? resp(200, {'data': {...verdictJson, 'classificationReceipt': receipt, 'projectId': projectId}, 'meta': {}})
          : resp(200, feed([s])));
      final r = await core.rampart.classify(input);
      final v = await core.rampart.verifyReceipt(r, input, now: () => now);
      expect(v.issuer, issuer);
      expect(v.projectId, projectId);
    });

    test('a bare receipt, or a result without projectId, is project_unknown', () async {
      final s = Signer('k1', 1);
      final receipt = sign(s);
      final c = bare();
      expect(await reasonOf(verify(c, receipt, input, keysOf(s), pid: null)), RampartReceiptReason.projectUnknown);
      final noPid = RampartVerdict(
        classification: 'suspicious', riskScore: 1, confidence: 1, categories: const [],
        calibrationVersion: 'x', classificationReceipt: receipt,
      );
      expect(await reasonOf(verify(c, noPid, input, keysOf(s), pid: null)), RampartReceiptReason.projectUnknown);
      expect((await verify(c, receipt, input, keysOf(s))).projectId, projectId);
    });

    test('anything that is not a receipt or a result is malformed', () async {
      final s = Signer('k1', 1);
      expect(await reasonOf(verify(bare(), 42, input, keysOf(s))), RampartReceiptReason.malformed);
    });

    test('takes the issuer from the key feed, never from the base URL', () async {
      final s = Signer('k1', 1);
      const feedIssuer = 'https://id.corp.internal/rampart';
      final core = K9oCore(
        baseUrl: 'https://acme.api-de01.corp.internal',
        projectSlug: 'p',
        accessToken: 't',
        httpClient: _fixed((req) => resp(200, {'keys': [s.jwkJson], 'issuer': feedIssuer})),
      );
      final good = sign(s, claims: {'iss': feedIssuer});
      expect((await core.rampart.verifyReceipt(good, input, projectId: projectId, now: () => now)).issuer, feedIssuer);
      final derived = sign(s, claims: {'iss': 'https://api.corp.internal/rampart'});
      expect(
        await reasonOf(core.rampart.verifyReceipt(derived, input, projectId: projectId, now: () => now)),
        RampartReceiptReason.issuer,
      );
    });

    test('refuses with issuer when neither the feed nor the option names one', () async {
      final s = Signer('k1', 1);
      final cap = Cap();
      final core = mk(cap, handler: (req, n) async => resp(200, {'keys': [s.jwkJson]}));
      final receipt = sign(s);
      try {
        await core.rampart.verifyReceipt(receipt, input, projectId: projectId, now: () => now);
        fail('expected a refusal');
      } on RampartReceiptError catch (e) {
        expect(e.reason, RampartReceiptReason.issuer);
        expect(e.detail, contains('no issuer is advertised'));
      }
      expect(
        await reasonOf(verify(bare(), receipt, input, RampartJwks([s.jwk]))),
        RampartReceiptReason.issuer,
      );
    });

    test('the issuer option overrides the feed and is binding', () async {
      final s = Signer('k1', 1);
      final c = bare();
      final other = sign(s, claims: {'iss': 'https://other.example/rampart'});
      expect(await reasonOf(verify(c, other, input, keysOf(s))), RampartReceiptReason.issuer);
      expect(
        (await verify(c, other, input, keysOf(s), iss: 'https://other.example/rampart')).issuer,
        'https://other.example/rampart',
      );
      expect(
        await reasonOf(verify(c, sign(s), input, keysOf(s), iss: 'https://other.example/rampart')),
        RampartReceiptReason.issuer,
      );
    });

    test('an input with a fraction or 2^53 is refused as input_hash', () async {
      final s = Signer('k1', 1);
      final receipt = sign(s);
      for (final bad in <Object>[
        {'x': 1.5},
        {'x': 9007199254740992},
        {'x': [0.1]},
        {'x': double.nan},
      ]) {
        expect(await reasonOf(verify(bare(), receipt, bad, keysOf(s))), RampartReceiptReason.inputHash, reason: '$bad');
      }
    });

    final cases = <(String, RampartReceiptReason, Object? Function(Signer))>[];
    void addCase(String name, RampartReceiptReason r, Object? Function(Signer) f) =>
        cases.add((name, r, f));

    String tamperSig(Signer s) {
      final parts = sign(s).split('.');
      final sig = base64Url.decode(base64Url.normalize(parts[2]));
      sig[0] ^= 1;
      return '${parts[0]}.${parts[1]}.${b64u(sig)}';
    }

    String tamperClaims(Signer s) {
      final parts = sign(s).split('.');
      final claims = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1])))) as Map<String, dynamic>;
      claims['classification'] = 'clear';
      return '${parts[0]}.${b64uJson(claims)}.${parts[2]}';
    }

    addCase('a kid the key set does not hold', RampartReceiptReason.keyUnknown, (s) => {'r': sign(s, header: {'kid': 'nope'})});
    addCase('a key of another type', RampartReceiptReason.keyUnknown, (s) => {'r': sign(s), 'keys': RampartJwks([RampartJwk(kid: 'k1', kty: 'RSA', crv: 'Ed25519', x: s.jwk.x)], issuer: issuer)});
    addCase('an Ed25519 key with a short x', RampartReceiptReason.keyUnknown, (s) => {'r': sign(s), 'keys': RampartJwks([RampartJwk(kid: 'k1', kty: 'OKP', crv: 'Ed25519', x: 'AAAA')], issuer: issuer)});
    addCase('alg HS256', RampartReceiptReason.alg, (s) => {'r': sign(s, header: {'alg': 'HS256'})});
    addCase('alg none', RampartReceiptReason.alg, (s) => {'r': sign(s, header: {'alg': 'none'})});
    addCase('typ JWT', RampartReceiptReason.typ, (s) => {'r': sign(s, header: {'typ': 'JWT'})});
    addCase('typ with another version', RampartReceiptReason.typ, (s) => {'r': sign(s, header: {'typ': 'k9o.rampart.classify.v2'})});
    addCase('no typ', RampartReceiptReason.typ, (s) => {'r': sign(s, header: {'typ': null})});
    addCase('another issuer', RampartReceiptReason.issuer, (s) => {'r': sign(s, claims: {'iss': 'https://evil.example/rampart'})});
    addCase('another project', RampartReceiptReason.project, (s) => {'r': sign(s, claims: {'project_id': 'proj_other'})});
    addCase('a project id that is a slug', RampartReceiptReason.project, (s) => {'r': sign(s, claims: {'project_id': 'portal'})});
    addCase('an input with a fractional number', RampartReceiptReason.inputHash, (s) => {'r': sign(s), 'input': {'text': 'hello', 'n': 1.5}});
    addCase('an input with an integer above 2^53-1', RampartReceiptReason.inputHash, (s) => {'r': sign(s), 'input': {'n': 9007199254740992}});
    addCase('expired past the skew', RampartReceiptReason.expired, (s) => {'r': sign(s, claims: {'iat': nowS - 7200, 'exp': nowS - 61})});
    addCase('issued in the future past the skew', RampartReceiptReason.notYetValid, (s) => {'r': sign(s, claims: {'iat': nowS + 61, 'exp': nowS + 3600})});
    addCase('another input', RampartReceiptReason.inputHash, (s) => {'r': sign(s), 'input': {'text': 'different'}});
    addCase('an input that cannot be canonicalised', RampartReceiptReason.inputHash, (s) => {'r': sign(s), 'input': {'text': double.nan}});
    addCase('a tampered signature', RampartReceiptReason.signature, (s) => {'r': tamperSig(s)});
    addCase('tampered claims', RampartReceiptReason.signature, (s) => {'r': tamperClaims(s)});
    addCase('a short signature', RampartReceiptReason.signature, (s) => {'r': '${sign(s).split('.').take(2).join('.')}.AAAA'});
    addCase('a signature by another key under the same kid', RampartReceiptReason.signature, (s) => {'r': sign(Signer('k1', 99))});
    addCase('two parts', RampartReceiptReason.malformed, (s) => {'r': 'only.two'});
    addCase('four parts', RampartReceiptReason.malformed, (s) => {'r': 'a.b.c.d'});
    addCase('characters outside base64url', RampartReceiptReason.malformed, (s) => {'r': '!!!.@@@.###'});
    addCase('a header that is not an object', RampartReceiptReason.malformed, (s) => {'r': '${b64u(utf8.encode('[]'))}.${b64u(utf8.encode('{}'))}.AAAA'});
    addCase('no kid', RampartReceiptReason.malformed, (s) => {'r': '${b64u(utf8.encode('{}'))}.${b64u(utf8.encode('{}'))}.AAAA'});
    addCase('a critical header parameter', RampartReceiptReason.malformed, (s) => {'r': sign(s, header: {'crit': ['x']})});
    addCase('a non-numeric exp', RampartReceiptReason.malformed, (s) => {'r': sign(s, claims: {'exp': 'soon'})});
    addCase('an unknown classification', RampartReceiptReason.malformed, (s) => {'r': sign(s, claims: {'classification': 'fine'})});
    addCase('a risk outside 0..10000', RampartReceiptReason.malformed, (s) => {'r': sign(s, claims: {'risk_bp': 10001})});
    addCase('a fractional confidence', RampartReceiptReason.malformed, (s) => {'r': sign(s, claims: {'confidence_bp': 1.5})});
    addCase('a missing digest', RampartReceiptReason.malformed, (s) => {'r': sign(s, claims: {'input_sha256': null})});
    addCase('a missing calibration version', RampartReceiptReason.malformed, (s) => {'r': sign(s, claims: {'calibration_version': null})});
    addCase('categories that are not strings', RampartReceiptReason.malformed, (s) => {'r': sign(s, claims: {'categories': [1]})});

    for (final c in cases) {
      test('refuses ${c.$1} with ${c.$2.value}', () async {
        final s = Signer('k1', 1);
        final made = c.$3(s) as Map<String, Object?>;
        final keys = (made['keys'] as RampartJwks?) ?? keysOf(s);
        final inp = made.containsKey('input') ? made['input'] : input;
        expect(await reasonOf(verify(bare(), made['r']!, inp, keys)), c.$2);
      });
    }

    test('covers every reason of the closed set', () {
      final covered = cases.map((c) => c.$2).toSet()
        ..add(RampartReceiptReason.keyUnavailable) // the key feed tests below
        ..add(RampartReceiptReason.projectUnknown); // the project tests above
      expect(covered, RampartReceiptReason.values.toSet());
      expect(RampartReceiptReason.values.map((r) => r.value).toList()..sort(), [
        'alg', 'expired', 'input_hash', 'issuer', 'key_unavailable', 'key_unknown', 'malformed',
        'not_yet_valid', 'project', 'project_unknown', 'signature', 'typ',
      ]);
    });

    test('applies the clock skew at both ends, 60 s by default, and takes another value', () async {
      final s = Signer('k1', 1);
      final c = bare();
      final late = sign(s, claims: {'iat': nowS - 3600, 'exp': nowS - 60});
      expect((await verify(c, late, input, keysOf(s))).kid, 'k1');
      expect(await reasonOf(verify(c, late, input, keysOf(s), skew: 10)), RampartReceiptReason.expired);
      final early = sign(s, claims: {'iat': nowS + 60, 'exp': nowS + 3600});
      expect((await verify(c, early, input, keysOf(s))).kid, 'k1');
      expect(await reasonOf(verify(c, early, input, keysOf(s), skew: 0)), RampartReceiptReason.notYetValid);
    });

    test('windows: present, absent, invalid, and unknown claims', () async {
      final s = Signer('k1', 1);
      Future<RampartVerified> v(Map<String, dynamic> claims) =>
          verify(bare(), sign(s, claims: claims), input, keysOf(s));
      expect((await v({'windows': 3})).windows, 3);
      expect((await v({'windows': 3.0})).windows, 3);
      expect((await v({})).windows, 1);
      expect((await v({'future_claim': {'x': 1}})).windows, 1);
      for (final bad in <Object>[0, -1, 1.5, '2', true, [], {}]) {
        expect(await reasonOf(v({'windows': bad})), RampartReceiptReason.malformed, reason: '$bad');
      }
    });

    test('takes the verdict from the signed claims', () async {
      final s = Signer('k1', 1);
      final v = await verify(
        bare(),
        sign(s, claims: {'classification': 'malicious', 'risk_bp': 9900}),
        input,
        keysOf(s),
      );
      expect([v.classification, v.riskScore], ['malicious', 9900]);
    });

    test('does not use a key carried inside the receipt', () async {
      final real = Signer('k1', 1);
      final attacker = Signer('k1', 2);
      final receipt = sign(attacker, header: {'jwk': attacker.jwkJson});
      expect(await reasonOf(verify(bare(), receipt, input, keysOf(real))), RampartReceiptReason.signature);
    });

    group('the key feed', () {
      test('fetches the feed itself, keeps it, and does not fetch again for a known kid', () async {
        final s = Signer('k1', 1);
        final cap = Cap();
        final core = mk(cap, handler: (req, n) async => resp(200, feed([s])));
        final receipt = sign(s);
        for (var i = 0; i < 3; i++) {
          await core.rampart.verifyReceipt(receipt, input, projectId: projectId, now: () => now);
        }
        expect(jwksFetches(cap), 1);
      });

      test('refetches once on an unknown kid and then finds the rotated key', () async {
        final old = Signer('k1', 1), rotated = Signer('k2', 2);
        var published = [old];
        final cap = Cap();
        final core = mk(cap, handler: (req, n) async => resp(200, feed(published)));
        await core.rampart.verifyReceipt(sign(old), input, projectId: projectId, now: () => now);
        published = [old, rotated];
        final v = await core.rampart.verifyReceipt(sign(rotated), input, projectId: projectId, now: () => now);
        expect(v.kid, 'k2');
        expect(jwksFetches(cap), 2);
      });

      test('refetches only once per call for a kid that never appears', () async {
        final known = Signer('k1', 1), stranger = Signer('zz', 3);
        final cap = Cap();
        final core = mk(cap, handler: (req, n) async => resp(200, feed([known])));
        await core.rampart.verifyReceipt(sign(known), input, projectId: projectId, now: () => now);
        expect(
          await reasonOf(core.rampart.verifyReceipt(sign(stranger), input, projectId: projectId, now: () => now)),
          RampartReceiptReason.keyUnknown,
        );
        expect(jwksFetches(cap), 2);
      });

      test('does not fetch twice in one call when the first fetch already lacks the kid', () async {
        final known = Signer('k1', 1), stranger = Signer('zz', 3);
        final cap = Cap();
        final core = mk(cap, handler: (req, n) async => resp(200, feed([known])));
        expect(
          await reasonOf(core.rampart.verifyReceipt(sign(stranger), input, projectId: projectId, now: () => now)),
          RampartReceiptReason.keyUnknown,
        );
        expect(jwksFetches(cap), 1);
      });

      test('never fetches when you pass the key set', () async {
        final s = Signer('k1', 1);
        final cap = Cap();
        final core = mk(cap, handler: (req, n) async => resp(200, feed([s])));
        await core.rampart.verifyReceipt(sign(s), input, keys: keysOf(s), projectId: projectId, now: () => now);
        await reasonOf(core.rampart.verifyReceipt(sign(s, header: {'kid': 'x'}), input, keys: keysOf(s), projectId: projectId, now: () => now));
        expect(cap.count, 0);
      });

      test('refuses with key_unavailable, not a pass, when the feed cannot be read', () async {
        final s = Signer('k1', 1);
        final core = mk(Cap(), handler: (req, n) async => resp(503, {
          'code': 'K9O_UPSTREAM_UNAVAILABLE', 'message': 'down', 'context': {},
        }));
        expect(
          await reasonOf(core.rampart.verifyReceipt(sign(s), input, projectId: projectId, now: () => now)),
          RampartReceiptReason.keyUnavailable,
        );
      });
    });
  });
}

http.Client _fixed(http.StreamedResponse Function(http.BaseRequest) f) =>
    _Fixed(f);

class _Fixed extends http.BaseClient {
  final http.StreamedResponse Function(http.BaseRequest) f;
  _Fixed(this.f);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'HEAD') {
      return http.StreamedResponse(const Stream.empty(), 200);
    }
    return f(request);
  }
}
