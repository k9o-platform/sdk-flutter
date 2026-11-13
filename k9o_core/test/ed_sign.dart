// Test-only RFC 8032 Ed25519 signing, written independently of lib/src/ed25519.dart
// (affine arithmetic, no shared code except SHA-512), so a signature made here and
// accepted by the SDK's verifier cross-checks both.
import 'package:k9o_core/src/ed25519.dart' show sha512Bytes;

final BigInt _p = (BigInt.one << 255) - BigInt.from(19);
final BigInt _l =
    (BigInt.one << 252) +
    BigInt.parse('27742317777372353535851937790883648493');
BigInt _inv(BigInt x) => x.modPow(_p - BigInt.two, _p);
final BigInt _d = (BigInt.from(-121665) * _inv(BigInt.from(121666))) % _p;

typedef _P = (BigInt, BigInt);

_P _addA(_P a, _P b) {
  final x1 = a.$1, y1 = a.$2, x2 = b.$1, y2 = b.$2;
  final t = _d * x1 * x2 * y1 * y2 % _p;
  final x3 = (x1 * y2 + x2 * y1) * _inv(BigInt.one + t) % _p;
  final y3 = (y1 * y2 + x1 * x2) * _inv(BigInt.one - t) % _p;
  return (x3, y3);
}

_P _mulA(BigInt k, _P pt) {
  var r = (BigInt.zero, BigInt.one);
  var q = pt;
  while (k > BigInt.zero) {
    if (k.isOdd) r = _addA(r, q);
    q = _addA(q, q);
    k >>= 1;
  }
  return r;
}

final _P _bp = () {
  final y = BigInt.from(4) * _inv(BigInt.from(5)) % _p;
  final x2 = (y * y - BigInt.one) * _inv(_d * y * y + BigInt.one) % _p;
  var x = x2.modPow((_p + BigInt.from(3)) ~/ BigInt.from(8), _p);
  if ((x * x - x2) % _p != BigInt.zero) {
    x = x * BigInt.two.modPow((_p - BigInt.one) ~/ BigInt.from(4), _p) % _p;
  }
  if (x.isOdd) x = _p - x;
  return (x, y);
}();

BigInt _le(List<int> b) {
  var n = BigInt.zero;
  for (var i = b.length - 1; i >= 0; i--) {
    n = (n << 8) | BigInt.from(b[i]);
  }
  return n;
}

List<int> _leBytes(BigInt n, int len) => [
  for (var i = 0; i < len; i++) ((n >> (8 * i)) & BigInt.from(255)).toInt(),
];

List<int> _enc(_P pt) =>
    _leBytes(pt.$2 | (pt.$1.isOdd ? BigInt.one << 255 : BigInt.zero), 32);

({BigInt a, List<int> prefix, List<int> pub}) _expand(List<int> seed) {
  final h = sha512Bytes(seed);
  final s = h.sublist(0, 32);
  s[0] &= 248;
  s[31] &= 127;
  s[31] |= 64;
  final a = _le(s);
  return (a: a, prefix: h.sublist(32), pub: _enc(_mulA(a, _bp)));
}

/// The 32-byte public key for [seed].
List<int> edPublicKey(List<int> seed) => _expand(seed).pub;

/// The 64-byte signature of [msg] under [seed].
List<int> edSign(List<int> seed, List<int> msg) {
  final k = _expand(seed);
  final r = _le(sha512Bytes([...k.prefix, ...msg])) % _l;
  final rEnc = _enc(_mulA(r, _bp));
  final h = _le(sha512Bytes([...rEnc, ...k.pub, ...msg])) % _l;
  final s = (r + h * k.a) % _l;
  return [...rEnc, ..._leBytes(s, 32)];
}
