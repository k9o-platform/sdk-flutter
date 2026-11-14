import 'package:k9o_core/k9o_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

const base = 'https://acme.api.k9o.io/@member-portal/data';

void main() {
  group('select', () {
    test('GET /data/<collection> with no query string', () async {
      final cap = Cap();
      final r = await mk(
        cap,
        data: [
          {'id': 'rec_1'},
        ],
        meta: {
          'cursor': {'next': 'n1'},
        },
      ).from('posts').select();
      expect(cap.req.method, 'GET');
      expect(cap.req.url.toString(), '$base/posts');
      expect(cap.req.headers['authorization'], 'Bearer tok_abc');
      expect(r.data.single['id'], 'rec_1');
      expect((r.meta['cursor'] as Map)['next'], 'n1');
    });

    test(
      'every filter, limit, cursor and count become query parameters',
      () async {
        final cap = Cap();
        await mk(cap, data: [])
            .from('posts')
            .select()
            .eq('a', 'x')
            .neq('b', 2)
            .gt('c', 3)
            .gte('d', 4)
            .lt('e', 5)
            .lte('f', 6)
            .inList('g', ['p', 'q'])
            .notIn('h', [1, 2])
            .like('i', 'a%')
            .ilike('j', 'B%')
            .isValue('k', 'null')
            .filter('l', 'eq', true)
            .limit(10)
            .cursor('cur')
            .count(CountMode.exact)
            .execute();
        expect(cap.req.url.queryParameters, {
          'a': 'eq.x',
          'b': 'neq.2',
          'c': 'gt.3',
          'd': 'gte.4',
          'e': 'lt.5',
          'f': 'lte.6',
          'g': 'in.(p,q)',
          'h': 'notIn.(1,2)',
          'i': 'like.a%',
          'j': 'ilike.B%',
          'k': 'is.null',
          'l': 'eq.true',
          'limit': '10',
          'cursor': 'cur',
          'count': 'exact',
        });
      },
    );

    test('whole-number doubles print without a fraction', () async {
      final cap = Cap();
      await mk(cap, data: []).from('posts').select().eq('n', 2.0).gt('m', 1.5);
      expect(cap.req.url.queryParameters, {'n': 'eq.2', 'm': 'gt.1.5'});
    });

    test('an unknown filter operator is refused', () {
      expect(
        () => mk(Cap()).from('posts').select().filter('a', 'between', 1),
        throwsA(isA<KError>()),
      );
    });

    test(
      'bad collection names and a missing slug fail before any request',
      () async {
        final cap = Cap();
        expect(
          (await kerrorOf(() => mk(cap).from('Bad Name').select())).code,
          'K9O_INVALID_FIELD_VALUE',
        );
        expect(
          (await kerrorOf(() => mk(cap, slug: null).from('posts').select()))
              .code,
          'K9O_MISSING_PROJECT_CONTEXT',
        );
        expect(cap.count, 0);
      },
    );
  });

  group('insert / update / delete', () {
    test('insert POSTs the record', () async {
      final cap = Cap();
      final r = await mk(
        cap,
        data: {'id': 'rec_1', 'title': 'Hi'},
        status: 201,
      ).from('posts').insert({'title': 'Hi'});
      expect(cap.req.method, 'POST');
      expect(cap.req.url.toString(), '$base/posts');
      expect(cap.json, {'title': 'Hi'});
      expect(r.data['id'], 'rec_1');
    });

    test('update PATCHes /<id> with the patch', () async {
      final cap = Cap();
      await mk(
        cap,
        data: {'id': 'rec 1'},
      ).from('posts').update({'title': 'New'}).eq('id', 'rec 1');
      expect(cap.req.method, 'PATCH');
      expect(cap.req.url.toString(), '$base/posts/rec%201');
      expect(cap.json, {'title': 'New'});
    });

    test('delete DELETEs /<id>', () async {
      final cap = Cap();
      final r = await mk(
        cap,
        data: {'id': 'rec_1'},
      ).from('posts').delete().eq('id', 'rec_1');
      expect(cap.req.method, 'DELETE');
      expect(cap.req.url.toString(), '$base/posts/rec_1');
      expect(r.data['id'], 'rec_1');
    });

    test(
      'update and delete without an id filter are refused before any request',
      () async {
        final cap = Cap(), core = mk(cap);
        final u = await kerrorOf(
          () => core.from('posts').update({'a': 1}).eq('title', 'x'),
        );
        final d = await kerrorOf(() => core.from('posts').delete());
        expect(u.code, 'K9O_INVALID_FIELD_VALUE');
        expect(u.message, contains("eq('id'"));
        expect(d.code, 'K9O_INVALID_FIELD_VALUE');
        expect(cap.count, 0);
      },
    );

    test('a gateway error surfaces as KError', () async {
      final cap = Cap();
      final core = mk(
        cap,
        status: 404,
        errorBody: {
          'code': 'K9O_NOT_FOUND',
          'message': 'gone',
          'requestId': 'r1',
        },
      );
      final e = await kerrorOf(() => core.from('posts').delete().eq('id', 'x'));
      expect(e.code, 'K9O_NOT_FOUND');
      expect(e.requestId, 'r1');
    });
  });

  group('textSearch and vectorSearch', () {
    test('textSearch wire shape and defaults', () async {
      final cap = Cap();
      await mk(cap, data: [])
          .from('posts')
          .select()
          .textSearch('body', 'ship it')
          .eq('status', 'live');
      expect(cap.req.url.queryParameters, {
        'status': 'eq.live',
        'textSearch': 'body:ship it',
      });
    });

    test('textSearch with language and type', () async {
      final cap = Cap();
      await mk(cap, data: []).from('posts').select().textSearch(
            'body',
            '"a b"',
            language: 'french',
            type: TextSearchType.phrase,
          );
      expect(cap.req.url.queryParameters, {
        'textSearch': 'body:"a b"',
        'textSearchLanguage': 'french',
        'textSearchType': 'phrase',
      });
    });

    test(
      'a later textSearch with defaults clears earlier language and type',
      () async {
        final cap = Cap();
        await mk(cap, data: [])
            .from('posts')
            .select()
            .textSearch(
              'body',
              'a',
              language: 'german',
              type: TextSearchType.phrase,
            )
            .textSearch('body', 'b');
        expect(cap.req.url.queryParameters, {'textSearch': 'body:b'});
      },
    );

    test('vectorSearch POSTs the embedding in a body', () async {
      final cap = Cap();
      await mk(
        cap,
        data: [],
      ).from('docs').select().vectorSearch('embedding', [0.1, 0.2, -3]);
      expect(cap.req.method, 'POST');
      expect(cap.req.url.toString(), '$base/docs/search');
      expect(cap.json, {
        'vectorSearch': {
          'column': 'embedding',
          'vector': [0.1, 0.2, -3],
        },
      });
    });

    test('vectorSearch with filters and paging', () async {
      final cap = Cap();
      await mk(cap, data: [])
          .from('docs')
          .select()
          .vectorSearch('embedding', [1, 2])
          .eq('status', 'open')
          .gt('score', 5)
          .limit(20)
          .count(CountMode.exact);
      expect(cap.req.method, 'POST');
      expect(cap.json, {
        'vectorSearch': {
          'column': 'embedding',
          'vector': [1, 2],
        },
        'filter': {'status': 'eq.open', 'score': 'gt.5'},
        'limit': 20,
        'count': 'exact',
      });
    });

    test('vectorSearch metric and limit', () async {
      final cap = Cap();
      await mk(cap, data: []).from('docs').select().vectorSearch(
            'embedding',
            [1],
            metric: VectorMetric.dot,
            limit: 3,
          );
      expect(cap.json, {
        'vectorSearch': {
          'column': 'embedding',
          'vector': [1],
          'metric': 'dot',
          'limit': 3,
        },
      });
    });

    test('vectorSearch with textSearch is rejected without a request',
        () async {
      final cap = Cap();
      await expectLater(
        mk(cap, data: [])
            .from('docs')
            .select()
            .textSearch('body', 'x')
            .vectorSearch('embedding', [1]),
        throwsA(
          isA<KError>()
              .having((e) => e.code, 'code', 'K9O_INVALID_FIELD_VALUE'),
        ),
      );
      expect(cap.count, 0);
    });

    test('a select without vectorSearch is still a GET', () async {
      final cap = Cap();
      await mk(cap, data: []).from('docs').select().eq('status', 'open');
      expect(cap.req.method, 'GET');
      expect(cap.req.url.path, '/@member-portal/data/docs');
    });

    test('validation errors are K9O_INVALID_FIELD_VALUE', () {
      final s = mk(Cap()).from('docs').select();
      void bad(void Function() f) => expect(
            f,
            throwsA(
              isA<KError>().having(
                (e) => e.code,
                'code',
                'K9O_INVALID_FIELD_VALUE',
              ),
            ),
          );
      bad(() => s.textSearch('1bad', 'x'));
      bad(() => s.textSearch('a-b', 'x'));
      bad(() => s.textSearch('a' * 64, 'x'));
      bad(() => s.textSearch('body', ''));
      bad(() => s.textSearch('body', 'x', language: 'en-us'));
      bad(() => s.vectorSearch('bad col', [1]));
      bad(() => s.vectorSearch('embedding', []));
      bad(() => s.vectorSearch('embedding', [1, double.nan]));
      bad(() => s.vectorSearch('embedding', [1], limit: 0));
      bad(() => s.vectorSearch('embedding', [1], limit: 1001));
    });

    test('limits 1 and 1000 are accepted', () {
      final s = mk(Cap()).from('docs').select();
      s.vectorSearch('embedding', [1], limit: 1);
      s.vectorSearch('embedding', [1], limit: 1000);
    });
  });
}
