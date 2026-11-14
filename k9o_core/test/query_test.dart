import 'package:k9o_core/k9o_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('translateNamedParams (shared vectors)', () {
    void vec(
      String name,
      String sql,
      Map<String, Object?> named,
      String out,
      List<Object?> params,
    ) {
      test(name, () {
        final t = translateNamedParams(sql, named);
        expect(t.sql, out);
        expect(t.params, params);
      });
    }

    vec(
      '1 json operator and a string value',
      "SELECT * FROM users WHERE data->>'role' = :role",
      {'role': 'admin'},
      "SELECT * FROM users WHERE data->>'role' = \$1",
      ['admin'],
    );
    vec(
      '2 repeated names reuse one number',
      'SELECT :a, :b, :a',
      {'a': 1, 'b': 2},
      r'SELECT $1, $2, $1',
      [1, 2],
    );
    vec(
      '3 quoted text and casts are untouched',
      "SELECT ':not_a_param', \":also_not\", x::int FROM t WHERE y = :y",
      {'y': true},
      "SELECT ':not_a_param', \":also_not\", x::int FROM t WHERE y = \$1",
      [true],
    );
    vec(
      '4 escaped quote and line comment',
      "SELECT 'it''s :no' , :v -- :comment\nFROM t",
      {'v': null},
      "SELECT 'it''s :no' , \$1 -- :comment\nFROM t",
      [null],
    );
    vec(
      '5 nested block comment',
      'SELECT /* :c /* :d */ :e */ :f',
      {'f': 1},
      r'SELECT /* :c /* :d */ :e */ $1',
      [1],
    );
    vec(
      '6 dollar-quoted strings',
      r'SELECT $$ :x $$, $q$ :y $q$, :z',
      {'z': 's'},
      r'SELECT $$ :x $$, $q$ :y $q$, $1',
      ['s'],
    );
    vec(
      '7 array slice and a:b',
      'SELECT arr[1:2], a:b, :n',
      {'n': 5},
      r'SELECT arr[1:2], a:b, $1',
      [5],
    );

    test('8 a missing value throws before any request', () {
      expect(
        () => translateNamedParams('SELECT :missing', {}),
        throwsA(
          isA<KError>()
              .having((e) => e.code, 'code', 'K9O_INVALID_FIELD_VALUE')
              .having((e) => e.message, 'message', contains(':missing')),
        ),
      );
    });

    test('9 an object value is refused', () {
      expect(
        () => translateNamedParams('SELECT :a', {'a': <String, Object?>{}}),
        throwsA(
          isA<KError>().having(
            (e) => e.code,
            'code',
            'K9O_INVALID_FIELD_VALUE',
          ),
        ),
      );
    });

    test(
      'extra keys are ignored; E-strings with backslash escapes are skipped',
      () {
        final t = translateNamedParams(r"SELECT E'it\'s :no', :a", {
          'a': 1,
          'unused': 2,
        });
        expect(t.sql, r"SELECT E'it\'s :no', $1");
        expect(t.params, [1]);
      },
    );

    test('quoted identifier with doubled quote is skipped; unterminated text does not throw', () {
      expect(
        translateNamedParams('SELECT "a"":b" , :c', {'c': 1}).sql,
        'SELECT "a"":b" , \$1',
      );
      expect(
        translateNamedParams("SELECT 'open :a", {}).sql,
        "SELECT 'open :a",
      );
    });

    test('NaN and a list are refused as values', () {
      expect(
        () => translateNamedParams('SELECT :a', {'a': double.nan}),
        throwsA(isA<KError>()),
      );
      expect(
        () => translateNamedParams('SELECT :a', {
          'a': [1],
        }),
        throwsA(isA<KError>()),
      );
    });
  });

  group('core.query wire shape', () {
    test('10 positional list is sent unchanged', () async {
      final cap = Cap();
      final r = await mk(
        cap,
        data: [
          {'n': 1},
        ],
        meta: {
          'rawQuery': {'intent': 'select', 'rowCount': 1},
        },
      ).query(r'SELECT $1', ['x']);
      expect(cap.plain.method, 'POST');
      expect(
        cap.req.url.toString(),
        'https://acme.api.k9o.io/@member-portal/query',
      );
      expect(cap.req.headers['authorization'], 'Bearer tok_abc');
      expect(cap.json, {
        'sql': r'SELECT $1',
        'params': ['x'],
      });
      expect(r.data, [
        {'n': 1},
      ]);
      expect(r.meta['rawQuery'], {'intent': 'select', 'rowCount': 1});
    });

    test('11 no params: the body has no params key', () async {
      final cap = Cap(), core = mk(cap, data: []);
      await core.query('SELECT 1');
      expect(cap.json, {'sql': 'SELECT 1'});
      await core.query('SELECT 1', <Object?>[]);
      expect(cap.json.containsKey('params'), isFalse);
      await core.query('SELECT 1', <String, Object?>{});
      expect(cap.json.containsKey('params'), isFalse);
    });

    test('a map is rewritten to positional parameters', () async {
      final cap = Cap();
      await mk(cap, data: []).query(
        "SELECT * FROM users WHERE data->>'role' = :role AND n > :n",
        {'role': 'admin', 'n': 3},
      );
      expect(cap.json, {
        'sql': "SELECT * FROM users WHERE data->>'role' = \$1 AND n > \$2",
        'params': ['admin', 3],
      });
    });

    test(
      'invalid values and param types are refused before any request',
      () async {
        final cap = Cap(), core = mk(cap, data: []);
        expect(
          (await kerrorOf(() => core.query('SELECT :a', {'a': DateTime(2026)})))
              .code,
          'K9O_INVALID_FIELD_VALUE',
        );
        expect(
          (await kerrorOf(() => core.query(r'SELECT $1', [<int>[]]))).message,
          contains('params[0]'),
        );
        expect(
          (await kerrorOf(() => core.query('SELECT 1', 'x'))).code,
          'K9O_INVALID_FIELD_VALUE',
        );
        expect(
          (await kerrorOf(
            () => core.query('SELECT :missing', <String, Object?>{}),
          )).message,
          contains(':missing'),
        );
        expect(cap.count, 0);
      },
    );

    test('a missing projectSlug is refused before any request', () async {
      final cap = Cap();
      final e = await kerrorOf(() => mk(cap, slug: null).query('SELECT 1'));
      expect(e.code, 'K9O_MISSING_PROJECT_CONTEXT');
      expect(cap.count, 0);
    });

    test('a gateway refusal surfaces as KError', () async {
      final cap = Cap();
      final core = mk(
        cap,
        status: 400,
        errorBody: {'code': 'K9O_RAW_SQL_READ_ONLY', 'message': 'read only'},
      );
      final e = await kerrorOf(() => core.query('DELETE FROM t'));
      expect(e.code, 'K9O_RAW_SQL_READ_ONLY');
      expect(e.status, 400);
    });
  });

  group('core.search', () {
    test('GETs the collection with textSearch parameters and paging', () async {
      final cap = Cap();
      await mk(
        cap,
        data: [],
        meta: {
          'cursor': {'next': 'c2'},
        },
      ).search(
        'posts',
        column: 'body',
        q: 'hello world',
        language: 'german',
        type: TextSearchType.websearch,
        limit: 5,
        cursor: 'c1',
      );
      expect(cap.req.method, 'GET');
      expect(cap.req.url.path, '/@member-portal/data/posts');
      expect(cap.req.url.queryParameters, {
        'textSearch': 'body:hello world',
        'textSearchLanguage': 'german',
        'textSearchType': 'websearch',
        'limit': '5',
        'cursor': 'c1',
      });
    });

    test('defaults omit language and type; the query is URL-encoded', () async {
      final cap = Cap();
      await mk(cap, data: []).search('posts', column: 'body', q: 'a&b c');
      expect(cap.req.url.query, contains('textSearch=body%3Aa%26b+c'));
      expect(cap.req.url.queryParameters.keys, ['textSearch']);
    });

    test('validation errors come before any request', () async {
      final cap = Cap(), core = mk(cap, data: []);
      expect(
        (await kerrorOf(() => core.search('posts', column: 'bad col', q: 'x')))
            .code,
        'K9O_INVALID_FIELD_VALUE',
      );
      expect(
        (await kerrorOf(() => core.search('posts', column: 'body', q: '')))
            .code,
        'K9O_INVALID_FIELD_VALUE',
      );
      expect(
        (await kerrorOf(
          () => core.search(
            'posts',
            column: 'body',
            q: 'x',
            language: 'en glish',
          ),
        )).code,
        'K9O_INVALID_FIELD_VALUE',
      );
      expect(cap.count, 0);
    });
  });
}
