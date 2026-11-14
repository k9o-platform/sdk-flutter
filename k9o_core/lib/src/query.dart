import 'client.dart';
import 'envelope.dart';

/// Result of [translateNamedParams].
class TranslatedQuery {
  final String sql;
  final List<Object?> params;
  const TranslatedQuery(this.sql, this.params);
}

bool _identStart(String c) {
  final u = c.codeUnitAt(0);
  return (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || u == 95;
}

bool _identChar(String c) {
  final u = c.codeUnitAt(0);
  return _identStart(c) || (u >= 48 && u <= 57);
}

Object? _checkValue(Object? value, String where) {
  if (value == null || value is String || value is bool) return value;
  if (value is num && value.isFinite) return value;
  throw invalidValue(
    '$where must be a string, number, boolean or null; serialise anything else (for example as JSON text) first',
  );
}

final RegExp _dollarTag = RegExp(r'\$([A-Za-z_][A-Za-z0-9_]*)?\$');

/// Rewrite `:name` placeholders to `$n`.
///
/// Skips quoted text, comments, dollar-quoted strings and `::` casts, so
/// `data->>'role' = :role` and `x::int` come out right. Each distinct name gets one
/// number in order of first appearance. A placeholder with no key in [named] throws
/// [KError] `K9O_INVALID_FIELD_VALUE` with the message `no value for :name`.
TranslatedQuery translateNamedParams(String sql, Map<String, Object?> named) {
  final order = <String>[];
  final out = StringBuffer();
  var i = 0;
  final n = sql.length;
  while (i < n) {
    final c = sql[i];
    final next = i + 1 < n ? sql[i + 1] : null;
    if (c == "'" ||
        ((c == 'E' || c == 'e') &&
            next == "'" &&
            !(i > 0 && _identChar(sql[i - 1])))) {
      final escapes = c != "'";
      var j = escapes ? i + 2 : i + 1;
      for (; j < n; j++) {
        if (escapes && sql[j] == r'\') {
          j++;
          continue;
        }
        if (sql[j] == "'") {
          if (j + 1 < n && sql[j + 1] == "'") {
            j++;
            continue;
          }
          break;
        }
      }
      final end = j + 1 < n ? j + 1 : n;
      out.write(sql.substring(i, end));
      i = j + 1;
    } else if (c == '"') {
      var j = i + 1;
      for (; j < n; j++) {
        if (sql[j] == '"') {
          if (j + 1 < n && sql[j + 1] == '"') {
            j++;
            continue;
          }
          break;
        }
      }
      final end = j + 1 < n ? j + 1 : n;
      out.write(sql.substring(i, end));
      i = j + 1;
    } else if (c == '-' && next == '-') {
      var j = sql.indexOf('\n', i);
      if (j == -1) j = n;
      out.write(sql.substring(i, j));
      i = j;
    } else if (c == '/' && next == '*') {
      var depth = 1;
      var j = i + 2;
      while (j < n && depth > 0) {
        if (sql[j] == '/' && j + 1 < n && sql[j + 1] == '*') {
          depth++;
          j += 2;
        } else if (sql[j] == '*' && j + 1 < n && sql[j + 1] == '/') {
          depth--;
          j += 2;
        } else {
          j++;
        }
      }
      if (j > n) j = n;
      out.write(sql.substring(i, j));
      i = j;
    } else if (c == r'$') {
      final m = _dollarTag.matchAsPrefix(sql, i);
      if (m != null) {
        final tag = m.group(0)!;
        final close = sql.indexOf(tag, i + tag.length);
        final end = close == -1 ? n : close + tag.length;
        out.write(sql.substring(i, end));
        i = end;
      } else {
        out.write(c);
        i++;
      }
    } else if (c == ':' && next == ':') {
      out.write('::');
      i += 2;
    } else if (c == ':' &&
        next != null &&
        _identStart(next) &&
        !(i > 0 && _identChar(sql[i - 1]))) {
      var j = i + 2;
      while (j < n && _identChar(sql[j])) {
        j++;
      }
      final name = sql.substring(i + 1, j);
      var idx = order.indexOf(name);
      if (idx == -1) {
        if (!named.containsKey(name)) {
          throw invalidValue('no value for :$name', {'name': name});
        }
        order.add(name);
        idx = order.length - 1;
      }
      out.write('\$${idx + 1}');
      i = j;
    } else {
      out.write(c);
      i++;
    }
  }
  return TranslatedQuery(out.toString(), [
    for (final name in order) _checkValue(named[name], 'the value for :$name'),
  ]);
}

/// POST /@<slug>/query — run one read-only SQL statement; `data` is the list of rows.
///
/// [params] is a `List` (positional, bound to `$1, $2, ...`; the SQL is sent as
/// written) or a `Map` of named values (`:name` placeholders are rewritten to `$n`
/// and the values become the positional list). Values are bound by the database,
/// never interpolated into the text.
///
/// Gateway rules: read-only (a write is refused with `K9O_RAW_SQL_READ_ONLY`), one
/// statement per call, row-level security applies, at most 100000 characters of SQL
/// and 1000 parameters, and the caller needs the project-editor role.
Future<Envelope<List<Map<String, dynamic>>>> runQuery(
  K9oCore core,
  String sql, [
  Object? params,
]) async {
  core.requireProjectSlug();
  var text = sql;
  var values = <Object?>[];
  if (params is List) {
    values = [
      for (var i = 0; i < params.length; i++)
        _checkValue(params[i], 'params[$i]'),
    ];
  } else if (params is Map) {
    final named = <String, Object?>{};
    for (final e in params.entries) {
      named[e.key.toString()] = e.value;
    }
    final t = translateNamedParams(sql, named);
    text = t.sql;
    values = t.params;
  } else if (params != null) {
    throw invalidValue('params must be a List (positional) or a Map (named)');
  }
  final body = <String, dynamic>{
    'sql': text,
    if (values.isNotEmpty) 'params': values,
  };
  return core.send<List<Map<String, dynamic>>>(
    'POST',
    'query',
    body: body,
    decode: rowsOf,
  );
}

/// Internal: decode a list of row objects.
List<Map<String, dynamic>> rowsOf(Object? data) {
  if (data is! List) {
    throw invalidInternal();
  }
  return [for (final r in data) (r as Map).cast<String, dynamic>()];
}
