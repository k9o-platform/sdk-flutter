import 'dart:convert';

import 'package:k9o_core/src/ed25519.dart';
import 'package:test/test.dart';

import 'ed_sign.dart';

List<int> hex(String s) => [
  for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16),
];
String toHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

// RFC 8032 section 7.1, test vectors 1 to 3.
const vectors = <List<String>>[
  [
    '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60',
    'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a',
    '',
    'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
  ],
  [
    '4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb',
    '3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c',
    '72',
    '92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00',
  ],
  [
    'c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7',
    'fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025',
    'af82',
    '6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a',
  ],
];

void main() {
  group('sha512', () {
    test('matches the known vectors', () {
      expect(
        toHex(sha512Bytes(utf8.encode('abc'))),
        'ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a'
        '2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f',
      );
      expect(
        toHex(sha512Bytes(const [])),
        'cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce'
        '47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e',
      );
      // 111, 112 and 128 bytes straddle the padding boundary of a 128-byte block.
      expect(
        toHex(sha512Bytes(List.filled(111, 0x61))),
        'fa9121c7b32b9e01733d034cfc78cbf67f926c7ed83e82200ef8681819692176'
        '0b4beff48404df811b953828274461673c68d04e297b0eb7b2b4d60fc6b566a2',
      );
      expect(
        toHex(sha512Bytes(List.filled(112, 0x61))),
        'c01d080efd492776a1c43bd23dd99d0a2e626d481e16782e75d54c2503b5dc32'
        'bd05f0f1ba33e568b88fd2d970929b719ecbb152f58f130a407c8830604b70ca',
      );
      expect(
        toHex(sha512Bytes(List.filled(128, 0x61))),
        'b73d1929aa615934e61a871596b3f3b33359f42b8175602e89f7e06e5f658a24'
        '3667807ed300314b95cacdd579f3e33abdfbe351909519a846d465c59582f321',
      );
    });
  });

  group('RFC 8032 Ed25519', () {
    for (var i = 0; i < vectors.length; i++) {
      final v = vectors[i];
      test('vector ${i + 1}: verifies, and the test signer reproduces it', () {
        final pub = hex(v[1]), msg = hex(v[2]), sig = hex(v[3]);
        expect(ed25519Verify(pub, msg, sig), isTrue);
        expect(toHex(edPublicKey(hex(v[0]))), v[1]);
        expect(toHex(edSign(hex(v[0]), msg)), v[3]);
      });
      test('vector ${i + 1}: refuses a changed message, key or signature', () {
        final pub = hex(v[1]), msg = hex(v[2]), sig = hex(v[3]);
        expect(ed25519Verify(pub, [...msg, 0], sig), isFalse);
        final badSig = [...sig]..[10] ^= 1;
        expect(ed25519Verify(pub, msg, badSig), isFalse);
        final badS = [...sig]..[40] ^= 1;
        expect(ed25519Verify(pub, msg, badS), isFalse);
        final other = hex(vectors[(i + 1) % 3][1]);
        expect(ed25519Verify(other, msg, sig), isFalse);
      });
    }

    test('refuses wrong lengths, a non-canonical S and a bad point encoding', () {
      final v = vectors[0];
      final pub = hex(v[1]), sig = hex(v[3]);
      expect(ed25519Verify(pub.sublist(1), const [], sig), isFalse);
      expect(ed25519Verify(pub, const [], sig.sublist(1)), isFalse);
      // S + L is the same scalar mod L but not canonical.
      final l = (BigInt.one << 252) +
          BigInt.parse('27742317777372353535851937790883648493');
      var s = BigInt.zero;
      for (var i = 63; i >= 32; i--) {
        s = (s << 8) | BigInt.from(sig[i]);
      }
      final big = s + l;
      final sig2 = [
        ...sig.sublist(0, 32),
        for (var i = 0; i < 32; i++) ((big >> (8 * i)) & BigInt.from(255)).toInt(),
      ];
      expect(ed25519Verify(pub, const [], sig2), isFalse);
      // y = 2^255 - 1 is >= p: not a valid encoding.
      final badKey = List<int>.filled(32, 0xff)..[31] = 0x7f;
      expect(ed25519Verify(badKey, const [], sig), isFalse);
      final badR = [...List<int>.filled(32, 0xff)..[31] = 0x7f, ...sig.sublist(32)];
      expect(ed25519Verify(pub, const [], badR), isFalse);
    });

    test('signs and verifies a longer message with an arbitrary seed', () {
      final seed = List<int>.generate(32, (i) => i * 7 + 1);
      final msg = utf8.encode('eyJhbGciOiJFZERTQSJ9.' * 20);
      expect(ed25519Verify(edPublicKey(seed), msg, edSign(seed, msg)), isTrue);
      expect(
        ed25519Verify(edPublicKey(seed), [...msg, 1], edSign(seed, msg)),
        isFalse,
      );
    });
  });
}
