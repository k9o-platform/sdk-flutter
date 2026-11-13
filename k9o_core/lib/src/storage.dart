import 'dart:convert';

import 'client.dart';
import 'envelope.dart';
import 'kerror.dart';

const int _maxExpiresIn = 604800;

/// A bucket.
class StorageBucket {
  final String name;
  final bool public;

  /// Bytes; null means no limit.
  final int? fileSizeLimit;

  /// MIME allow-list; empty means any.
  final List<String> allowedMimeTypes;
  final bool versioning;
  final int? deleteAfterDays;
  final String createdAt;
  final String updatedAt;

  /// Platform-owned buckets cannot be written through the public routes.
  final bool system;

  /// The storage location the bucket is linked to, or null for platform-managed storage.
  final String? byosBindingId;

  const StorageBucket({
    required this.name,
    required this.public,
    required this.fileSizeLimit,
    required this.allowedMimeTypes,
    required this.versioning,
    required this.deleteAfterDays,
    required this.createdAt,
    required this.updatedAt,
    required this.system,
    required this.byosBindingId,
  });

  factory StorageBucket.fromJson(Map<String, dynamic> j) => StorageBucket(
    name: j['name'] as String,
    public: (j['public'] as bool?) ?? false,
    fileSizeLimit: (j['fileSizeLimit'] as num?)?.toInt(),
    allowedMimeTypes: [
      for (final m in (j['allowedMimeTypes'] as List? ?? const [])) m as String,
    ],
    versioning: (j['versioning'] as bool?) ?? false,
    deleteAfterDays: (j['deleteAfterDays'] as num?)?.toInt(),
    createdAt: (j['createdAt'] as String?) ?? '',
    updatedAt: (j['updatedAt'] as String?) ?? '',
    system: (j['system'] as bool?) ?? false,
    byosBindingId: j['byosBindingId'] as String?,
  );
}

/// An object listing entry. [path] is relative to the bucket.
class StorageObject {
  final String path;
  final int size;
  final String? lastModified;
  const StorageObject(this.path, this.size, this.lastModified);

  factory StorageObject.fromJson(Map<String, dynamic> j) => StorageObject(
    j['path'] as String,
    (j['size'] as num).toInt(),
    j['lastModified'] as String?,
  );
}

/// A pre-authenticated download URL. [expiresIn] is the lifetime the gateway used (at most 900 seconds).
class SignedUrl {
  final String signedUrl;
  final int expiresIn;
  const SignedUrl(this.signedUrl, this.expiresIn);

  factory SignedUrl.fromJson(Map<String, dynamic> j) =>
      SignedUrl(j['signedUrl'] as String, (j['expiresIn'] as num).toInt());
}

class RemovedObject {
  final String bucket;
  final String path;
  final bool deleted;
  const RemovedObject(this.bucket, this.path, this.deleted);

  factory RemovedObject.fromJson(Map<String, dynamic> j) => RemovedObject(
    j['bucket'] as String,
    j['path'] as String,
    j['deleted'] as bool,
  );
}

class DeletedBucket {
  final String name;
  final bool deleted;
  final int objectsDeleted;
  const DeletedBucket(this.name, this.deleted, this.objectsDeleted);

  factory DeletedBucket.fromJson(Map<String, dynamic> j) => DeletedBucket(
    j['name'] as String,
    j['deleted'] as bool,
    (j['objectsDeleted'] as num).toInt(),
  );
}

Map<String, dynamic> _map(Object? d) {
  if (d is Map) return d.cast<String, dynamic>();
  throw invalidInternal();
}

List<T> _list<T>(Object? d, T Function(Map<String, dynamic>) f) {
  if (d is! List) throw invalidInternal();
  return [for (final e in d) f((e as Map).cast<String, dynamic>())];
}

String _bucketPath(String name, [String suffix = '']) {
  if (name.isEmpty) {
    throw invalidValue('bucket name must not be empty', {
      'field': 'bucket',
      'reason': 'empty',
    });
  }
  // Dot segments survive percent-encoding and would be collapsed into a different route.
  if (name == '.' || name == '..') {
    throw invalidValue('bucket name must not be a dot segment', {
      'field': 'bucket',
      'reason': 'dot_segment',
    });
  }
  return 'storage/buckets/${Uri.encodeComponent(name)}$suffix';
}

void _requireObjectPath(String path) {
  if (path.isEmpty) {
    throw invalidValue('object path must not be empty', {
      'field': 'path',
      'reason': 'empty',
    });
  }
}

const Set<String> _clearable = {
  'fileSizeLimit',
  'allowedMimeTypes',
  'deleteAfterDays',
  'byosBindingId',
};

/// `core.storage`: buckets and objects.
class StorageNamespace {
  final K9oCore _core;
  StorageNamespace(this._core);

  /// List the project's buckets.
  Future<Envelope<List<StorageBucket>>> listBuckets() async {
    _core.requireProjectSlug();
    return _core.send(
      'GET',
      'storage/buckets',
      decode: (d) => _list(d, StorageBucket.fromJson),
    );
  }

  /// Read one bucket.
  Future<Envelope<StorageBucket>> getBucket(String name) async {
    final path = _bucketPath(name);
    return _core.send(
      'GET',
      path,
      decode: (d) => StorageBucket.fromJson(_map(d)),
    );
  }

  /// Create a bucket. The name is 3 to 63 lowercase letters, digits and hyphens.
  ///
  /// `public`, `versioning` and `deleteAfterDays` are stored and returned but not enforced yet.
  Future<Envelope<StorageBucket>> createBucket(
    String name, {
    bool? public,
    int? fileSizeLimit,
    List<String>? allowedMimeTypes,
    bool? versioning,
    int? deleteAfterDays,
    String? byosBindingId,
  }) async {
    _core.requireProjectSlug();
    final body = <String, dynamic>{
      'name': name,
      if (public != null) 'public': public,
      if (fileSizeLimit != null) 'fileSizeLimit': fileSizeLimit,
      if (allowedMimeTypes != null) 'allowedMimeTypes': allowedMimeTypes,
      if (versioning != null) 'versioning': versioning,
      if (deleteAfterDays != null) 'deleteAfterDays': deleteAfterDays,
      if (byosBindingId != null) 'byosBindingId': byosBindingId,
    };
    return _core.send(
      'POST',
      'storage/buckets',
      body: body,
      decode: (d) => StorageBucket.fromJson(_map(d)),
    );
  }

  /// Change a bucket. Fields left out are unchanged. Name a field in [clear] to set it to null
  /// (`fileSizeLimit`: no limit, `allowedMimeTypes`: any type, `deleteAfterDays`: never,
  /// `byosBindingId`: unlink the storage location).
  Future<Envelope<StorageBucket>> updateBucket(
    String name, {
    bool? public,
    int? fileSizeLimit,
    List<String>? allowedMimeTypes,
    bool? versioning,
    int? deleteAfterDays,
    String? byosBindingId,
    Set<String> clear = const {},
  }) async {
    final path = _bucketPath(name);
    for (final c in clear) {
      if (!_clearable.contains(c)) {
        throw invalidValue('clear can name only: ${_clearable.join(', ')}', {
          'field': c,
        });
      }
    }
    final body = <String, dynamic>{
      if (public != null) 'public': public,
      if (fileSizeLimit != null) 'fileSizeLimit': fileSizeLimit,
      if (allowedMimeTypes != null) 'allowedMimeTypes': allowedMimeTypes,
      if (versioning != null) 'versioning': versioning,
      if (deleteAfterDays != null) 'deleteAfterDays': deleteAfterDays,
      if (byosBindingId != null) 'byosBindingId': byosBindingId,
      for (final c in clear) c: null,
    };
    return _core.send(
      'PATCH',
      path,
      body: body,
      decode: (d) => StorageBucket.fromJson(_map(d)),
    );
  }

  /// Delete a bucket. A non-empty bucket is refused unless [empty] is true, which deletes its objects first.
  Future<Envelope<DeletedBucket>> deleteBucket(
    String name, {
    bool empty = false,
  }) async {
    final path = _bucketPath(name);
    return _core.send(
      'DELETE',
      path,
      query: empty ? {'empty': 'true'} : null,
      decode: (d) => DeletedBucket.fromJson(_map(d)),
    );
  }

  /// A handle on one bucket for object operations: `core.storage.from('avatars').upload(...)`.
  BucketHandle from(String bucket) => BucketHandle(_core, bucket);
}

/// Object operations on one bucket.
class BucketHandle {
  final K9oCore _core;
  final String bucket;
  BucketHandle(this._core, this.bucket);

  /// Upload bytes (for example `await File(p).readAsBytes()`) as the object at [path].
  ///
  /// [upsert] false (default) refuses to overwrite an existing path (409 `K9O_ALREADY_EXISTS`).
  /// [metadata] holds caller-defined strings: at most 10 keys and 2 KB in total.
  /// The bucket's size and MIME limits are enforced by the gateway.
  Future<Envelope<StorageObject>> upload(
    String path,
    List<int> data, {
    String? contentType,
    bool upsert = false,
    Map<String, String>? metadata,
  }) async {
    _requireObjectPath(path);
    final route = _bucketPath(bucket, '/objects');
    final name = path.split('/').last;
    return _core.sendMultipart(
      route,
      fields: {
        'path': path,
        if (contentType != null) 'contentType': contentType,
        'upsert': upsert ? 'true' : 'false',
        if (metadata != null) 'metadata': jsonEncode(metadata),
      },
      fileField: 'file',
      bytes: data,
      filename: name.isEmpty ? 'file' : name,
      decode: (d) => StorageObject.fromJson(_map(d)),
    );
  }

  /// Upload text (UTF-8) as the object at [path].
  Future<Envelope<StorageObject>> uploadText(
    String path,
    String text, {
    String contentType = 'text/plain',
    bool upsert = false,
    Map<String, String>? metadata,
  }) => upload(
    path,
    utf8.encode(text),
    contentType: contentType,
    upsert: upsert,
    metadata: metadata,
  );

  /// A pre-authenticated GET URL for one object. [expiresIn] is required (1 to 604800 seconds);
  /// the gateway never signs for more than 900 seconds and answers with the lifetime it used.
  Future<Envelope<SignedUrl>> createSignedUrl(
    String path, {
    required int expiresIn,
    bool? download,
  }) async {
    _requireObjectPath(path);
    if (expiresIn < 1 || expiresIn > _maxExpiresIn) {
      throw KError(
        code: 'K9O_INVALID_FIELD_VALUE',
        message:
            'expiresIn is required and must be an integer from 1 to $_maxExpiresIn seconds',
        context: {'field': 'expiresIn', 'reason': 'out_of_range'},
        recommendation:
            'Pass an explicit expiresIn; signed URLs have no default lifetime.',
      );
    }
    final route = _bucketPath(bucket, '/objects/sign');
    return _core.send(
      'POST',
      route,
      body: {
        'path': path,
        'expiresIn': expiresIn,
        if (download != null) 'download': download,
      },
      decode: (d) => SignedUrl.fromJson(_map(d)),
    );
  }

  /// List objects, optionally under a [prefix].
  Future<Envelope<List<StorageObject>>> list({String? prefix}) async {
    final route = _bucketPath(bucket, '/objects');
    return _core.send(
      'GET',
      route,
      query: prefix == null ? null : {'prefix': prefix},
      decode: (d) => _list(d, StorageObject.fromJson),
    );
  }

  /// Delete one object.
  Future<Envelope<RemovedObject>> remove(String path) async {
    _requireObjectPath(path);
    final route = _bucketPath(bucket, '/objects');
    return _core.send(
      'DELETE',
      route,
      query: {'path': path},
      decode: (d) => RemovedObject.fromJson(_map(d)),
    );
  }
}
