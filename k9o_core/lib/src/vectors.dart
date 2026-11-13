import 'client.dart';
import 'data.dart' show VectorMetric;
import 'envelope.dart';
import 'kerror.dart';

const int _maxVector = 16000;
const int _maxRows = 1000;

/// Where a vector came from: a source handle and the index of the chunk within it.
class VectorSource {
  final String handle;
  final int chunkIndex;

  /// Any further keys the source carries.
  final Map<String, dynamic> extra;
  const VectorSource(
    this.handle,
    this.chunkIndex, {
    this.extra = const <String, dynamic>{},
  });

  factory VectorSource.fromJson(Map<String, dynamic> j) {
    final extra = Map<String, dynamic>.of(j)
      ..remove('handle')
      ..remove('chunkIndex');
    return VectorSource(
      j['handle'] as String? ?? '',
      (j['chunkIndex'] as num?)?.toInt() ?? 0,
      extra: extra,
    );
  }

  Map<String, dynamic> toJson() => {
        ...extra,
        'handle': handle,
        'chunkIndex': chunkIndex,
      };
}

/// One row to store with [VectorsNamespace.upsert].
class VectorRow {
  /// 1 to 256 characters. Default: generated. Upserting an existing id overwrites that row.
  final String? id;

  /// 1 to 16000 numbers; every row in one request has the same length.
  final List<num> vector;
  final VectorSource source;

  /// At most 128 characters.
  final String? contentHash;

  /// At most 100000 characters. Stored sealed when the row belongs to a subject.
  final String? text;

  /// Default `{}`. Only keep values here that you filter on; they are stored in plain text.
  final Map<String, dynamic>? metadata;

  /// The one end user the row belongs to (`['eu_...']`). Required on a per-subject
  /// collection (the default for a new collection); refused on a collection declared shared.
  final List<String>? subjectIds;

  const VectorRow({
    this.id,
    required this.vector,
    required this.source,
    this.contentHash,
    this.text,
    this.metadata,
    this.subjectIds,
  });

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'vector': vector,
        '_source': source.toJson(),
        if (contentHash != null) 'contentHash': contentHash,
        if (text != null) 'text': text,
        if (metadata != null) 'metadata': metadata,
        if (subjectIds != null) 'subjectIds': subjectIds,
      };
}

/// One row returned by [VectorsNamespace.nearest].
class NearestVector {
  final String id;

  /// Higher is more similar.
  final double score;
  final VectorSource source;
  final String? contentHash;
  final String? text;
  final Map<String, dynamic> metadata;

  /// From `metadata.model`, when set.
  final String? model;

  /// From `_source.chunkIndex`, when set.
  final int? chunk;

  const NearestVector({
    required this.id,
    required this.score,
    required this.source,
    required this.contentHash,
    required this.text,
    required this.metadata,
    required this.model,
    required this.chunk,
  });

  factory NearestVector.fromJson(Map<String, dynamic> j) => NearestVector(
        id: j['id'] as String,
        score: (j['score'] as num).toDouble(),
        source: VectorSource.fromJson(
          (j['_source'] as Map?)?.cast<String, dynamic>() ?? const {},
        ),
        contentHash: j['contentHash'] as String?,
        text: j['text'] as String?,
        metadata: (j['metadata'] as Map?)?.cast<String, dynamic>() ?? const {},
        model: j['model'] as String?,
        chunk: (j['chunk'] as num?)?.toInt(),
      );
}

/// Result of [VectorsNamespace.nearest].
class NearestVectorsResult {
  /// Closest first.
  final List<NearestVector> results;
  final String collection;
  const NearestVectorsResult(this.results, this.collection);

  factory NearestVectorsResult.fromJson(Map<String, dynamic> j) =>
      NearestVectorsResult([
        for (final r in (j['results'] as List? ?? const []))
          NearestVector.fromJson((r as Map).cast<String, dynamic>()),
      ], j['collection'] as String? ?? '');
}

/// Result of [VectorsNamespace.upsert].
class UpsertVectorsResult {
  final int upserted;
  final String collection;
  const UpsertVectorsResult(this.upserted, this.collection);

  factory UpsertVectorsResult.fromJson(Map<String, dynamic> j) =>
      UpsertVectorsResult(
        (j['upserted'] as num).toInt(),
        j['collection'] as String? ?? '',
      );
}

KError _invalid(String message, [Map<String, dynamic>? context]) => KError(
      code: 'K9O_INVALID_FIELD_VALUE',
      message: message,
      context: context,
    );

void _checkVector(Object? vector, String name) {
  if (vector is! List || vector.isEmpty || vector.length > _maxVector) {
    throw _invalid('$name must be a list of 1 to $_maxVector numbers');
  }
  for (final n in vector) {
    if (n is! num || !n.isFinite) {
      throw _invalid('$name must contain only finite numbers');
    }
  }
}

/// `core.vectors.*`: embeddings you computed yourself, stored next to the text and
/// metadata they came from, and nearest-neighbour search over them.
///
/// Both calls send the vector in the request body, so they take real embeddings of any
/// common size (up to 16000 numbers). A vector collection's name starts with `_`. The first
/// upsert creates the collection and fixes its dimension; every later vector must have the
/// same length. Searching a collection that was never upserted answers 404
/// `K9O_COLLECTION_NOT_FOUND`.
class VectorsNamespace {
  final K9oCore _core;
  VectorsNamespace(this._core);

  String _path(String collection, String tail) {
    if (!collection.startsWith('_')) {
      throw _invalid('a vector collection name must start with _', {
        'collection': collection,
      });
    }
    return 'vectors/${Uri.encodeComponent(collection)}/$tail';
  }

  /// POST /@<projectSlug>/vectors/<collection>/search: the rows nearest to [queryVector],
  /// closest first.
  ///
  /// [topK] is 1 to 1000 (the gateway defaults to 10). [minScore] keeps only results whose
  /// score is at least that. [metric] defaults to cosine. [filters] are equality checks on
  /// `id`, `contentHash`, `source.<key>` and `metadata.<key>`; every one must match.
  /// Null options are omitted from the request.
  ///
  /// Invalid input throws [KError] `K9O_INVALID_FIELD_VALUE` before any request.
  Future<Envelope<NearestVectorsResult>> nearest(
    String collection, {
    required List<num> queryVector,
    int? topK,
    num? minScore,
    VectorMetric? metric,
    Map<String, Object>? filters,
  }) {
    final path = _path(collection, 'search');
    _checkVector(queryVector, 'queryVector');
    if (topK != null && (topK < 1 || topK > 1000)) {
      throw _invalid('topK must be a whole number from 1 to 1000', {
        'topK': topK,
      });
    }
    if (minScore != null && !minScore.isFinite) {
      throw _invalid('minScore must be a number', {'minScore': minScore});
    }
    if (filters != null) {
      for (final v in filters.values) {
        if (v is! String && v is! num && v is! bool) {
          throw _invalid('filter values must be a string, number or boolean');
        }
      }
    }
    final body = <String, dynamic>{
      'queryVector': queryVector,
      if (topK != null) 'topK': topK,
      if (minScore != null) 'minScore': minScore,
      if (metric != null) 'metric': metric.name,
      if (filters != null) 'filters': filters,
    };
    return _core.post(path, body, NearestVectorsResult.fromJson);
  }

  /// POST /@<projectSlug>/vectors/<collection>/upsert: insert or overwrite 1 to 1000 rows in
  /// one request. The first upsert creates the collection.
  ///
  /// Invalid input throws [KError] `K9O_INVALID_FIELD_VALUE` before any request.
  Future<Envelope<UpsertVectorsResult>> upsert(
    String collection,
    List<VectorRow> rows,
  ) {
    final path = _path(collection, 'upsert');
    if (rows.isEmpty || rows.length > _maxRows) {
      throw _invalid('rows must be a list of 1 to $_maxRows rows');
    }
    for (var i = 0; i < rows.length; i++) {
      _checkVector(rows[i].vector, 'rows[$i].vector');
    }
    return _core.post(
        path,
        {
          'rows': [for (final r in rows) r.toJson()],
        },
        UpsertVectorsResult.fromJson);
  }
}
