import 'dart:convert';

/// Thrown by [canonicalize] for a value that cannot be written in the canonical form.
class JcsError implements Exception {
  final String message;
  JcsError(this.message);
  @override
  String toString() => 'JcsError: $message';
}

const int _maxSafe = 9007199254740991; // 2^53 - 1

String _str(String s) {
  final u = s.codeUnits;
  final b = StringBuffer('"');
  for (var i = 0; i < u.length; i++) {
    final c = u[i];
    if (c >= 0xD800 && c <= 0xDBFF) {
      if (i + 1 < u.length && u[i + 1] >= 0xDC00 && u[i + 1] <= 0xDFFF) {
        b
          ..writeCharCode(c)
          ..writeCharCode(u[i + 1]);
        i++;
        continue;
      }
      throw JcsError('string contains an unpaired surrogate');
    }
    if (c >= 0xDC00 && c <= 0xDFFF) {
      throw JcsError('string contains an unpaired surrogate');
    }
    switch (c) {
      case 0x22:
        b.write(r'\"');
      case 0x5C:
        b.write(r'\\');
      case 0x08:
        b.write(r'\b');
      case 0x09:
        b.write(r'\t');
      case 0x0A:
        b.write(r'\n');
      case 0x0C:
        b.write(r'\f');
      case 0x0D:
        b.write(r'\r');
      default:
        if (c < 0x20) {
          b.write('\\u${c.toRadixString(16).padLeft(4, '0')}');
        } else {
          b.writeCharCode(c);
        }
    }
  }
  return (b..write('"')).toString();
}

String _num(num n) {
  if (n is double) {
    if (!n.isFinite) throw JcsError('NaN and Infinity cannot be canonicalised');
    if (n != n.truncateToDouble()) {
      throw JcsError(
        'only integers can be canonicalised; a fractional number is refused',
      );
    }
    if (n.abs() > _maxSafe) {
      throw JcsError(
        'an integer above 9007199254740991 in absolute value is refused',
      );
    }
    return n == 0 ? '0' : n.toInt().toString();
  }
  final i = n as int;
  if (i > _maxSafe || i < -_maxSafe) {
    throw JcsError(
      'an integer above 9007199254740991 in absolute value is refused',
    );
  }
  return i.toString();
}

int _cmp(List<int> a, List<int> b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final d = a[i] - b[i];
    if (d != 0) return d;
  }
  return a.length - b.length;
}

String _write(Object? v) {
  if (v == null) return 'null';
  if (v is bool) return v ? 'true' : 'false';
  if (v is num) return _num(v);
  if (v is String) return _str(v);
  if (v is List) return '[${v.map(_write).join(',')}]';
  if (v is Map) {
    final entries = <MapEntry<List<int>, String>>[];
    for (final e in v.entries) {
      final k = e.key;
      if (k is! String) throw JcsError('an object key must be a string');
      final quoted = _str(k);
      entries.add(MapEntry(utf8.encode(k), '$quoted:${_write(e.value)}'));
    }
    entries.sort((a, b) => _cmp(a.key, b.key));
    return '{${entries.map((e) => e.value).join(',')}}';
  }
  throw JcsError('a ${v.runtimeType} value cannot be canonicalised');
}

/// The platform's canonical JSON form (the "Kilimanjaro JCS code-point profile") of [value].
///
/// Object members are sorted by their names' UTF-8 bytes (Unicode code point order, not
/// UTF-16 order), with no whitespace. Strings use the minimal escapes: `"`, `\`, the short
/// escapes `\b \t \n \f \r`, other control characters below U+0020 as lowercase `\u00xx`;
/// everything else is written literally. Numbers are integers only, up to 2^53 - 1 in
/// absolute value (`-0` is `0`); a fraction, NaN, Infinity or a larger integer throws
/// [JcsError], as does any value that is not JSON.
String canonicalize(Object? value) => _write(value);
