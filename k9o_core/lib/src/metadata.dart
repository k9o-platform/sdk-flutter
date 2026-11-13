import 'client.dart';
import 'data.dart' show VectorMetric;
import 'envelope.dart';
import 'kerror.dart';

/// Comparison operators of a `where` clause. [and], [or] and [not] are part of the grammar,
/// but the gateway refuses them today (400 `K9O_INVALID_FIELD_VALUE` on a collection
/// surface, `K9O_METADATA_FIELD_NOT_INDEXED` on telemetry).
enum MetadataOp {
  eq('eq'),
  neq('neq'),
  gt('gt'),
  gte('gte'),
  lt('lt'),
  lte('lte'),
  contains('contains'),
  startsWith('startsWith'),
  endsWith('endsWith'),
  inList('in'),
  notIn('notIn'),
  and('and'),
  or('or'),
  not('not');

  final String wire;
  const MetadataOp(this.wire);
}

/// One condition. On a `collection:` surface [field] is a declared column (`priority` or
/// `metadata.priority`; the prefix is added when it is missing) and each field may appear
/// once. On a `telemetry:` surface the fields are `createdAt` (with [MetadataOp.gt],
/// [MetadataOp.gte], [MetadataOp.lt], [MetadataOp.lte]) and `actorId` (with [MetadataOp.eq]).
class MetadataWhere {
  final String field;
  final MetadataOp op;
  final Object? value;
  const MetadataWhere(this.field, this.op, [this.value]);
}

/// One result row. A `collection:` row has [recordId]; a `telemetry:` row has [eventId].
/// [metadata] holds the declared columns that are present on the row, under their bare
/// names (an undeclared column never appears).
class MetadataRow {
  final String surface;
  final String scope;
  final String? recordId;
  final String? eventId;
  final Map<String, dynamic> metadata;

  const MetadataRow({
    required this.surface,
    required this.scope,
    required this.recordId,
    required this.eventId,
    required this.metadata,
  });

  factory MetadataRow.fromJson(Map<String, dynamic> j) => MetadataRow(
        surface: j['surface'] as String? ?? '',
        scope: j['scope'] as String? ?? '',
        recordId: j['recordId'] as String?,
        eventId: j['eventId'] as String?,
        metadata: (j['metadata'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
}

/// One column to declare. [indexed] defaults to false when null.
class MetadataColumn {
  final String column;
  final bool? indexed;
  const MetadataColumn(this.column, {this.indexed});

  Map<String, dynamic> toJson() => {
        'column': column,
        if (indexed != null) 'indexed': indexed,
      };
}

/// One declared column as the gateway reports it.
class MetadataIndexColumn {
  final String column;
  final bool indexed;
  const MetadataIndexColumn(this.column, this.indexed);

  @override
  bool operator ==(Object other) =>
      other is MetadataIndexColumn &&
      other.column == column &&
      other.indexed == indexed;

  @override
  int get hashCode => Object.hash(column, indexed);
}

/// A collection's declaration: its declared columns, ordered by name.
class MetadataIndex {
  final String collection;
  final List<MetadataIndexColumn> columns;
  const MetadataIndex(this.collection, this.columns);

  factory MetadataIndex.fromJson(Map<String, dynamic> j) => MetadataIndex(
        j['collection'] as String? ?? '',
        [
          for (final c in (j['columns'] as List? ?? const []))
            MetadataIndexColumn(
              (c as Map)['column'] as String? ?? '',
              c['indexed'] as bool? ?? false,
            ),
        ],
      );
}

/// The cursor of the next page of a metadata call (`meta['cursor']['next']`), or null on the last page.
extension MetadataNextCursor<T> on Envelope<T> {
  String? get nextCursor {
    final c = meta['cursor'];
    if (c is Map && c['next'] is String) return c['next'] as String;
    return null;
  }
}

const String _prefix = 'metadata.';
const int _maxColumns = 64;
const int _maxLimit = 1000;
const Set<String> _slices = {'collection', 'telemetry', 'storage'};
final RegExp _scope = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$');
final RegExp _ident = RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]{0,62}$');

/// On a telemetry surface these where fields are sent bare, never prefixed.
const Set<String> _telemetryFields = {'createdAt', 'actorId'};

void _checkSurface(String surface, String name) {
  final at = surface.indexOf(':');
  final slice = at < 0 ? '' : surface.substring(0, at);
  final scope = at < 0 ? '' : surface.substring(at + 1);
  if (!_slices.contains(slice) ||
      !_scope.hasMatch(scope) ||
      (slice == 'collection' && !_ident.hasMatch(scope))) {
    throw KError(
      code: 'K9O_UNKNOWN_SURFACE',
      message:
          '$name "$surface" is not a surface: use collection:<name>, telemetry:<event> or storage:<bucket>',
      context: {'surface': surface},
    );
  }
}

void _checkCollectionSurface(String surface, String name) {
  _checkSurface(surface, name);
  if (!surface.startsWith('collection:')) {
    throw invalidValue(
      '$name must be a collection surface (collection:<name>)',
      {'surface': surface},
    );
  }
}

void _checkLimit(int? value, String name) {
  if (value != null && (value < 1 || value > _maxLimit)) {
    throw invalidValue(
      '$name must be a whole number from 1 to $_maxLimit',
      {name: value},
    );
  }
}

/// The name on the wire: `metadata.<name>`, adding the prefix when it is missing.
String _prefixed(String name, String label) {
  if (name.isEmpty || name == _prefix) {
    throw invalidValue('$label must be a column name', {label: name});
  }
  return name.startsWith(_prefix) ? name : '$_prefix$name';
}

List<Map<String, dynamic>>? _wireWhere(
  List<MetadataWhere>? where, {
  required bool telemetry,
}) {
  if (where == null) return null;
  final out = <Map<String, dynamic>>[];
  for (var i = 0; i < where.length; i++) {
    final c = where[i];
    final bare = telemetry && _telemetryFields.contains(c.field);
    out.add({
      'field': bare ? c.field : _prefixed(c.field, 'where[$i].field'),
      'op': c.op.wire,
      if (c.value != null) 'value': c.value,
    });
  }
  return out;
}

String _collectionName(String collection) {
  if (!_ident.hasMatch(collection)) {
    throw invalidValue('collection must be a collection name', {
      'collection': collection,
    });
  }
  return collection;
}

List<MetadataRow> _rows(Object? data) {
  if (data is! List) throw invalidInternal();
  return [
    for (final r in data)
      MetadataRow.fromJson((r as Map).cast<String, dynamic>()),
  ];
}

Map<String, dynamic> _object(Object? data) {
  if (data is! Map) throw invalidInternal();
  return data.cast<String, dynamic>();
}

/// `core.metadata.*`: columns you declare on a collection (or on another data surface) so
/// they can be filtered, searched and matched by vector through one API, with the same
/// access rules as the data. This client has no `metadata.subscribe`.
///
/// Declare the columns first ([MetadataIndexNamespace.declare]). [set] writes declared
/// columns only; [filter], [search] and [MetadataVectorsNamespace.nearest] read declared
/// columns only. Column names given to [filter] (`where` fields), [search] (`field`) and
/// [MetadataVectorsNamespace.nearest] (`column`) are sent as `metadata.<name>`; the prefix
/// is added when you leave it out. Rows come back with bare column names under `metadata`.
/// Page [filter] with `nextCursor` on the result.
///
/// Errors arrive as [KError] with the gateway's code:
/// - 400 `K9O_UNKNOWN_SURFACE`: the surface is not `collection:<name>`, `telemetry:<event>` or `storage:<bucket>`.
/// - 400 `K9O_METADATA_FIELD_NOT_INDEXED`: the column is not declared.
/// - 400 `K9O_ENCRYPTED_COLUMN_OPERATION_UNSUPPORTED`: an encrypted column takes only `eq` (not null) and `inList`.
/// - 403 `K9O_EXTENSION_PERMISSION_DENIED`: an extension token lacks a grant for the surface.
/// - 413 `K9O_QUERY_RESULT_TOO_LARGE`: more than 10000 rows across the surfaces.
/// - 501 `K9O_NOT_IMPLEMENTED`: `storage:` surfaces are accepted by the client and answered with 501.
class MetadataNamespace {
  final K9oCore _core;
  late final MetadataVectorsNamespace vectors = MetadataVectorsNamespace(_core);
  late final MetadataIndexNamespace index = MetadataIndexNamespace(_core);

  MetadataNamespace(this._core);

  /// POST /@<projectSlug>/metadata/query: rows of one or more [surfaces] whose declared
  /// columns meet [where], in request order. Pages with [cursor] when exactly one surface is
  /// named (`nextCursor` on the result, null on the last page). [limit] is 1 to 1000 per
  /// surface (the gateway defaults to 100). More than 10000 rows answers 413
  /// `K9O_QUERY_RESULT_TOO_LARGE`; a `storage:` surface answers 501 `K9O_NOT_IMPLEMENTED`.
  ///
  /// Invalid input throws [KError] before any request.
  Future<Envelope<List<MetadataRow>>> filter({
    required List<String> surfaces,
    List<MetadataWhere>? where,
    int? limit,
    String? cursor,
  }) {
    _core.requireProjectSlug();
    if (surfaces.isEmpty)
      throw invalidValue('surfaces must be a non-empty list');
    for (var i = 0; i < surfaces.length; i++) {
      _checkSurface(surfaces[i], 'surfaces[$i]');
    }
    _checkLimit(limit, 'limit');
    if (cursor != null) {
      if (cursor.isEmpty) {
        throw invalidValue('cursor must be the cursor of a previous page');
      }
      if (surfaces.length != 1) {
        throw invalidValue(
          'cursor is allowed only with exactly one surface',
          {'field': 'cursor'},
        );
      }
    }
    final wire = _wireWhere(
      where,
      telemetry: surfaces.any((s) => s.startsWith('telemetry:')),
    );
    return _core.send<List<MetadataRow>>(
      'POST',
      'metadata/query',
      body: {
        'surfaces': surfaces,
        if (wire != null) 'where': wire,
        if (limit != null) 'limit': limit,
        if (cursor != null) 'cursor': cursor,
      },
      decode: _rows,
    );
  }

  /// PATCH /@<projectSlug>/metadata/collection/<collection>/<id>: write declared columns of
  /// one record. Keys of [metadata] are bare column names (a leading `metadata.` is dropped);
  /// a column that is not declared answers 400 `K9O_METADATA_FIELD_NOT_INDEXED`. Returns the
  /// whole updated record. The write follows the record API's rules, so a write that needs
  /// approval is queued there.
  ///
  /// Invalid input throws [KError] before any request.
  Future<Envelope<Map<String, dynamic>>> set(
    String collection,
    String id,
    Map<String, Object?> metadata,
  ) {
    final name = _collectionName(collection);
    if (id.isEmpty) throw invalidValue('id must be a record id', {'id': id});
    if (metadata.isEmpty) {
      throw invalidValue('metadata must be a map with at least one column');
    }
    final bare = <String, Object?>{
      for (final e in metadata.entries)
        (e.key.startsWith(_prefix) ? e.key.substring(_prefix.length) : e.key):
            e.value,
    };
    return _core.send<Map<String, dynamic>>(
      'PATCH',
      'metadata/collection/${Uri.encodeComponent(name)}/${Uri.encodeComponent(id)}',
      body: {'metadata': bare},
      decode: _object,
    );
  }

  /// POST /@<projectSlug>/metadata/search: full-text search over one declared text column of
  /// a collection. Matching is by word stem, so "finance" does not match "financial". Returns
  /// the first page only (there is no cursor input) and no rank. [limit] is 1 to 1000 (the
  /// gateway defaults to 50).
  ///
  /// Invalid input throws [KError] before any request.
  Future<Envelope<List<MetadataRow>>> search({
    required String surface,
    required String field,
    required String q,
    int? limit,
  }) {
    _core.requireProjectSlug();
    _checkCollectionSurface(surface, 'surface');
    final wireField = _prefixed(field, 'field');
    if (q.isEmpty) throw invalidValue('q must be a non-empty string');
    _checkLimit(limit, 'limit');
    return _core.send<List<MetadataRow>>(
      'POST',
      'metadata/search',
      body: {
        'surface': surface,
        'field': wireField,
        'q': q,
        if (limit != null) 'limit': limit,
      },
      decode: _rows,
    );
  }
}

/// `core.metadata.vectors.*`.
class MetadataVectorsNamespace {
  final K9oCore _core;
  MetadataVectorsNamespace(this._core);

  /// POST /@<projectSlug>/metadata/vectors/nearest: the rows whose declared vector column is
  /// nearest to [embedding], closest first. Rows carry no score. At most 50 rows come back
  /// whatever [k] is, until the gateway forwards a larger page size. [k] is 1 to 1000 (the
  /// gateway defaults to 10); [metric] defaults to cosine.
  ///
  /// Invalid input throws [KError] before any request.
  Future<Envelope<List<MetadataRow>>> nearest({
    required String surface,
    required String column,
    required List<num> embedding,
    int? k,
    VectorMetric? metric,
    List<MetadataWhere>? where,
  }) {
    _core.requireProjectSlug();
    _checkCollectionSurface(surface, 'surface');
    final wireColumn = _prefixed(column, 'column');
    if (embedding.isEmpty) {
      throw invalidValue('embedding must be a non-empty list of numbers');
    }
    if (embedding.any((n) => !n.isFinite)) {
      throw invalidValue('embedding must contain only finite numbers');
    }
    _checkLimit(k, 'k');
    final wire = _wireWhere(where, telemetry: false);
    return _core.send<List<MetadataRow>>(
      'POST',
      'metadata/vectors/nearest',
      body: {
        'surface': surface,
        'column': wireColumn,
        'embedding': embedding,
        if (k != null) 'k': k,
        if (metric != null) 'metric': metric.name,
        if (wire != null) 'where': wire,
      },
      decode: _rows,
    );
  }
}

/// `core.metadata.index.*`.
class MetadataIndexNamespace {
  final K9oCore _core;
  MetadataIndexNamespace(this._core);

  /// GET /@<projectSlug>/metadata/index/<collection>: the columns declared on a collection,
  /// ordered by name.
  Future<Envelope<MetadataIndex>> get(String collection) {
    final name = _collectionName(collection);
    return _core.send<MetadataIndex>(
      'GET',
      'metadata/index/${Uri.encodeComponent(name)}',
      decode: (d) => MetadataIndex.fromJson(_object(d)),
    );
  }

  /// PUT /@<projectSlug>/metadata/index/<collection>: declare the columns of a collection
  /// that metadata may use. The columns must already exist on the collection. The list
  /// replaces the previous declaration (an empty list clears it); at most 64 columns, no
  /// `id`, no duplicates. Needs the project-admin role and the migrations permission.
  ///
  /// Invalid input throws [KError] before any request.
  Future<Envelope<MetadataIndex>> declare(
    String collection,
    List<MetadataColumn> columns,
  ) {
    final name = _collectionName(collection);
    if (columns.length > _maxColumns) {
      throw invalidValue('at most $_maxColumns columns can be declared', {
        'count': columns.length,
      });
    }
    final seen = <String>{};
    for (var i = 0; i < columns.length; i++) {
      final c = columns[i].column;
      if (!_ident.hasMatch(c) || c == 'id') {
        throw invalidValue(
          'columns[$i].column must be a column name other than id',
          {'column': c},
        );
      }
      if (!seen.add(c)) {
        throw invalidValue('column "$c" is listed twice', {'column': c});
      }
    }
    return _core.send<MetadataIndex>(
      'PUT',
      'metadata/index/${Uri.encodeComponent(name)}',
      body: {
        'columns': [for (final c in columns) c.toJson()],
      },
      decode: (d) => MetadataIndex.fromJson(_object(d)),
    );
  }
}
