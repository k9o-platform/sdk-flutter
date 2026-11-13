import 'dart:async';
import 'dart:convert';

import 'package:unorm_dart/unorm_dart.dart' show nfkc, nfkd;

import 'sha256.dart';

/// Moat: a local guard around one model call. It runs in your process, makes no network
/// call and needs no account.
///
/// What it does:
///  1. Pins the system prompt. [Moat.messages] builds the message list itself: your prompt
///     is always the one `system` message and the untrusted input is always a `user`
///     message, never a `system` one.
///  2. Refuses untrusted input that carries a role or system marker (a refusal, not a
///     sanitiser).
///  3. Enforces a declared input schema and a declared output schema.
///  4. Filters the output for personal data through a function you pass (optional).
///
/// The pin is structural. It stops injected text from becoming the system prompt; it does
/// not stop that text from reaching the model, so keep treating the model's answer as
/// untrusted and check it with [Moat.checkOutput].
///
/// A refusal is thrown as [MoatRefusal], with a [MoatReason] from a closed set and a short
/// `detail` that never repeats the refused content. A bad prompt or schema given to the
/// constructor throws [MoatConfigError].
///
/// Schema language: a subset of JSON Schema. Supported keywords: `type` (object, array,
/// string, number, integer, boolean, null, or a list of them), `properties`, `required`,
/// `additionalProperties` (true or false), `items` (one schema), `enum`, `const`,
/// `minLength`, `maxLength`, `pattern` (a regular expression, searched, not anchored),
/// `minimum`, `maximum`, `minItems`, `maxItems`. Any other keyword is rejected by the
/// constructor, so a typo never switches a check off.

/// Why a call was refused. The set is closed.
enum MoatReason {
  roleMarker('role_marker'),
  inputSchema('input_schema'),
  outputSchema('output_schema'),
  pii('pii');

  /// The cross-SDK name, for example `role_marker`.
  final String value;
  const MoatReason(this.value);
}

/// Thrown when input or output is refused.
class MoatRefusal implements Exception {
  final MoatReason reason;
  final String detail;
  MoatRefusal(this.reason, this.detail);

  @override
  String toString() => 'moat refused (${reason.value}): $detail';
}

/// Thrown by the constructor for an empty prompt, an unsupported schema keyword or a
/// malformed schema.
class MoatConfigError implements Exception {
  final String message;
  MoatConfigError(this.message);
  @override
  String toString() => 'MoatConfigError: $message';
}

/// One chat message: [role] is `system` or `user`.
class MoatMessage {
  final String role;
  final String content;
  const MoatMessage(this.role, this.content);

  @override
  bool operator ==(Object other) =>
      other is MoatMessage && other.role == role && other.content == content;
  @override
  int get hashCode => Object.hash(role, content);
  @override
  String toString() => 'MoatMessage($role)';
}

/// A PII filter: gets the output as text. `true`, a number above 0, a non-empty list, or a
/// map with `found: true` or `total` above 0 means personal data was found. Any other shape
/// is treated as a refusal (the filter is not understood, so the output is not passed).
typedef MoatPiiFilter = FutureOr<Object?> Function(String text);

const int _maxDepth = 64;

const Set<String> _keywords = {
  'type', 'properties', 'required', 'additionalProperties', 'items', 'enum', //
  'const', 'minLength', 'maxLength', 'pattern', 'minimum', 'maximum',
  'minItems', 'maxItems',
};
const List<String> _types = [
  'object', 'array', 'string', 'number', 'integer', 'boolean', 'null', //
];

bool _isInt(Object? v) => v is num && v.isFinite && v == v.truncateToDouble();

void _checkCount(Map schema, String key, String path) {
  if (schema.containsKey(key)) {
    final v = schema[key];
    if (!(_isInt(v) && (v as num) >= 0)) {
      throw MoatConfigError('$path: $key must be a non-negative integer');
    }
  }
}

/// Reject anything outside the subset.
void _assertSupported(Object? schema, String path) {
  if (schema is! Map)
    throw MoatConfigError('$path: a schema must be an object');
  for (final k in schema.keys) {
    if (k is! String || !_keywords.contains(k)) {
      throw MoatConfigError('$path: unsupported schema keyword "$k"');
    }
  }
  if (schema.containsKey('type')) {
    final t = schema['type'];
    final list = t is List ? t : [t];
    if (list.isEmpty || !list.every((x) => x is String && _types.contains(x))) {
      throw MoatConfigError(
        '$path: type must be one of ${_types.join(', ')} or a list of them',
      );
    }
  }
  if (schema.containsKey('properties')) {
    final props = schema['properties'];
    if (props is! Map) {
      throw MoatConfigError('$path: properties must be an object of schemas');
    }
    props.forEach((k, v) => _assertSupported(v, '$path.$k'));
  }
  if (schema.containsKey('required')) {
    final r = schema['required'];
    if (!(r is List && r.every((x) => x is String))) {
      throw MoatConfigError('$path: required must be a list of property names');
    }
  }
  if (schema.containsKey('additionalProperties') &&
      schema['additionalProperties'] is! bool) {
    throw MoatConfigError('$path: additionalProperties must be true or false');
  }
  if (schema.containsKey('items')) _assertSupported(schema['items'], '$path[]');
  if (schema.containsKey('enum')) {
    final e = schema['enum'];
    if (!(e is List && e.isNotEmpty)) {
      throw MoatConfigError('$path: enum must be a non-empty list');
    }
  }
  for (final k in const ['minLength', 'maxLength', 'minItems', 'maxItems']) {
    _checkCount(schema, k, path);
  }
  if (schema.containsKey('pattern')) {
    final pat = schema['pattern'];
    if (pat is! String) {
      throw MoatConfigError('$path: pattern must be a string');
    }
    try {
      RegExp(pat);
    } on FormatException {
      throw MoatConfigError('$path: pattern is not a valid regular expression');
    }
  }
  for (final k in const ['minimum', 'maximum']) {
    if (schema.containsKey(k)) {
      final v = schema[k];
      if (!(v is num && v.isFinite)) {
        throw MoatConfigError('$path: $k must be a finite number');
      }
    }
  }
}

String _typeOf(Object? v) {
  if (v == null) return 'null';
  if (v is List) return 'array';
  if (v is String) return 'string';
  if (v is bool) return 'boolean';
  if (v is num) {
    if (!v.isFinite) return 'other';
    return v == v.truncateToDouble() ? 'integer' : 'number';
  }
  if (v is Map) return 'object';
  return 'other';
}

bool _deepEqual(Object? a, Object? b) {
  if (a is num && b is num) return a == b;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEqual(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !_deepEqual(a[k], b[k])) return false;
    }
    return true;
  }
  return a == b;
}

int _len(String s) => s.runes.length;

/// The first violation of [schema] by [value] as a short message without the value, or null.
String? _violation(Object? value, Map schema, String path) {
  final actual = _typeOf(value);
  if (schema.containsKey('type')) {
    final t = schema['type'];
    final list = (t is List ? t : [t]).cast<String>();
    final ok = list.any(
      (x) => x == actual || (x == 'number' && actual == 'integer'),
    );
    if (!ok) return '$path: expected ${list.join(' or ')}, got $actual';
  }
  if (schema.containsKey('const') && !_deepEqual(value, schema['const'])) {
    return '$path: does not equal the required constant';
  }
  if (schema.containsKey('enum') &&
      !(schema['enum'] as List).any((e) => _deepEqual(e, value))) {
    return '$path: not one of the allowed values';
  }
  if (value is String) {
    final minL = schema['minLength'], maxL = schema['maxLength'];
    if (minL != null && _len(value) < (minL as num)) {
      return '$path: shorter than ${(minL).toInt()}';
    }
    if (maxL != null && _len(value) > (maxL as num)) {
      return '$path: longer than ${(maxL).toInt()}';
    }
    final pat = schema['pattern'];
    if (pat != null && !RegExp(pat as String).hasMatch(value)) {
      return '$path: does not match the pattern';
    }
  }
  if (value is num) {
    final mn = schema['minimum'], mx = schema['maximum'];
    if (mn != null && value < (mn as num)) return '$path: below $mn';
    if (mx != null && value > (mx as num)) return '$path: above $mx';
  }
  if (value is List) {
    final mn = schema['minItems'], mx = schema['maxItems'];
    if (mn != null && value.length < (mn as num)) {
      return '$path: fewer than ${mn.toInt()} items';
    }
    if (mx != null && value.length > (mx as num)) {
      return '$path: more than ${mx.toInt()} items';
    }
    final items = schema['items'];
    if (items != null) {
      for (var i = 0; i < value.length; i++) {
        final v = _violation(value[i], items as Map, '$path[$i]');
        if (v != null) return v;
      }
    }
  }
  if (value is Map) {
    for (final k in (schema['required'] as List?) ?? const []) {
      if (!value.containsKey(k)) {
        return '$path: missing required property "$k"';
      }
    }
    final props = (schema['properties'] as Map?) ?? const {};
    for (final k in value.keys) {
      if (props.containsKey(k)) {
        final v = _violation(value[k], props[k] as Map, '$path.$k');
        if (v != null) return v;
      } else if (schema['additionalProperties'] == false) {
        return '$path: unexpected property "$k"';
      }
    }
  }
  return null;
}

// --- role markers ---

final RegExp _lineRole = RegExp(
  r'^ ?(system|assistant|developer|tool|user) ?:',
);
final RegExp _roleJson = RegExp(
  r'"role"\s*:\s*"\s*(system|developer|assistant)\s*"',
);
final RegExp _lineBreak = RegExp('[\r\n\u0085\u2028\u2029]');
const List<String> _markers = [
  '<|system|>', '<|im_start|>', '<|im_end|>', '[inst]', '<<sys>>', //
  '### system', '### instruction',
];
const List<String> _privileged = ['system', 'developer', 'assistant'];

/// Default-ignorable and format code points removed before matching, as inclusive
/// [from, to] pairs. The same table is used in every SDK.
const List<List<int>> _ignorable = [
  [0x00AD, 0x00AD], [0x034F, 0x034F], [0x061C, 0x061C], [0x115F, 0x1160], //
  [0x17B4, 0x17B5], [0x180B, 0x180F], [0x200B, 0x200F], [0x202A, 0x202E],
  [0x2060, 0x206F], [0x3164, 0x3164], [0xFE00, 0xFE0F], [0xFEFF, 0xFEFF],
  [0xFFA0, 0xFFA0], [0xFFF0, 0xFFF8], [0x1BCA0, 0x1BCA3], [0x1D173, 0x1D17A],
  [0xE0000, 0xE0FFF],
];

bool _isIgnorable(int cp) {
  for (final r in _ignorable) {
    if (cp >= r[0] && cp <= r[1]) return true;
  }
  return false;
}

/// Cyrillic and Greek look-alikes of the marker letters, code point to the lowercase Latin
/// letter, applied to the comparison text only. Mirrors moat-confusables.json (version 2);
/// a test asserts the two are equal. This is not general homoglyph detection.
const Map<int, String> moatConfusables = {
  0x0430: 'a',
  0x0410: 'a',
  0x0441: 'c',
  0x0421: 'c',
  0x0435: 'e',
  0x0415: 'e',
  0x0456: 'i',
  0x0406: 'i',
  0x043E: 'o',
  0x041E: 'o',
  0x0440: 'p',
  0x0420: 'p',
  0x0455: 's',
  0x0405: 's',
  0x0443: 'y',
  0x0423: 'y',
  0x0501: 'd',
  0x04CF: 'l',
  0x04C0: 'l',
  0x0422: 't',
  0x041C: 'm',
  0x041D: 'h',
  0x0445: 'x',
  0x0425: 'x',
  0x0391: 'a',
  0x03B1: 'a',
  0x0395: 'e',
  0x03B5: 'e',
  0x0399: 'i',
  0x03B9: 'i',
  0x039F: 'o',
  0x03BF: 'o',
  0x03A1: 'p',
  0x03C1: 'p',
  0x03A4: 't',
  0x03C4: 't',
  0x03A5: 'y',
  0x03C5: 'u',
  0x03BD: 'v',
  0x039C: 'm',
  0x039D: 'n',
  0x03A7: 'x',
  0x03C7: 'x',
  0x03F2: 'c',
  0x03F9: 'c',
  0x0397: 'h',
  0x0442: 't',
};

final RegExp _mark = RegExp(r'[\p{Mn}\p{Me}]', unicode: true);

/// Horizontal whitespace: tab and every Unicode space separator (Zs).
bool _isHSpace(int cp) =>
    cp == 0x09 ||
    cp == 0x20 ||
    cp == 0xA0 ||
    cp == 0x1680 ||
    (cp >= 0x2000 && cp <= 0x200A) ||
    cp == 0x202F ||
    cp == 0x205F ||
    cp == 0x3000;

/// The text as it is compared with the markers: NFKC, NFKD with nonspacing and enclosing
/// marks dropped, ignorable and format characters removed, confusables mapped to Latin,
/// case-folded, runs of horizontal whitespace collapsed to one space (line breaks
/// kept, because the label check is line-start). Used for matching only.
String _normalise(String s) {
  final b = StringBuffer();
  final stripped = nfkd(nfkc(s)).replaceAll(_mark, '');
  for (final cp in stripped.runes) {
    if (_isIgnorable(cp)) continue;
    final m = moatConfusables[cp];
    if (m != null) {
      b.write(m);
    } else {
      b.writeCharCode(cp);
    }
  }
  final out = StringBuffer();
  var inSpace = false;
  for (final cp in b.toString().toLowerCase().runes) {
    if (_isHSpace(cp)) {
      if (!inSpace) out.write(' ');
      inSpace = true;
    } else {
      inSpace = false;
      out.writeCharCode(cp);
    }
  }
  return out.toString();
}

/// Text of a scalar JSON value as `JSON.stringify` would write it; null when [v] is not JSON.
String? _stringify(Object? v, [int depth = 0]) {
  if (depth > _maxDepth + 1) return null;
  if (v == null) return 'null';
  if (v is bool) return v ? 'true' : 'false';
  if (v is num) {
    if (!v.isFinite) return 'null';
    return v == v.truncateToDouble() && v.abs() < 1e21
        ? v.toInt().toString()
        : v.toString();
  }
  if (v is String) return jsonEncode(v);
  if (v is List) {
    final parts = <String>[];
    for (final x in v) {
      parts.add(_stringify(x, depth + 1) ?? 'null');
    }
    return '[${parts.join(',')}]';
  }
  if (v is Map) {
    final parts = <String>[];
    for (final e in v.entries) {
      final s = _stringify(e.value, depth + 1);
      if (s == null) continue;
      parts.add('${jsonEncode(e.key.toString())}:$s');
    }
    return '{${parts.join(',')}}';
  }
  return null;
}

String? _markerIn(String text) {
  final n = _normalise(text);
  for (final line in n.split(_lineBreak)) {
    final m = _lineRole.firstMatch(line);
    if (m != null) return 'a line starts with "${m.group(1)}:"';
  }
  for (final m in _markers) {
    if (n.contains(m)) return 'contains the marker $m';
  }
  if (_roleJson.hasMatch(n)) {
    return 'contains a JSON object with a role of system, developer or assistant';
  }
  return null;
}

const String _roleJsonDetail =
    'contains a JSON object with a role of system, developer or assistant';
const String _tooDeep = 'the input is nested too deeply';

/// Scan every string value and object key at any depth (to a depth of 64).
String? _scan(Object? v, int depth) {
  if (depth > _maxDepth) return _tooDeep;
  if (v is String) return _markerIn(v);
  if (v is List) {
    for (final x in v) {
      final r = _scan(x, depth + 1);
      if (r != null) return r;
    }
  } else if (v is Map) {
    for (final e in v.entries) {
      final k = _markerIn(e.key.toString());
      if (k != null) return k;
      final r = _scan(e.value, depth + 1);
      if (r != null) return r;
    }
  }
  return null;
}

String? _roleKeyed(Object? v, int depth) {
  if (depth > _maxDepth) return _tooDeep;
  if (v is List) {
    for (final x in v) {
      final r = _roleKeyed(x, depth + 1);
      if (r != null) return r;
    }
    return null;
  }
  if (v is! Map) return null;
  for (final e in v.entries) {
    final x = e.value;
    if (_normalise(e.key.toString()).trim() == 'role' &&
        x is String &&
        _privileged.contains(_normalise(x).trim())) {
      return _roleJsonDetail;
    }
    final r = _roleKeyed(x, depth + 1);
    if (r != null) return r;
  }
  return null;
}

/// A local guard around one model call. See the library notes above.
class Moat {
  final String _prompt;
  final Map? _inputSchema;
  final Map? _outputSchema;
  final MoatPiiFilter? _pii;

  /// [prompt] is the pinned system prompt. [inputSchema] is what the untrusted input must
  /// satisfy before it is placed in the message list; [outputSchema] is what the model
  /// output must satisfy. [pii], when given, is called with the output as text.
  Moat({
    required String prompt,
    Map<String, dynamic>? inputSchema,
    Map<String, dynamic>? outputSchema,
    MoatPiiFilter? pii,
  })  : _prompt = prompt,
        _inputSchema = inputSchema,
        _outputSchema = outputSchema,
        _pii = pii {
    if (prompt.isEmpty) {
      throw MoatConfigError('prompt must be a non-empty string');
    }
    if (inputSchema != null) _assertSupported(inputSchema, 'inputSchema');
    if (outputSchema != null) _assertSupported(outputSchema, 'outputSchema');
  }

  /// The message list for one model call: the pinned prompt as `system`, then the untrusted
  /// input as text in a `user` message (a string as it is, anything else as JSON). Throws
  /// [MoatRefusal] (`input_schema` or `role_marker`).
  List<MoatMessage> messages(Object? untrustedInput) {
    final schema = _inputSchema;
    if (schema != null) {
      final v = _violation(untrustedInput, schema, r'$');
      if (v != null) throw MoatRefusal(MoatReason.inputSchema, v);
    }
    final text =
        untrustedInput is String ? untrustedInput : _stringify(untrustedInput);
    if (text == null) {
      throw MoatRefusal(
        MoatReason.inputSchema,
        'the input cannot be written as JSON',
      );
    }
    var found = _markerIn(text);
    if (found == null) {
      // Object input is written as one JSON line, which hides line starts: look inside
      // every string value and key as well.
      Object? parsed = untrustedInput;
      if (untrustedInput is String) {
        try {
          parsed = jsonDecode(untrustedInput);
        } catch (_) {
          parsed = untrustedInput;
        }
      }
      found = _scan(parsed, 0) ?? _roleKeyed(parsed, 0);
    }
    if (found != null) throw MoatRefusal(MoatReason.roleMarker, found);
    return [MoatMessage('system', _prompt), MoatMessage('user', text)];
  }

  /// Check what the model returned. Without an output schema the value is returned as it
  /// is. With one, a string is parsed as JSON first (unless the schema asks for a string)
  /// and must conform; then the PII filter, if any, sees the output as text. Returns the
  /// validated value. Throws [MoatRefusal] (`output_schema` or `pii`).
  Future<Object?> checkOutput(Object? modelOutput) async {
    var value = modelOutput;
    final schema = _outputSchema;
    if (schema != null) {
      final t = schema['type'];
      final types = t == null ? const <Object?>[] : (t is List ? t : [t]);
      final stringOnly = types.length == 1 && types[0] == 'string';
      if (modelOutput is String && !stringOnly) {
        try {
          value = jsonDecode(modelOutput);
        } catch (_) {
          if (!types.contains('string')) {
            throw MoatRefusal(
              MoatReason.outputSchema,
              'the output is not valid JSON',
            );
          }
        }
      }
      final v = _violation(value, schema, r'$');
      if (v != null) throw MoatRefusal(MoatReason.outputSchema, v);
    }
    final pii = _pii;
    if (pii != null) {
      final text = value is String ? value : (_stringify(value) ?? '');
      Object? r;
      try {
        r = await pii(text);
      } catch (_) {
        throw MoatRefusal(
          MoatReason.pii,
          'the PII filter failed, so the output is not passed',
        );
      }
      final bool? hit = r is bool
          ? r
          : r is num
              ? r > 0
              : r is List
                  ? r.isNotEmpty
                  : r is Map && (r['found'] is bool || r['total'] is num)
                      ? (r['found'] == true ||
                          (r['total'] is num && r['total'] > 0))
                      : null;
      if (hit == null) {
        throw MoatRefusal(
          MoatReason.pii,
          'the PII filter returned an unrecognised result, so the output is not passed',
        );
      }
      if (hit) {
        throw MoatRefusal(MoatReason.pii, 'the output contains personal data');
      }
    }
    return value;
  }

  /// Lowercase hex SHA-256 of the pinned prompt, for example to pass to Rampart as input.
  String promptSha256() => sha256Hex(_prompt);
}
