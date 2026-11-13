import 'package:k9o_core/k9o_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

const base = '/@member-portal/metadata';

final p1 = <String, dynamic>{
  'surface': 'collection:posts',
  'scope': 'posts',
  'recordId': 'p1',
  'metadata': {
    'title': 'Quarterly report',
    'tags': ['pinned', 'finance'],
    'priority': 3,
    'embedding': '[1,0,0]',
  },
};
final telemetry = <String, dynamic>{
  'surface': 'telemetry:collection.metadata_index_declared',
  'scope': 'collection.metadata_index_declared',
  'eventId': 'aud_1',
  'metadata': {
    'id': 'aud_1',
    'type': 'collection.metadata_index_declared',
    'actorId': 'usr_1',
    'occurredAt': '2026-10-26T20:00:00.000Z',
  },
};

Map<String, dynamic> cursorMeta(String? next) => {
      'requestId': 'r1',
      'cursor': {'next': next},
    };

Future<void> refused(Cap cap, Future<Object?> Function() f,
    [String code = 'K9O_INVALID_FIELD_VALUE']) async {
  expect((await kerrorOf(f)).code, code);
  expect(cap.count, 0);
}

void main() {
  group('metadata.filter', () {
    test(
        'posts surfaces, prefixes fields and returns rows with the next cursor',
        () async {
      final cap = Cap();
      final core = mk(cap, data: [p1], meta: cursorMeta('cur_1'));
      final r = await core.metadata.filter(
        surfaces: ['collection:posts'],
        where: [
          MetadataWhere('priority', MetadataOp.gte, 2),
          MetadataWhere('metadata.title', MetadataOp.startsWith, 'Q'),
        ],
        limit: 1,
        cursor: 'cur_0',
      );
      expect(cap.plain.method, 'POST');
      expect(cap.plain.url.path, '$base/query');
      expect(cap.plain.url.query, '');
      expect(cap.plain.headers['authorization'], 'Bearer tok_abc');
      expect(cap.json, {
        'surfaces': ['collection:posts'],
        'where': [
          {'field': 'metadata.priority', 'op': 'gte', 'value': 2},
          {'field': 'metadata.title', 'op': 'startsWith', 'value': 'Q'},
        ],
        'limit': 1,
        'cursor': 'cur_0',
      });
      expect(r.nextCursor, 'cur_1');
      expect(r.data[0].recordId, 'p1');
      expect(r.data[0].metadata['priority'], 3);
    });

    test('sends only the surfaces by default and reports a null cursor',
        () async {
      final cap = Cap();
      final core = mk(cap, data: [p1, telemetry], meta: cursorMeta(null));
      final r = await core.metadata.filter(surfaces: [
        'collection:posts',
        'telemetry:collection.metadata_index_declared',
      ]);
      expect(cap.json, {
        'surfaces': [
          'collection:posts',
          'telemetry:collection.metadata_index_declared',
        ],
      });
      expect(r.nextCursor, isNull);
      expect(r.data[1].eventId, 'aud_1');
      expect(r.data[1].recordId, isNull);
    });

    test('leaves createdAt and actorId bare on a telemetry surface', () async {
      final cap = Cap();
      final core = mk(cap, data: [telemetry]);
      await core.metadata.filter(surfaces: [
        'telemetry:collection.'
      ], where: [
        MetadataWhere('createdAt', MetadataOp.gt, '2026-10-26T00:00:00Z'),
        MetadataWhere('actorId', MetadataOp.eq, 'usr_1'),
      ]);
      expect(cap.json['where'], [
        {'field': 'createdAt', 'op': 'gt', 'value': '2026-10-26T00:00:00Z'},
        {'field': 'actorId', 'op': 'eq', 'value': 'usr_1'},
      ]);
    });

    test('lets a storage surface through and decodes the 501', () async {
      final cap = Cap();
      final core = mk(cap, status: 501, errorBody: {
        'code': 'K9O_NOT_IMPLEMENTED',
        'message': 'storage metadata is not available',
        'context': {'surface': 'storage:photos'},
      });
      final e = await kerrorOf(
          () => core.metadata.filter(surfaces: ['storage:photos']));
      expect(cap.json, {
        'surfaces': ['storage:photos']
      });
      expect([e.code, e.status, e.context['surface']],
          ['K9O_NOT_IMPLEMENTED', 501, 'storage:photos']);
    });

    test('decodes the 413, the 400 not-indexed answer and the 403', () async {
      final big = mk(Cap(), status: 413, errorBody: {
        'code': 'K9O_QUERY_RESULT_TOO_LARGE',
        'message': 'too many rows',
        'context': {
          'cap': 10000,
          'surfaces': ['collection:posts']
        },
        'recommendation': 'Add where or lower limit.',
      });
      final e413 = await kerrorOf(
          () => big.metadata.filter(surfaces: ['collection:posts']));
      expect([
        e413.code,
        e413.status,
        e413.context['cap'],
        e413.recommendation
      ], [
        'K9O_QUERY_RESULT_TOO_LARGE',
        413,
        10000,
        'Add where or lower limit.'
      ]);

      final nope = mk(Cap(), status: 400, errorBody: {
        'code': 'K9O_METADATA_FIELD_NOT_INDEXED',
        'message': 'not declared',
        'context': {'surface': 'collection:posts', 'field': 'metadata.secret'},
        'recommendation': {'action': 'declare it'},
      });
      final e400 = await kerrorOf(() => nope.metadata.filter(
            surfaces: ['collection:posts'],
            where: [MetadataWhere('secret', MetadataOp.eq, 1)],
          ));
      expect([
        e400.code,
        e400.status,
        e400.context['field'],
        e400.recommendation
      ], [
        'K9O_METADATA_FIELD_NOT_INDEXED',
        400,
        'metadata.secret',
        'declare it'
      ]);

      final denied = mk(Cap(), status: 403, errorBody: {
        'code': 'K9O_EXTENSION_PERMISSION_DENIED',
        'message': 'no grant',
        'context': <String, dynamic>{},
      });
      final e403 = await kerrorOf(
          () => denied.metadata.filter(surfaces: ['collection:posts']));
      expect(
          [e403.code, e403.status], ['K9O_EXTENSION_PERMISSION_DENIED', 403]);
    });

    test('refuses bad input before any request', () async {
      final cap = Cap();
      final m = mk(cap, data: [p1]).metadata;
      await refused(cap, () => m.filter(surfaces: []));
      await refused(
          cap, () => m.filter(surfaces: ['posts']), 'K9O_UNKNOWN_SURFACE');
      await refused(cap, () => m.filter(surfaces: ['table:posts']),
          'K9O_UNKNOWN_SURFACE');
      await refused(cap, () => m.filter(surfaces: ['collection:']),
          'K9O_UNKNOWN_SURFACE');
      await refused(cap, () => m.filter(surfaces: ['collection:1posts']),
          'K9O_UNKNOWN_SURFACE');
      await refused(
          cap,
          () => m.filter(
              surfaces: ['collection:posts', 'telemetry:x'], cursor: 'c'));
      await refused(
          cap, () => m.filter(surfaces: ['collection:posts'], limit: 0));
      await refused(
          cap, () => m.filter(surfaces: ['collection:posts'], limit: 1001));
      await refused(
          cap, () => m.filter(surfaces: ['collection:posts'], cursor: ''));
      await refused(
          cap,
          () => m.filter(
              surfaces: ['collection:posts'],
              where: [MetadataWhere('', MetadataOp.eq, 1)]));
    });

    test('no projectSlug throws K9O_MISSING_PROJECT_CONTEXT', () async {
      final cap = Cap();
      final core = mk(cap, slug: null);
      await refused(
          cap,
          () => core.metadata.filter(surfaces: ['collection:posts']),
          'K9O_MISSING_PROJECT_CONTEXT');
      await refused(cap, () => core.metadata.index.get('posts'),
          'K9O_MISSING_PROJECT_CONTEXT');
    });
  });

  group('metadata.set', () {
    test('patches the record with the bare columns and returns the whole row',
        () async {
      final cap = Cap();
      final row = {
        'id': 'p2',
        'title': 'Team offsite 2027',
        'priority': 9,
        'secret': 's2'
      };
      final core = mk(cap, data: row, meta: {'requestId': 'r2'});
      final r = await core.metadata.set('posts', 'p 2', {
        'title': 'Team offsite 2027',
        'metadata.priority': 9,
      });
      expect(cap.plain.method, 'PATCH');
      expect(cap.plain.url.path, '$base/collection/posts/p%202');
      expect(cap.json, {
        'metadata': {'title': 'Team offsite 2027', 'priority': 9}
      });
      expect(r.data, row);
    });

    test('refuses bad input before any request', () async {
      final cap = Cap();
      final m = mk(cap).metadata;
      await refused(cap, () => m.set('bad-name', 'p1', {'a': 1}));
      await refused(cap, () => m.set('posts', '', {'a': 1}));
      await refused(cap, () => m.set('posts', 'p1', {}));
    });

    test('decodes the not-declared answer', () async {
      final core = mk(Cap(), status: 400, errorBody: {
        'code': 'K9O_METADATA_FIELD_NOT_INDEXED',
        'message': 'x',
        'context': {'field': 'metadata.nope'},
      });
      final e =
          await kerrorOf(() => core.metadata.set('posts', 'p1', {'nope': 1}));
      expect(e.code, 'K9O_METADATA_FIELD_NOT_INDEXED');
    });
  });

  group('metadata.search', () {
    final answer = [
      {
        'surface': 'collection:posts',
        'scope': 'posts',
        'recordId': 'p3',
        'metadata': {'title': 'Budget draft'},
      }
    ];

    test('posts surface, prefixed field, q and limit', () async {
      final cap = Cap();
      final core = mk(cap, data: answer, meta: cursorMeta(null));
      final r = await core.metadata.search(
        surface: 'collection:posts',
        field: 'body',
        q: 'finance',
        limit: 5,
      );
      expect(cap.plain.method, 'POST');
      expect(cap.plain.url.path, '$base/search');
      expect(cap.json, {
        'surface': 'collection:posts',
        'field': 'metadata.body',
        'q': 'finance',
        'limit': 5,
      });
      expect(r.data.map((x) => x.recordId), ['p3']);
      expect(r.nextCursor, isNull);
    });

    test('keeps an existing prefix and omits limit', () async {
      final cap = Cap();
      final core = mk(cap, data: answer);
      await core.metadata
          .search(surface: 'collection:posts', field: 'metadata.body', q: 'x');
      expect(cap.json,
          {'surface': 'collection:posts', 'field': 'metadata.body', 'q': 'x'});
    });

    test('refuses bad input before any request', () async {
      final cap = Cap();
      final m = mk(cap, data: answer).metadata;
      await refused(
          cap, () => m.search(surface: 'telemetry:x', field: 'body', q: 'a'));
      await refused(
          cap, () => m.search(surface: 'storage:b', field: 'body', q: 'a'));
      await refused(
          cap, () => m.search(surface: 'collection:posts', field: '', q: 'a'));
      await refused(cap,
          () => m.search(surface: 'collection:posts', field: 'body', q: ''));
      await refused(
          cap,
          () => m.search(
              surface: 'collection:posts', field: 'body', q: 'a', limit: 2000));
    });

    test('decodes the encrypted-column answer', () async {
      final core = mk(Cap(), status: 400, errorBody: {
        'code': 'K9O_ENCRYPTED_COLUMN_OPERATION_UNSUPPORTED',
        'message': 'x',
        'context': {'column': 'body', 'op': 'textSearch'},
      });
      final e = await kerrorOf(() => core.metadata
          .search(surface: 'collection:posts', field: 'body', q: 'a'));
      expect(e.code, 'K9O_ENCRYPTED_COLUMN_OPERATION_UNSUPPORTED');
    });
  });

  group('metadata.vectors.nearest', () {
    final answer = [
      {
        'surface': 'collection:posts',
        'scope': 'posts',
        'recordId': 'p1',
        'metadata': {'title': 'Quarterly report', 'embedding': '[1,0,0]'},
      }
    ];

    test('posts the prefixed column, the embedding and the options', () async {
      final cap = Cap();
      final core = mk(cap, data: answer, meta: cursorMeta(null));
      final r = await core.metadata.vectors.nearest(
        surface: 'collection:posts',
        column: 'embedding',
        embedding: [1, 0, 0],
        k: 3,
        metric: VectorMetric.dot,
        where: [MetadataWhere('priority', MetadataOp.gt, 1)],
      );
      expect(cap.plain.method, 'POST');
      expect(cap.plain.url.path, '$base/vectors/nearest');
      expect(cap.json, {
        'surface': 'collection:posts',
        'column': 'metadata.embedding',
        'embedding': [1, 0, 0],
        'k': 3,
        'metric': 'dot',
        'where': [
          {'field': 'metadata.priority', 'op': 'gt', 'value': 1}
        ],
      });
      expect(r.data[0].recordId, 'p1');
    });

    test('sends only the required fields by default', () async {
      final cap = Cap();
      final core = mk(cap, data: answer);
      await core.metadata.vectors.nearest(
          surface: 'collection:posts',
          column: 'metadata.embedding',
          embedding: [0.5]);
      expect(cap.json, {
        'surface': 'collection:posts',
        'column': 'metadata.embedding',
        'embedding': [0.5],
      });
    });

    test('refuses bad input before any request', () async {
      final cap = Cap();
      final v = mk(cap, data: answer).metadata.vectors;
      Future<Object?> call(
              {String surface = 'collection:posts',
              String column = 'e',
              List<num> embedding = const [1],
              int? k}) =>
          v.nearest(
              surface: surface, column: column, embedding: embedding, k: k);
      await refused(cap, () => call(embedding: []));
      await refused(cap, () => call(embedding: [1, double.nan]));
      await refused(cap, () => call(embedding: [double.infinity]));
      await refused(cap, () => call(k: 0));
      await refused(cap, () => call(k: 1001));
      await refused(cap, () => call(surface: 'telemetry:x'));
      await refused(cap, () => call(column: ''));
    });
  });

  group('metadata.index', () {
    final index = {
      'collection': 'posts',
      'columns': [
        {'column': 'body', 'indexed': false},
        {'column': 'tags', 'indexed': true},
      ],
    };

    test('gets the declaration', () async {
      final cap = Cap();
      final core = mk(cap, data: index);
      final r = await core.metadata.index.get('posts');
      expect(cap.plain.method, 'GET');
      expect(cap.plain.url.path, '$base/index/posts');
      expect(cap.bodies.last, isEmpty);
      expect(r.data.collection, 'posts');
      expect(r.data.columns[1], const MetadataIndexColumn('tags', true));
    });

    test('declares columns with PUT, an empty list and 64 columns', () async {
      final cap = Cap();
      final core = mk(cap, data: index);
      await core.metadata.index.declare('posts', [
        const MetadataColumn('body'),
        const MetadataColumn('tags', indexed: true),
      ]);
      expect(cap.plain.method, 'PUT');
      expect(cap.plain.url.path, '$base/index/posts');
      expect(cap.json, {
        'columns': [
          {'column': 'body'},
          {'column': 'tags', 'indexed': true},
        ],
      });
      await core.metadata.index.declare('posts', []);
      expect(cap.json, {'columns': <Object?>[]});
      await core.metadata.index.declare(
          'posts', [for (var i = 0; i < 64; i++) MetadataColumn('c$i')]);
      expect((cap.json['columns'] as List).length, 64);
      expect(cap.count, 3);
    });

    test(
        'refuses more than 64 columns, id, repeats and bad names before any request',
        () async {
      final cap = Cap();
      final i = mk(cap, data: index).metadata.index;
      await refused(
          cap,
          () => i.declare(
              'posts', [for (var n = 0; n < 65; n++) MetadataColumn('c$n')]));
      await refused(
          cap, () => i.declare('posts', [const MetadataColumn('id')]));
      await refused(
          cap,
          () => i.declare(
              'posts', [const MetadataColumn('a'), const MetadataColumn('a')]));
      await refused(
          cap, () => i.declare('posts', [const MetadataColumn('a b')]));
      await refused(cap, () => i.declare('bad-name', []));
      await refused(cap, () => i.get('bad-name'));
    });

    test('decodes a missing collection and a refused role', () async {
      final missing = mk(Cap(),
          status: 404,
          errorBody: {'code': 'K9O_COLLECTION_NOT_FOUND', 'message': 'x'});
      expect(
          (await kerrorOf(() => missing.metadata.index.declare('ghost', [])))
              .status,
          404);
      final denied = mk(Cap(),
          status: 403,
          errorBody: {'code': 'K9O_IAM_POLICY_DENIED', 'message': 'x'});
      expect(
          (await kerrorOf(() => denied.metadata.index.declare('posts', [])))
              .code,
          'K9O_IAM_POLICY_DENIED');
    });
  });
}
