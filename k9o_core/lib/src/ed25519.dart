// Ed25519 signature verification (RFC 8032, section 5.1.7) in pure Dart.
//
// The package has no crypto dependency, so receipt verification uses this file. It only
// verifies: no secret key is ever held, so constant-time behaviour is not needed. It uses
// BigInt, so it runs on every Dart platform (VM, Flutter on iOS and Android, web) with no
// OS-level crypto API and no minimum OS version. A verification takes a few milliseconds.
//
// `ed25519Verify` is cofactorless: it accepts a signature when [S]B == R + [h]A, rejects a
// non-canonical S (S >= L) and rejects a public key or R that is not a valid point encoding.

import 'dart:typed_data';

final BigInt _p = (BigInt.one << 255) - BigInt.from(19);
final BigInt _l =
    (BigInt.one << 252) +
    BigInt.parse('27742317777372353535851937790883648493');
final BigInt _zero = BigInt.zero;
final BigInt _one = BigInt.one;
final BigInt _two = BigInt.two;

BigInt _inv(BigInt x) => x.modPow(_p - _two, _p);
final BigInt _d = (BigInt.from(-121665) * _inv(BigInt.from(121666))) % _p;
final BigInt _sqrtM1 = _two.modPow((_p - _one) ~/ BigInt.from(4), _p);

// Extended homogeneous coordinates (X, Y, Z, T).
class _Pt {
  final BigInt x, y, z, t;
  const _Pt(this.x, this.y, this.z, this.t);
}

BigInt? _recoverX(BigInt y, int sign) {
  if (y >= _p) return null;
  final x2 = ((y * y - _one) * _inv(_d * y * y + _one)) % _p;
  if (x2 == _zero) return sign == 1 ? null : _zero;
  var x = x2.modPow((_p + BigInt.from(3)) ~/ BigInt.from(8), _p);
  if ((x * x - x2) % _p != _zero) x = (x * _sqrtM1) % _p;
  if ((x * x - x2) % _p != _zero) return null;
  if ((x.isOdd ? 1 : 0) != sign) x = _p - x;
  return x;
}

final _Pt _base = () {
  final by = (BigInt.from(4) * _inv(BigInt.from(5))) % _p;
  final bx = _recoverX(by, 0)!;
  return _Pt(bx, by, _one, (bx * by) % _p);
}();
final _Pt _identity = _Pt(_zero, _one, _one, _zero);

_Pt _add(_Pt a, _Pt b) {
  final a1 = ((a.y - a.x) * (b.y - b.x)) % _p;
  final b1 = ((a.y + a.x) * (b.y + b.x)) % _p;
  final c1 = (_two * a.t * b.t * _d) % _p;
  final d1 = (_two * a.z * b.z) % _p;
  final e = b1 - a1, f = d1 - c1, g = d1 + c1, h = b1 + a1;
  return _Pt((e * f) % _p, (g * h) % _p, (f * g) % _p, (e * h) % _p);
}

_Pt _mul(BigInt scalar, _Pt point) {
  var result = _identity;
  var addend = point;
  var s = scalar;
  while (s > _zero) {
    if (s.isOdd) result = _add(result, addend);
    addend = _add(addend, addend);
    s >>= 1;
  }
  return result;
}

bool _equal(_Pt a, _Pt b) =>
    (a.x * b.z - b.x * a.z) % _p == _zero &&
    (a.y * b.z - b.y * a.z) % _p == _zero;

BigInt _le(List<int> bytes) {
  var n = _zero;
  for (var i = bytes.length - 1; i >= 0; i--) {
    n = (n << 8) | BigInt.from(bytes[i]);
  }
  return n;
}

_Pt? _decode(List<int> enc) {
  if (enc.length != 32) return null;
  var y = _le(enc);
  final sign = (y >> 255).toInt();
  y &= (_one << 255) - _one;
  final x = _recoverX(y, sign);
  if (x == null) return null;
  return _Pt(x, y, _one, (x * y) % _p);
}

// --- SHA-512 (BigInt 64-bit words; only the verify path needs it) ---

final BigInt _m64 = (_one << 64) - _one;
final List<BigInt> _k512 = [
  '428a2f98d728ae22', '7137449123ef65cd', 'b5c0fbcfec4d3b2f', 'e9b5dba58189dbbc', //
  '3956c25bf348b538', '59f111f1b605d019', '923f82a4af194f9b', 'ab1c5ed5da6d8118',
  'd807aa98a3030242', '12835b0145706fbe', '243185be4ee4b28c', '550c7dc3d5ffb4e2',
  '72be5d74f27b896f', '80deb1fe3b1696b1', '9bdc06a725c71235', 'c19bf174cf692694',
  'e49b69c19ef14ad2', 'efbe4786384f25e3', '0fc19dc68b8cd5b5', '240ca1cc77ac9c65',
  '2de92c6f592b0275', '4a7484aa6ea6e483', '5cb0a9dcbd41fbd4', '76f988da831153b5',
  '983e5152ee66dfab', 'a831c66d2db43210', 'b00327c898fb213f', 'bf597fc7beef0ee4',
  'c6e00bf33da88fc2', 'd5a79147930aa725', '06ca6351e003826f', '142929670a0e6e70',
  '27b70a8546d22ffc', '2e1b21385c26c926', '4d2c6dfc5ac42aed', '53380d139d95b3df',
  '650a73548baf63de', '766a0abb3c77b2a8', '81c2c92e47edaee6', '92722c851482353b',
  'a2bfe8a14cf10364', 'a81a664bbc423001', 'c24b8b70d0f89791', 'c76c51a30654be30',
  'd192e819d6ef5218', 'd69906245565a910', 'f40e35855771202a', '106aa07032bbd1b8',
  '19a4c116b8d2d0c8', '1e376c085141ab53', '2748774cdf8eeb99', '34b0bcb5e19b48a8',
  '391c0cb3c5c95a63', '4ed8aa4ae3418acb', '5b9cca4f7763e373', '682e6ff3d6b2b8a3',
  '748f82ee5defb2fc', '78a5636f43172f60', '84c87814a1f0ab72', '8cc702081a6439ec',
  '90befffa23631e28', 'a4506cebde82bde9', 'bef9a3f7b2c67915', 'c67178f2e372532b',
  'ca273eceea26619c', 'd186b8c721c0c207', 'eada7dd6cde0eb1e', 'f57d4f7fee6ed178',
  '06f067aa72176fba', '0a637dc5a2c898a6', '113f9804bef90dae', '1b710b35131c471b',
  '28db77f523047d84', '32caab7b40c72493', '3c9ebe0a15c9bebc', '431d67c49c100d4c',
  '4cc5d4becb3e42b6', '597f299cfc657e2a', '5fcb6fab3ad6faec', '6c44198c4a475817',
].map((s) => BigInt.parse(s, radix: 16)).toList();

BigInt _rotr64(BigInt x, int n) => ((x >> n) | (x << (64 - n))) & _m64;

/// SHA-512 of [data] as 64 bytes.
List<int> sha512Bytes(List<int> data) {
  final h = [
    '6a09e667f3bcc908', 'bb67ae8584caa73b', '3c6ef372fe94f82b', 'a54ff53a5f1d36f1', //
    '510e527fade682d1', '9b05688c2b3e6c1f', '1f83d9abfb41bd6b', '5be0cd19137e2179',
  ].map((s) => BigInt.parse(s, radix: 16)).toList();
  final padLen = ((data.length + 17 + 127) ~/ 128) * 128;
  final msg = Uint8List(padLen);
  for (var i = 0; i < data.length; i++) {
    msg[i] = data[i] & 0xff;
  }
  msg[data.length] = 0x80;
  final bitLen = data.length * 8;
  for (var i = 0; i < 8; i++) {
    msg[padLen - 1 - i] = (bitLen ~/ _pow256(i)) % 256;
  }
  final w = List<BigInt>.filled(80, _zero);
  for (var off = 0; off < padLen; off += 128) {
    for (var i = 0; i < 16; i++) {
      var v = _zero;
      for (var j = 0; j < 8; j++) {
        v = (v << 8) | BigInt.from(msg[off + 8 * i + j]);
      }
      w[i] = v;
    }
    for (var i = 16; i < 80; i++) {
      final s0 = _rotr64(w[i - 15], 1) ^ _rotr64(w[i - 15], 8) ^ (w[i - 15] >> 7);
      final s1 = _rotr64(w[i - 2], 19) ^ _rotr64(w[i - 2], 61) ^ (w[i - 2] >> 6);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & _m64;
    }
    var a = h[0], b = h[1], c = h[2], d = h[3];
    var e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var i = 0; i < 80; i++) {
      final s1 = _rotr64(e, 14) ^ _rotr64(e, 18) ^ _rotr64(e, 41);
      final ch = (e & f) ^ ((e ^ _m64) & g);
      final t1 = (hh + s1 + ch + _k512[i] + w[i]) & _m64;
      final s0 = _rotr64(a, 28) ^ _rotr64(a, 34) ^ _rotr64(a, 39);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & _m64;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & _m64;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & _m64;
    }
    final s = [a, b, c, d, e, f, g, hh];
    for (var i = 0; i < 8; i++) {
      h[i] = (h[i] + s[i]) & _m64;
    }
  }
  final out = <int>[];
  for (final v in h) {
    for (var j = 7; j >= 0; j--) {
      out.add(((v >> (8 * j)) & BigInt.from(0xff)).toInt());
    }
  }
  return out;
}

int _pow256(int n) {
  var r = 1;
  for (var i = 0; i < n; i++) {
    r *= 256;
  }
  return r;
}

/// True when [signature] (64 bytes) is a valid Ed25519 signature of [message] under
/// [publicKey] (32 bytes).
bool ed25519Verify(List<int> publicKey, List<int> message, List<int> signature) {
  if (publicKey.length != 32 || signature.length != 64) return false;
  final a = _decode(publicKey);
  final r = _decode(signature.sublist(0, 32));
  if (a == null || r == null) return false;
  final s = _le(signature.sublist(32));
  if (s >= _l) return false;
  final h =
      _le(sha512Bytes([...signature.sublist(0, 32), ...publicKey, ...message])) %
      _l;
  return _equal(_mul(s, _base), _add(r, _mul(h, a)));
}
