import 'dart:convert';

const List<int> _k = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, //
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

const int _m = 0xffffffff;
int _rotr(int x, int n) => ((x >>> n) | (x << (32 - n))) & _m;

/// SHA-256 of [data] as 32 bytes. Pure Dart, 32-bit arithmetic only (runs on the web too).
List<int> sha256Bytes(List<int> data) {
  final h = <int>[
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, //
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];
  final bitLen = data.length * 8;
  final padLen = ((data.length + 9 + 63) ~/ 64) * 64;
  final msg = List<int>.filled(padLen, 0);
  for (var i = 0; i < data.length; i++) {
    msg[i] = data[i] & 0xff;
  }
  msg[data.length] = 0x80;
  // 64-bit big-endian length; messages here are far below 2^32 bits * 2^21.
  final hi = bitLen ~/ 0x100000000;
  final lo = bitLen % 0x100000000;
  for (var i = 0; i < 4; i++) {
    msg[padLen - 8 + i] = (hi >>> (24 - 8 * i)) & 0xff;
    msg[padLen - 4 + i] = (lo >>> (24 - 8 * i)) & 0xff;
  }
  final w = List<int>.filled(64, 0);
  for (var off = 0; off < padLen; off += 64) {
    for (var i = 0; i < 16; i++) {
      w[i] =
          (msg[off + 4 * i] << 24) |
          (msg[off + 4 * i + 1] << 16) |
          (msg[off + 4 * i + 2] << 8) |
          msg[off + 4 * i + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & _m;
    }
    var a = h[0], b = h[1], c = h[2], d = h[3];
    var e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e & _m) & g);
      final t1 = (hh + s1 + ch + _k[i] + w[i]) & _m;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & _m;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & _m;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & _m;
    }
    h[0] = (h[0] + a) & _m;
    h[1] = (h[1] + b) & _m;
    h[2] = (h[2] + c) & _m;
    h[3] = (h[3] + d) & _m;
    h[4] = (h[4] + e) & _m;
    h[5] = (h[5] + f) & _m;
    h[6] = (h[6] + g) & _m;
    h[7] = (h[7] + hh) & _m;
  }
  final out = <int>[];
  for (final v in h) {
    out
      ..add((v >>> 24) & 0xff)
      ..add((v >>> 16) & 0xff)
      ..add((v >>> 8) & 0xff)
      ..add(v & 0xff);
  }
  return out;
}

/// Lowercase hex SHA-256 of the UTF-8 bytes of [text].
String sha256Hex(String text) => sha256Bytes(utf8.encode(text))
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();
