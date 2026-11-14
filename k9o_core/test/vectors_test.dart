import 'package:k9o_core/k9o_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

const searchPath = '/@member-portal/vectors/_vec_example/search';
const upsertPath = '/@member-portal/vectors/_vec_example/upsert';

Map<String, dynamic> hit(String id, num score) => {
      'id': id,
      'score': score,
      '_source': {'handle': 'probe', 'chunkIndex': 0},
      'contentHash': null,
      'text': null,
      'metadata': <String, dynamic>{},
      'model': null,
      'chunk': 0,
    };

void main() {
  group('vectors.nearest', () {
    test('posts the vector in the body and decodes results closest first',
        () async {
      final cap = Cap();
      final core = mk(
        cap,
        data: {
          'results': [hit('p1', 1), hit('p2', 0.8)],
          'collection': '_vec_example',
        },
      );
      final r = await core.vectors.nearest(
        '_vec_example',
        queryVector: [1, 0, 0],
        topK: 2,
        minScore: 0.5,
        metric: VectorMetric.dot,
        filters: {'metadata.lang': 'en'},
      );
      expect(cap.plain.method, 'POST');
      expect(cap.plain.url.path, searchPath);
      expect(cap.plain.url.query, '');
      expect(cap.json, {
        'queryVector': [1, 0, 0],
        'topK': 2,
        'minScore': 0.5,
        'metric': 'dot',
        'filters': {'metadata.lang': 'en'},
      });
      expect(r.data.collection, '_vec_example');
      expect(r.data.results.map((x) => x.id), ['p1', 'p2']);
      expect(r.data.results[1].score, 0.8);
      expect(r.data.results[0].contentHash, isNull);
      expect(r.data.results[0].text, isNull);
      expect(r.data.results[0].model, isNull);
      expect(r.data.results[0].chunk, 0);
      expect(r.data.results[0].source.handle, 'probe');
    });

    test('optional fields are omitted from the body', () async {
      final cap = Cap();
      final core =
          mk(cap, data: {'results': [], 'collection': '_vec_example'});
      await core.vectors.nearest('_vec_example', queryVector: [1, 0, 0]);
      expect(cap.json, {
        'queryVector': [1, 0, 0]
      });
    });

    test('invalid input is refused before any request', () async {
      final cap = Cap();
      final core = mk(cap);
      final calls = <Future<Object?> Function()>[
        () => core.vectors.nearest('notes', queryVector: [1]),
        () => core.vectors.nearest('_x', queryVector: []),
        () => core.vectors.nearest('_x', queryVector: List.filled(16001, 0)),
        () => core.vectors.nearest('_x', queryVector: [1, double.nan]),
        () => core.vectors.nearest('_x', queryVector: [1, double.infinity]),
        () => core.vectors.nearest('_x', queryVector: [1], topK: 0),
        () => core.vectors.nearest('_x', queryVector: [1], topK: 1001),
        () =>
            core.vectors.nearest('_x', queryVector: [1], minScore: double.nan),
      ];
      for (final f in calls) {
        expect((await kerrorOf(f)).code, 'K9O_INVALID_FIELD_VALUE');
      }
      expect(cap.count, 0);
    });

    test('no projectSlug throws K9O_MISSING_PROJECT_CONTEXT', () async {
      final cap = Cap();
      final core = mk(cap, slug: null);
      final e = await kerrorOf(
        () => core.vectors.nearest('_x', queryVector: [1]),
      );
      expect(e.code, 'K9O_MISSING_PROJECT_CONTEXT');
      expect(cap.count, 0);
    });

    test('404 K9O_COLLECTION_NOT_FOUND decodes into a KError', () async {
      final cap = Cap();
      final core = mk(
        cap,
        status: 404,
        errorBody: {
          'code': 'K9O_COLLECTION_NOT_FOUND',
          'message': "derived vector collection '_vec_example' does not exist",
          'context': <String, dynamic>{},
        },
      );
      final e = await kerrorOf(
        () => core.vectors.nearest('_vec_example', queryVector: [1, 0, 0]),
      );
      expect(e.code, 'K9O_COLLECTION_NOT_FOUND');
      expect(e.status, 404);
    });

    test('400 K9O_INVALID_VECTOR_DIMENSION decodes with its context', () async {
      final cap = Cap();
      final core = mk(
        cap,
        status: 400,
        errorBody: {
          'code': 'K9O_INVALID_VECTOR_DIMENSION',
          'message':
              "query vector dimension does not match collection '_vec_example'",
          'context': {'collection': '_vec_example', 'queryDim': 2},
        },
      );
      final e = await kerrorOf(
        () => core.vectors.nearest('_vec_example', queryVector: [1, 0]),
      );
      expect(e.code, 'K9O_INVALID_VECTOR_DIMENSION');
      expect(e.status, 400);
      expect(e.context, {'collection': '_vec_example', 'queryDim': 2});
    });
  });

  group('vectors.upsert', () {
    test('posts the rows and returns the count', () async {
      final cap = Cap();
      final core =
          mk(cap, data: {'upserted': 3, 'collection': '_vec_example'});
      final r = await core.vectors.upsert('_vec_example', [
        VectorRow(
          id: 'p1',
          vector: [1, 0, 0],
          source: VectorSource('probe', 0),
          text: 'x',
          metadata: {'lang': 'en'},
          subjectIds: ['eu_YmGE3Z6nkv5i'],
        ),
        VectorRow(
          vector: [0, 1, 0],
          source: VectorSource('probe', 1),
          contentHash: 'h',
        ),
      ]);
      expect(cap.plain.method, 'POST');
      expect(cap.plain.url.path, upsertPath);
      expect(cap.json, {
        'rows': [
          {
            'id': 'p1',
            'vector': [1, 0, 0],
            '_source': {'handle': 'probe', 'chunkIndex': 0},
            'text': 'x',
            'metadata': {'lang': 'en'},
            'subjectIds': ['eu_YmGE3Z6nkv5i'],
          },
          {
            'vector': [0, 1, 0],
            '_source': {'handle': 'probe', 'chunkIndex': 1},
            'contentHash': 'h',
          },
        ],
      });
      expect(r.data.upserted, 3);
      expect(r.data.collection, '_vec_example');
    });

    test('invalid input is refused before any request', () async {
      final cap = Cap();
      final core = mk(cap);
      final src = VectorSource('h', 0);
      final calls = <Future<Object?> Function()>[
        () => core.vectors.upsert('notes', [
              VectorRow(vector: [1], source: src)
            ]),
        () => core.vectors.upsert('_x', []),
        () => core.vectors.upsert(
              '_x',
              List.filled(1001, VectorRow(vector: [1], source: src)),
            ),
        () => core.vectors.upsert('_x', [VectorRow(vector: [], source: src)]),
        () => core.vectors.upsert('_x', [
              VectorRow(vector: [double.nan], source: src),
            ]),
      ];
      for (final f in calls) {
        expect((await kerrorOf(f)).code, 'K9O_INVALID_FIELD_VALUE');
      }
      expect(cap.count, 0);
    });

    test('400 K9O_INVALID_VECTOR_DIMENSION decodes into a KError', () async {
      final cap = Cap();
      final core = mk(
        cap,
        status: 400,
        errorBody: {
          'code': 'K9O_INVALID_VECTOR_DIMENSION',
          'message': 'rows differ in length',
          'context': {'index': 1, 'expected': 3, 'got': 2},
        },
      );
      final e = await kerrorOf(
        () => core.vectors.upsert('_x', [
          VectorRow(vector: [1, 2, 3], source: VectorSource('h', 0)),
        ]),
      );
      expect(e.code, 'K9O_INVALID_VECTOR_DIMENSION');
      expect(e.status, 400);
    });
  });
}
