import 'dart:convert';
import 'dart:io';

import 'package:k9o_core/k9o_core.dart';
import 'package:k9o_core/src/sha256.dart';
import 'package:test/test.dart';

void main() {
  final fixture =
      jsonDecode(File('test/fixtures/jcs-cases.json').readAsStringSync())
          as Map<String, dynamic>;
  final cases = (fixture['cases'] as List).cast<Map<String, dynamic>>();

  group('platform canonical form: shared cases', () {
    test('the fixture holds the 25 shared cases', () {
      expect(cases, hasLength(25));
    });
    for (final c in cases) {
      test(c['name'] as String, () {
        if (c.containsKey('expectError')) {
          expect(() => canonicalize(c['input']), throwsA(isA<JcsError>()));
        } else {
          expect(canonicalize(c['input']), c['expectCanonical']);
        }
      });
    }
  });

  group('platform canonical form: objects, strings, numbers', () {
    test('sorts keys by UTF-8 byte order, not UTF-16 code units', () {
      expect(
        canonicalize({'\u{1f600}': 1, '\uff5e': 2, '\ufb00': 3}),
        '{"\ufb00":3,"\uff5e":2,"\u{1f600}":1}',
      );
    });

    test('handles nesting, empty containers and no whitespace', () {
      expect(
        canonicalize({
          'b': [],
          'a': {},
          'c': [
            1,
            {'z': 1, 'y': null},
          ],
        }),
        '{"a":{},"b":[],"c":[1,{"y":null,"z":1}]}',
      );
    });

    test('writes -0 as 0 and refuses fractions, NaN, Infinity and 2^53', () {
      expect(canonicalize(-0.0), '0');
      expect(canonicalize(3.0), '3');
      for (final n in <num>[
        0.5,
        1e-7,
        1e21,
        9007199254740992,
        -9007199254740992,
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        expect(() => canonicalize(n), throwsA(isA<JcsError>()), reason: '$n');
      }
    });

    test('refuses other values and unpaired surrogates', () {
      expect(() => canonicalize(DateTime(2020)), throwsA(isA<JcsError>()));
      expect(() => canonicalize([Object()]), throwsA(isA<JcsError>()));
      expect(() => canonicalize({1: 2}), throwsA(isA<JcsError>()));
      expect(
        () => canonicalize(String.fromCharCode(0xd800)),
        throwsA(isA<JcsError>()),
      );
      expect(
        () => canonicalize({String.fromCharCode(0xdc00): 1}),
        throwsA(isA<JcsError>()),
      );
    });
  });

  group('sha256', () {
    test('matches the known vectors', () {
      expect(
        sha256Hex(''),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      expect(
        sha256Hex('abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      expect(
        sha256Hex('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
      );
      expect(
        sha256Hex('x' * 1000),
        '44f8354494a5ba03ba1792a8d3e9c534c47a9181980fde7a3f44b06ef2ae7c7f',
      );
    });

    test('pads correctly at the block boundaries', () {
      // Known SHA-256 of 55, 56 and 64 'a' bytes.
      expect(
        sha256Hex('a' * 55),
        '9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318',
      );
      expect(
        sha256Hex('a' * 56),
        'b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a',
      );
      expect(
        sha256Hex('a' * 64),
        'ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb',
      );
    });
  });
}
