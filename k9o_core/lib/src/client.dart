import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai.dart';
import 'data.dart';
import 'envelope.dart';
import 'kerror.dart';
import 'metadata.dart';
import 'query.dart';
import 'rampart.dart';
import 'realtime.dart';
import 'region.dart';
import 'storage.dart';
import 'streams.dart';
import 'vectors.dart';

final RegExp _slugPattern = RegExp(r'^[a-z][a-z0-9-]{1,62}$');

Never _missingBaseUrl() => throw KError(
  code: 'K9O_INVALID_BASE_URL',
  message: 'pass baseUrl or orgSlug',
  context: {'field': 'baseUrl'},
  recommendation:
      'Pass your organization address (https://<orgSlug>.api.k9o.io) as baseUrl, or pass orgSlug.',
);

Never _badOrgSlug(String slug) => throw KError(
  code: 'K9O_INVALID_FIELD_VALUE',
  message:
      'orgSlug "$slug" does not match required format ^[a-z][a-z0-9-]{1,62}\$ (must not end with \'-\')',
  context: {'field': 'orgSlug', 'slug': slug},
  recommendation:
      'Pass a slug of lowercase letters, digits and hyphens; 2-63 chars; starts with a letter; does not end with a hyphen.',
);

/// Project-plane core client.
///
/// ```dart
/// final core = K9oCore(orgSlug: 'acme', projectSlug: 'p', accessToken: t);
/// // or: K9oCore(baseUrl: 'https://acme.api.k9o.io', projectSlug: 'p', accessToken: t);
/// ```
class K9oCore {
  final String baseUrl;
  final String? projectSlug;
  final String? _accessToken;
  final FutureOr<String?> Function()? _tokenProvider;
  final http.Client _http;

  late final AiNamespace ai = AiNamespace(this);

  /// Buckets and objects: `core.storage.from('avatars').upload(...)`.
  late final StorageNamespace storage = StorageNamespace(this);

  /// Bidirectional data streams: create, publish, replay and subscribe.
  late final StreamsNamespace streams = StreamsNamespace(this);

  /// The project change feed: `core.realtime.subscribe(topic)` and `core.realtime.replay(topic)`.
  late final RealtimeNamespace realtime = RealtimeNamespace(this);

  /// Embedding collections: `core.vectors.nearest(...)` searches with a vector in the
  /// request body, `core.vectors.upsert(...)` stores rows.
  late final VectorsNamespace vectors = VectorsNamespace(this);

  /// Declared columns on a collection: `filter`, `set`, `search`, `vectors.nearest`,
  /// `index.get` and `index.declare`.
  late final MetadataNamespace metadata = MetadataNamespace(this);

  /// Rampart: `core.rampart.classify(...)`, `jwks()` and `verifyReceipt(...)`.
  late final RampartNamespace rampart = RampartNamespace(this);

  K9oCore({
    String? baseUrl,
    this.projectSlug,
    String? accessToken,
    FutureOr<String?> Function()? tokenProvider,
    http.Client? httpClient,
    String? orgSlug,
  }) : baseUrl = resolveBaseUrl(
         baseUrl,
         orgSlug,
         onMissing: _missingBaseUrl,
         onBadSlug: _badOrgSlug,
       ),
       _accessToken = accessToken,
       _tokenProvider = tokenProvider,
       _http = httpClient ?? http.Client();

  /// Start a data query on one collection: `core.from('posts').select()`.
  FromBuilder from(String collection) => FromBuilder(this, collection);

  /// Run one read-only SQL statement. See [runQuery] for the parameter rules.
  ///
  /// [params] is a `List` (positional, `$1, $2, ...`) or a `Map` of named values
  /// (`:name` placeholders). `data` is the list of rows.
  Future<Envelope<List<Map<String, dynamic>>>> query(
    String sql, [
    Object? params,
  ]) => runQuery(this, sql, params);

  /// Full-text search over one text column of [collection], best matches first.
  Future<Envelope<List<Map<String, dynamic>>>> search(
    String collection, {
    required String column,
    required String q,
    String? language,
    TextSearchType? type,
    int? limit,
    String? cursor,
  }) async {
    var b = from(collection).select().textSearch(
      column,
      q,
      language: language ?? 'english',
      type: type ?? TextSearchType.plain,
    );
    if (limit != null) b = b.limit(limit);
    if (cursor != null) b = b.cursor(cursor);
    return await b.execute();
  }

  /// Internal: the bound project slug, validated. Throws before any request.
  String requireProjectSlug() {
    final slug = projectSlug;
    if (slug == null || slug.isEmpty) {
      throw KError(
        code: 'K9O_MISSING_PROJECT_CONTEXT',
        message: 'operation requires projectSlug bound on the client',
      );
    }
    if (!_slugPattern.hasMatch(slug) || slug.endsWith('-')) {
      throw KError(
        code: 'K9O_INVALID_FIELD_VALUE',
        message: 'projectSlug does not match the required format',
      );
    }
    return slug;
  }

  Future<String>? _origin;

  /// The origin requests go to: the regional host once learned (one credential-free
  /// probe of a region-free `<org>.api[-staging].<rest>` address), else [baseUrl].
  Future<String> _resolveOrigin() {
    final hit = _origin;
    if (hit != null) return hit;
    final p = probeRegion(_http, baseUrl).then((r) {
      if (!r.cacheable) _origin = null;
      return r.origin;
    });
    return _origin = p;
  }

  Future<Uri> _uri(String path, Map<String, String>? query) async {
    final slug = requireProjectSlug();
    final origin = await _resolveOrigin();
    final uri = Uri.parse('$origin/@$slug/$path');
    return query == null || query.isEmpty
        ? uri
        : uri.replace(queryParameters: query);
  }

  Future<Map<String, String>> _headers({
    required String accept,
    bool json = false,
  }) async {
    final token = _tokenProvider != null
        ? await _tokenProvider!()
        : _accessToken;
    return {
      if (json) 'content-type': 'application/json',
      'accept': accept,
      if (token != null && token.isNotEmpty) 'authorization': 'Bearer $token',
    };
  }

  /// The gateway's request id from the `x-k9o-request-id` response header (any case).
  static String? _headerRequestId(Map<String, String> headers) {
    for (final e in headers.entries) {
      if (e.key.toLowerCase() == 'x-k9o-request-id' && e.value.isNotEmpty) {
        return e.value;
      }
    }
    return null;
  }

  Never _throwFor(int status, String bodyText, Map<String, String> headers) {
    final headerId = _headerRequestId(headers);
    Object? json;
    try {
      json = jsonDecode(bodyText);
    } catch (_) {
      json = null;
    }
    if (json is Map<String, dynamic> && json['code'] is String) {
      final rec = json['recommendation'];
      String? text;
      double? wait;
      if (rec is String) {
        text = rec;
      } else if (rec is Map) {
        final action = rec['action'];
        final note = rec['note'];
        text = action is String ? action : (note is String ? note : null);
        final w = rec['retryAfterSec'];
        if (w is num && w.isFinite && w >= 0) wait = w.toDouble();
      }
      final message = json['message'];
      final context = json['context'];
      final requestId = json['requestId'];
      throw KError(
        code: json['code'] as String,
        message: message is String ? message : '',
        context: context is Map ? context.cast<String, dynamic>() : null,
        recommendation: text,
        status: status,
        requestId: requestId is String ? requestId : headerId,
        retryAfterSec: wait,
      );
    }
    throw KError(
      code: 'K9O_INTERNAL_ERROR',
      message: 'unparseable error response from the gateway',
      status: status,
      requestId: headerId,
    );
  }

  KError _unreachable() => KError(
    // Deliberately drop the cause text: it may echo request details.
    code: 'K9O_UPSTREAM_UNAVAILABLE',
    message: 'the gateway could not be reached',
  );

  Envelope<T> _envelopeFrom<T>(
    http.Response res,
    T Function(Object? data) decode,
  ) {
    if (res.statusCode < 200 || res.statusCode >= 300)
      _throwFor(res.statusCode, res.body, res.headers);
    if (res.statusCode == 204)
      return Envelope<T>(decode(null), <String, dynamic>{});
    Object? json;
    try {
      json = jsonDecode(res.body);
    } catch (_) {
      json = null;
    }
    if (json is! Map<String, dynamic> || !json.containsKey('data')) {
      throw KError(
        code: 'K9O_INTERNAL_ERROR',
        message: 'unparseable success response from the gateway',
        status: res.statusCode,
      );
    }
    final meta =
        (json['meta'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    return Envelope<T>(decode(json['data']), meta);
  }

  /// Internal: send a JSON request under `/@<projectSlug>/` and decode the envelope.
  Future<Envelope<T>> send<T>(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    required T Function(Object? data) decode,
  }) async {
    final uri = await _uri(path, query);
    final headers = await _headers(
      accept: 'application/json',
      json: body != null,
    );
    final http.Response res;
    try {
      final req = http.Request(method, uri)..headers.addAll(headers);
      if (body != null) req.body = jsonEncode(body);
      res = await http.Response.fromStream(await _http.send(req));
    } catch (_) {
      throw _unreachable();
    }
    return _envelopeFrom(res, decode);
  }

  /// Internal: GET a public path that has no project prefix and needs no credentials
  /// (for example `rampart/jwks`) and return the decoded JSON object as it is.
  Future<Map<String, dynamic>> getPublicJson(String path) async {
    final origin = await _resolveOrigin();
    final http.Response res;
    try {
      final req = http.Request('GET', Uri.parse('$origin/$path'))
        ..headers['accept'] = 'application/json';
      res = await http.Response.fromStream(await _http.send(req));
    } catch (_) {
      throw _unreachable();
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      _throwFor(res.statusCode, res.body, res.headers);
    }
    Object? json;
    try {
      json = jsonDecode(res.body);
    } catch (_) {
      json = null;
    }
    if (json is! Map<String, dynamic>) {
      throw KError(
        code: 'K9O_INTERNAL_ERROR',
        message: 'unparseable success response from the gateway',
        status: res.statusCode,
      );
    }
    return json;
  }

  /// Internal: POST a project-plane path and decode the envelope.
  Future<Envelope<T>> post<T>(
    String path,
    Map<String, dynamic> body,
    T Function(Map<String, dynamic>) decode,
  ) {
    return send<T>(
      'POST',
      path,
      body: body,
      decode: (data) {
        if (data is! Map) {
          throw KError(
            code: 'K9O_INTERNAL_ERROR',
            message: 'unparseable success response from the gateway',
          );
        }
        return decode(data.cast<String, dynamic>());
      },
    );
  }

  /// Internal: POST a multipart form (one file part plus text fields).
  Future<Envelope<T>> sendMultipart<T>(
    String path, {
    required Map<String, String> fields,
    required String fileField,
    required List<int> bytes,
    required String filename,
    required T Function(Object? data) decode,
  }) async {
    final uri = await _uri(path, null);
    final headers = await _headers(accept: 'application/json');
    final http.Response res;
    try {
      final req = http.MultipartRequest('POST', uri)
        ..headers.addAll(headers)
        ..fields.addAll(fields)
        ..files.add(
          http.MultipartFile.fromBytes(fileField, bytes, filename: filename),
        );
      res = await http.Response.fromStream(await _http.send(req));
    } catch (_) {
      throw _unreachable();
    }
    return _envelopeFrom(res, decode);
  }

  /// Internal: open a streaming GET (server-sent events). Throws [KError] on a non-2xx answer.
  Future<http.StreamedResponse> openStream(
    String path, {
    Map<String, String>? query,
    Map<String, String>? extraHeaders,
  }) async {
    final uri = await _uri(path, query);
    final headers = await _headers(accept: 'text/event-stream');
    final http.StreamedResponse res;
    try {
      final req = http.Request('GET', uri)
        ..headers.addAll(headers)
        ..headers.addAll(extraHeaders ?? const {});
      res = await _http.send(req);
    } catch (_) {
      throw _unreachable();
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      String text;
      try {
        text = await res.stream.bytesToString();
      } catch (_) {
        text = '';
      }
      _throwFor(res.statusCode, text, res.headers);
    }
    return res;
  }
}

KError invalidValue(String message, [Map<String, dynamic>? context]) =>
    KError(code: 'K9O_INVALID_FIELD_VALUE', message: message, context: context);

KError invalidInternal() => KError(
  code: 'K9O_INTERNAL_ERROR',
  message: 'unparseable success response from the gateway',
);
