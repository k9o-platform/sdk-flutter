import 'dart:async';

import 'client.dart';
import 'envelope.dart';
import 'kerror.dart';
import 'query.dart';

final RegExp _searchColumn = RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]{0,62}$');
final RegExp _collectionName = RegExp(r'^[a-z][a-z0-9_-]{0,62}$');
final RegExp _languageName = RegExp(r'^[a-zA-Z_]+$');

const Set<String> _filterOps = {
  'eq',
  'neq',
  'gt',
  'gte',
  'lt',
  'lte',
  'in',
  'notIn',
  'like',
  'ilike',
  'is', //
};

/// Total-count behaviour for [SelectBuilder.count].
enum CountMode { none, exact, estimated }

/// Query syntax for [SelectBuilder.textSearch].
enum TextSearchType { plain, phrase, websearch }

/// Distance metric for [SelectBuilder.vectorSearch].
enum VectorMetric { cosine, euclidean, dot }

String _str(Object? v) {
  if (v is double && v.isFinite && v == v.truncateToDouble())
    return v.toInt().toString();
  return v.toString();
}

/// Shared filter, paging and count methods. Awaiting a builder runs it.
abstract class FilterBuilder<S extends FilterBuilder<S, R>, R>
    implements Future<R> {
  final Map<String, String> _filters = {};
  final List<(String, String, Object?)> _filterList = [];
  int? _limit;
  String? _cursor;
  CountMode? _count;

  S get _self => this as S;

  /// Run the request. Awaiting the builder does the same.
  Future<R> execute();

  S _add(String column, String op, Object? value) {
    _filterList.add((column, op, value));
    final val = value is List ? '(${value.map(_str).join(',')})' : _str(value);
    // One filter per column: a later filter on the same column replaces the earlier one.
    _filters[column] = '$op.$val';
    return _self;
  }

  S eq(String column, Object value) => _add(column, 'eq', value);
  S neq(String column, Object value) => _add(column, 'neq', value);
  S gt(String column, Object value) => _add(column, 'gt', value);
  S gte(String column, Object value) => _add(column, 'gte', value);
  S lt(String column, Object value) => _add(column, 'lt', value);
  S lte(String column, Object value) => _add(column, 'lte', value);

  /// `column IN (values)`. (`in` is a reserved word in Dart.)
  S inList(String column, List<Object> values) => _add(column, 'in', values);
  S notIn(String column, List<Object> values) => _add(column, 'notIn', values);
  S like(String column, String pattern) => _add(column, 'like', pattern);
  S ilike(String column, String pattern) => _add(column, 'ilike', pattern);

  /// `column IS value`, where [value] is `'null'`, `'true'` or `'false'`. (`is` is a reserved word in Dart.)
  S isValue(String column, String value) => _add(column, 'is', value);

  /// A filter with an explicit operator: eq, neq, gt, gte, lt, lte, in, notIn, like, ilike or is.
  S filter(String column, String op, Object value) {
    if (!_filterOps.contains(op)) {
      throw invalidValue('filter operator "$op" is not supported', {'op': op});
    }
    return _add(column, op, value);
  }

  /// Page size.
  S limit(int n) {
    _limit = n;
    return _self;
  }

  /// Opaque cursor from a previous response's `meta.cursor.next`.
  S cursor(String opaque) {
    _cursor = opaque;
    return _self;
  }

  /// Total-count behaviour: [CountMode.none] (default) skips the count, `exact` counts, `estimated` is fast and approximate.
  S count(CountMode mode) {
    _count = mode;
    return _self;
  }

  Map<String, String> _toQuery() => {
        ..._filters,
        if (_limit != null) 'limit': '$_limit',
        if (_cursor != null) 'cursor': _cursor!,
        if (_count != null) 'count': _count!.name,
      };

  @override
  Future<T> then<T>(
    FutureOr<T> Function(R value) onValue, {
    Function? onError,
  }) =>
      execute().then(onValue, onError: onError);

  @override
  Future<R> catchError(Function onError, {bool Function(Object error)? test}) =>
      execute().catchError(onError, test: test);

  @override
  Future<R> whenComplete(FutureOr<void> Function() action) =>
      execute().whenComplete(action);

  @override
  Stream<R> asStream() => execute().asStream();

  @override
  Future<R> timeout(Duration timeLimit, {FutureOr<R> Function()? onTimeout}) =>
      execute().timeout(timeLimit, onTimeout: onTimeout);
}

String _collectionPath(K9oCore core, String collection) {
  if (core.projectSlug == null || core.projectSlug!.isEmpty) {
    throw KError(
      code: 'K9O_MISSING_PROJECT_CONTEXT',
      message:
          'data-plane operations require projectSlug to be bound on the client',
      context: {'collection': collection},
    );
  }
  core.requireProjectSlug();
  if (!_collectionName.hasMatch(collection)) {
    throw invalidValue(
      'collection name "$collection" does not match required format',
      {'collection': collection},
    );
  }
  return 'data/$collection';
}

Map<String, dynamic> _recordOf(Object? data) {
  if (data is Map) return data.cast<String, dynamic>();
  if (data == null) return <String, dynamic>{};
  throw invalidInternal();
}

/// A write that was queued for approval instead of applied (HTTP 202): the change as it was proposed.
class QueuedChange {
  /// `apr_<base62>`.
  final String id;

  /// Always `pending_approval`.
  final String status;
  final String collection;

  /// `insert`, `update` or `delete`.
  final String operation;
  final String makerId;

  /// Insert: the record. Update: the patch. Delete: `{}`.
  final Map<String, dynamic> proposedPayload;

  /// The record the change targets; `null` for an insert.
  final String? targetRecordId;

  const QueuedChange({
    required this.id,
    required this.status,
    required this.collection,
    required this.operation,
    required this.makerId,
    required this.proposedPayload,
    required this.targetRecordId,
  });

  factory QueuedChange.fromJson(Map<String, dynamic> json) {
    final payload = json['proposedPayload'];
    return QueuedChange(
      id: json['id'] as String,
      status: json['status'] as String,
      collection: json['collection'] as String,
      operation: json['operation'] as String,
      makerId: json['makerId'] as String,
      proposedPayload: payload is Map
          ? payload.cast<String, dynamic>()
          : <String, dynamic>{},
      targetRecordId: json['targetRecordId'] as String?,
    );
  }
}

/// The answer of a single-record write sent with `requireApproval()`: a [QueuedWrite] when the write waits for
/// approval, an [AppliedWrite] when an `auto_approve` policy applied it at once. Use a `switch` to tell them apart.
sealed class ApprovalGatedWrite {
  const ApprovalGatedWrite();
}

/// The write was queued (HTTP 202); nothing was written to the collection yet.
final class QueuedWrite extends ApprovalGatedWrite {
  final QueuedChange change;

  /// The response `meta`; `meta['approval']['status']` repeats `change.status`.
  final Map<String, dynamic> meta;
  const QueuedWrite(this.change, this.meta);
}

/// The write was applied; [envelope] is the normal answer of the insert, update or delete.
final class AppliedWrite extends ApprovalGatedWrite {
  final Envelope<Map<String, dynamic>> envelope;
  const AppliedWrite(this.envelope);
}

ApprovalGatedWrite _gated(Envelope<Map<String, dynamic>> e) {
  final approval = e.meta['approval'];
  final queued = approval is Map &&
      approval['status'] == 'pending_approval' &&
      e.data['status'] == 'pending_approval';
  return queued
      ? QueuedWrite(QueuedChange.fromJson(e.data), e.meta)
      : AppliedWrite(e);
}

const Map<String, String> _approvalQuery = {'requireApproval': 'true'};

/// A single-record write sent with `requireApproval`. Await it, or call `execute()`.
class ApprovalWrite implements Future<ApprovalGatedWrite> {
  final Future<Envelope<Map<String, dynamic>>> Function() _run;
  ApprovalWrite._(this._run);

  /// Run the request. Awaiting the write does the same.
  Future<ApprovalGatedWrite> execute() async => _gated(await _run());

  @override
  Future<T> then<T>(
    FutureOr<T> Function(ApprovalGatedWrite value) onValue, {
    Function? onError,
  }) =>
      execute().then(onValue, onError: onError);

  @override
  Future<ApprovalGatedWrite> catchError(
    Function onError, {
    bool Function(Object error)? test,
  }) =>
      execute().catchError(onError, test: test);

  @override
  Future<ApprovalGatedWrite> whenComplete(FutureOr<void> Function() action) =>
      execute().whenComplete(action);

  @override
  Stream<ApprovalGatedWrite> asStream() => execute().asStream();

  @override
  Future<ApprovalGatedWrite> timeout(
    Duration timeLimit, {
    FutureOr<ApprovalGatedWrite> Function()? onTimeout,
  }) =>
      execute().timeout(timeLimit, onTimeout: onTimeout);
}

/// An INSERT of one record. Resolves to the stored record.
class InsertBuilder implements Future<Envelope<Map<String, dynamic>>> {
  final K9oCore _core;
  final String _collection;
  final Map<String, Object?> _record;
  InsertBuilder._(this._core, this._collection, this._record);

  Future<Envelope<Map<String, dynamic>>> _send(
      Map<String, String>? query) async {
    final path = _collectionPath(_core, _collection);
    return _core.send<Map<String, dynamic>>(
      'POST',
      path,
      query: query,
      body: _record,
      decode: _recordOf,
    );
  }

  /// Run the request. Awaiting the builder does the same.
  Future<Envelope<Map<String, dynamic>>> execute() => _send(null);

  /// Queue the insert for approval (`?requireApproval=true`). The answer is a [QueuedWrite] (HTTP 202) or, when an
  /// `auto_approve` policy covers the write, an [AppliedWrite].
  ApprovalWrite requireApproval() =>
      ApprovalWrite._(() => _send(_approvalQuery));

  @override
  Future<T> then<T>(
    FutureOr<T> Function(Envelope<Map<String, dynamic>> value) onValue, {
    Function? onError,
  }) =>
      execute().then(onValue, onError: onError);

  @override
  Future<Envelope<Map<String, dynamic>>> catchError(
    Function onError, {
    bool Function(Object error)? test,
  }) =>
      execute().catchError(onError, test: test);

  @override
  Future<Envelope<Map<String, dynamic>>> whenComplete(
    FutureOr<void> Function() action,
  ) =>
      execute().whenComplete(action);

  @override
  Stream<Envelope<Map<String, dynamic>>> asStream() => execute().asStream();

  @override
  Future<Envelope<Map<String, dynamic>>> timeout(
    Duration timeLimit, {
    FutureOr<Envelope<Map<String, dynamic>>> Function()? onTimeout,
  }) =>
      execute().timeout(timeLimit, onTimeout: onTimeout);
}

/// `core.from(collection)`: pick a verb.
class FromBuilder {
  final K9oCore _core;
  final String _collection;
  FromBuilder(this._core, this._collection);

  /// Start a SELECT. Chain filters, then `await` it (or call `execute()`).
  SelectBuilder select() => SelectBuilder._(_core, _collection);

  /// Insert one record. Returns the stored record with its platform-generated `id` and `metadata`.
  /// Call `.requireApproval()` on the result to queue the write instead.
  InsertBuilder insert(Map<String, Object?> record) =>
      InsertBuilder._(_core, _collection, record);

  /// Start an UPDATE. The chain must include `.eq('id', ...)`.
  UpdateBuilder update(Map<String, Object?> patch) =>
      UpdateBuilder._(_core, _collection, patch);

  /// Start a DELETE. The chain must include `.eq('id', ...)`.
  DeleteBuilder delete() => DeleteBuilder._(_core, _collection);
}

/// A SELECT: filters, paging, count, text search and vector search. Resolves to the list of records.
class SelectBuilder
    extends FilterBuilder<SelectBuilder, Envelope<List<Map<String, dynamic>>>> {
  final K9oCore _core;
  final String _collection;
  final Map<String, String> _search = {};
  Map<String, Object?>? _vector;

  SelectBuilder._(this._core, this._collection);

  /// Full-text search over one text column. Composes with filters, `limit` and `cursor`.
  ///
  /// Throws [KError] `K9O_INVALID_FIELD_VALUE` for a bad column, an empty [query] or a bad [language].
  SelectBuilder textSearch(
    String column,
    String query, {
    String language = 'english',
    TextSearchType type = TextSearchType.plain,
  }) {
    if (!_searchColumn.hasMatch(column)) {
      throw invalidValue(
        "textSearch column '$column' is not a valid identifier",
      );
    }
    if (query.isEmpty) throw invalidValue('textSearch query must be non-empty');
    if (!_languageName.hasMatch(language)) {
      throw invalidValue(
        'textSearch language must be a text-search configuration name',
      );
    }
    _search['textSearch'] = '$column:$query';
    if (language != 'english') {
      _search['textSearchLanguage'] = language;
    } else {
      _search.remove('textSearchLanguage');
    }
    if (type != TextSearchType.plain) {
      _search['textSearchType'] = type.name;
    } else {
      _search.remove('textSearchType');
    }
    return this;
  }

  /// Semantic search: the rows nearest to [embedding] in one vector column, closest first.
  ///
  /// [limit] is 1 to 1000 (gateway default 10). The embedding is sent in a request body (`POST .../search`), so a
  /// real embedding fits; it cannot be combined with [textSearch]. The rows returned are the smaller of the page
  /// `limit` (default 50) and this limit, so set both to get N rows.
  SelectBuilder vectorSearch(
    String column,
    List<num> embedding, {
    VectorMetric metric = VectorMetric.cosine,
    int? limit,
  }) {
    if (!_searchColumn.hasMatch(column)) {
      throw invalidValue(
        "vectorSearch column '$column' is not a valid identifier",
      );
    }
    if (embedding.isEmpty || embedding.any((n) => !n.isFinite)) {
      throw invalidValue(
        'vectorSearch embedding must be a non-empty list of numbers',
      );
    }
    if (limit != null && (limit < 1 || limit > 1000)) {
      throw invalidValue(
        'vectorSearch limit must be an integer from 1 to 1000',
      );
    }
    _vector = {
      'column': column,
      'vector': List<num>.of(embedding),
      if (metric != VectorMetric.cosine) 'metric': metric.name,
      if (limit != null) 'limit': limit,
    };
    return this;
  }

  @override
  Future<Envelope<List<Map<String, dynamic>>>> execute() async {
    final path = _collectionPath(_core, _collection);
    final vector = _vector;
    if (vector == null) {
      return _core.send<List<Map<String, dynamic>>>(
        'GET',
        path,
        query: {..._toQuery(), ..._search},
        decode: rowsOf,
      );
    }
    if (_search.containsKey('textSearch')) {
      throw invalidValue(
        'vectorSearch and textSearch cannot be combined on one query',
      );
    }
    final filter = <String, String>{};
    final body = <String, Object?>{'vectorSearch': vector};
    _toQuery().forEach((key, value) {
      switch (key) {
        case 'limit':
          body[key] = int.parse(value);
        case 'select' || 'order' || 'cursor' || 'count' || 'or':
          body[key] = value;
        default:
          filter[key] = value;
      }
    });
    if (filter.isNotEmpty) body['filter'] = filter;
    return _core.send<List<Map<String, dynamic>>>(
      'POST',
      '$path/search',
      body: body,
      decode: rowsOf,
    );
  }
}

String _idFrom(FilterBuilder b, String verb, String collection) {
  for (final f in b._filterList.reversed) {
    if (f.$1 == 'id' && f.$2 == 'eq') return _str(f.$3);
  }
  throw KError(
    code: 'K9O_INVALID_FIELD_VALUE',
    message:
        "$verb() requires an `.eq('id', '...')` filter; ${verb == 'delete' ? 'deleting' : 'changing'} many rows in one call is not supported",
    context: {'collection': collection},
    recommendation:
        "Chain `.eq('id', 'rec_...')` before awaiting; to handle several rows, call once per id.",
  );
}

/// An UPDATE of one record. Resolves to the updated record.
class UpdateBuilder
    extends FilterBuilder<UpdateBuilder, Envelope<Map<String, dynamic>>> {
  final K9oCore _core;
  final String _collection;
  final Map<String, Object?> _patch;
  UpdateBuilder._(this._core, this._collection, this._patch);

  Future<Envelope<Map<String, dynamic>>> _send(
      Map<String, String>? query) async {
    final id = _idFrom(this, 'update', _collection);
    final path = _collectionPath(_core, _collection);
    return _core.send<Map<String, dynamic>>(
      'PATCH',
      '$path/${Uri.encodeComponent(id)}',
      query: query,
      body: _patch,
      decode: _recordOf,
    );
  }

  @override
  Future<Envelope<Map<String, dynamic>>> execute() => _send(null);

  /// Queue the update for approval (`?requireApproval=true`). The answer is a [QueuedWrite] (HTTP 202) or, when an
  /// `auto_approve` policy covers the write, an [AppliedWrite]. Keep the `.eq('id', ...)` in the chain.
  ApprovalWrite requireApproval() =>
      ApprovalWrite._(() => _send(_approvalQuery));
}

/// A DELETE of one record. Resolves to the deleted record.
class DeleteBuilder
    extends FilterBuilder<DeleteBuilder, Envelope<Map<String, dynamic>>> {
  final K9oCore _core;
  final String _collection;
  DeleteBuilder._(this._core, this._collection);

  Future<Envelope<Map<String, dynamic>>> _send(
      Map<String, String>? query) async {
    final id = _idFrom(this, 'delete', _collection);
    final path = _collectionPath(_core, _collection);
    return _core.send<Map<String, dynamic>>(
      'DELETE',
      '$path/${Uri.encodeComponent(id)}',
      query: query,
      decode: _recordOf,
    );
  }

  @override
  Future<Envelope<Map<String, dynamic>>> execute() => _send(null);

  /// Queue the delete for approval (`?requireApproval=true`). The answer is a [QueuedWrite] (HTTP 202) or, when an
  /// `auto_approve` policy covers the write, an [AppliedWrite]. Keep the `.eq('id', ...)` in the chain.
  ApprovalWrite requireApproval() =>
      ApprovalWrite._(() => _send(_approvalQuery));
}
