import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'client.dart';
import 'envelope.dart';
import 'kerror.dart';
import 'sse.dart';

/// Error codes the stream routes return, besides the common ones.
const List<String> streamErrorCodes = [
  'K9O_STREAM_UNAVAILABLE',
  'K9O_STREAM_INVALID',
  'K9O_STREAM_NOT_FOUND',
  'K9O_STREAM_LIMIT_EXCEEDED',
  'K9O_STREAM_STORAGE_ALLOTMENT_EXCEEDED',
];

const int _defaultReconnectMs = 1000;
const int _maxReconnectMs = 30000;

/// A user stream, as the gateway returns it.
class StreamRecord {
  final String id;
  final String slug;
  final String projectId;
  final String displayName;
  final String subjectPrefix;
  final String region;
  final int retentionSeconds;
  final String retentionClass;
  final int? maxBytes;
  final String status;
  final String createdAt;
  final String? createdBy;

  const StreamRecord({
    required this.id,
    required this.slug,
    required this.projectId,
    required this.displayName,
    required this.subjectPrefix,
    required this.region,
    required this.retentionSeconds,
    required this.retentionClass,
    required this.maxBytes,
    required this.status,
    required this.createdAt,
    required this.createdBy,
  });

  factory StreamRecord.fromJson(Map<String, dynamic> j) => StreamRecord(
    id: j['id'] as String,
    slug: j['slug'] as String,
    projectId: (j['projectId'] as String?) ?? '',
    displayName: (j['displayName'] as String?) ?? '',
    subjectPrefix: (j['subjectPrefix'] as String?) ?? '',
    region: (j['region'] as String?) ?? '',
    retentionSeconds: (j['retentionSeconds'] as num?)?.toInt() ?? 0,
    retentionClass: (j['retentionClass'] as String?) ?? '',
    maxBytes: (j['maxBytes'] as num?)?.toInt(),
    status: (j['status'] as String?) ?? '',
    createdAt: (j['createdAt'] as String?) ?? '',
    createdBy: j['createdBy'] as String?,
  );
}

/// Result of [StreamsNamespace.delete].
class RetiredStream {
  final String slug;
  final String status;
  const RetiredStream(this.slug, this.status);
}

/// Result of [StreamsNamespace.publish].
class PublishResult {
  final String streamSlug;
  final String subject;
  final int bytes;
  final bool accepted;
  const PublishResult(this.streamSlug, this.subject, this.bytes, this.accepted);

  factory PublishResult.fromJson(Map<String, dynamic> j) => PublishResult(
    j['streamSlug'] as String,
    j['subject'] as String,
    (j['bytes'] as num).toInt(),
    j['accepted'] as bool,
  );
}

/// One event on a stream.
class StreamEvent {
  /// The event's position in the stream (a string).
  final String sequence;

  /// The full subject the event was published under.
  final String subject;

  /// The published payload (any JSON value).
  final Object? data;
  final String publishedAt;
  const StreamEvent(this.sequence, this.subject, this.data, this.publishedAt);

  factory StreamEvent.fromJson(Map<String, dynamic> j, {String? sequence}) =>
      StreamEvent(
        sequence ?? (j['sequence'] == null ? '' : j['sequence'].toString()),
        (j['subject'] as String?) ?? '',
        j['data'],
        (j['publishedAt'] as String?) ?? '',
      );
}

/// Result of [StreamsNamespace.replay].
class ReplayResult {
  final String streamSlug;
  final List<StreamEvent> events;

  /// The sequence to pass as `fromSequence` for the next page, or null when the stream is empty.
  final String? nextCursor;

  /// True when the page is full: there may be more events.
  final bool hasMore;
  const ReplayResult(
    this.streamSlug,
    this.events,
    this.nextCursor,
    this.hasMore,
  );

  factory ReplayResult.fromJson(Map<String, dynamic> j) => ReplayResult(
    j['streamSlug'] as String,
    [
      for (final e in (j['events'] as List? ?? const []))
        StreamEvent.fromJson((e as Map).cast<String, dynamic>()),
    ],
    j['nextCursor']?.toString(),
    (j['hasMore'] as bool?) ?? false,
  );
}

Map<String, dynamic> _map(Object? d) {
  if (d is Map) return d.cast<String, dynamic>();
  throw invalidInternal();
}

/// `core.streams`: user data streams (create, publish, replay, subscribe).
///
/// Publishing needs project admin; subscribe and replay need project admin or auditor.
/// `K9O_STREAM_UNAVAILABLE` (503) means the stream data plane is not available in this
/// deployment, `K9O_STREAM_INVALID` means the request was refused (for example a bad subject).
class StreamsNamespace {
  final K9oCore _core;
  StreamsNamespace(this._core);

  String _path(String slug, [String tail = '']) {
    return 'data-streams/user${slug.isEmpty ? '' : '/${Uri.encodeComponent(slug)}'}$tail';
  }

  /// Create a stream. [maxBytes] is the reserved storage ceiling (at least 10 MiB and at most 64 GiB, in steps of 10 MiB up to 1 GiB, 100 MiB up to 10 GiB and 1 GiB up to 64 GiB);
  /// [retentionSeconds] is a whole number of hours in seconds (3600 or more; default 24 hours).
  Future<Envelope<StreamRecord>> create({
    required String displayName,
    required int maxBytes,
    int? retentionSeconds,
  }) async {
    _core.requireProjectSlug();
    return _core.send(
      'POST',
      _path(''),
      body: {
        'displayName': displayName,
        'maxBytes': maxBytes,
        if (retentionSeconds != null) 'retentionSeconds': retentionSeconds,
      },
      decode: (d) => StreamRecord.fromJson(_map(d)),
    );
  }

  /// List the project's active streams.
  Future<Envelope<List<StreamRecord>>> list() async {
    _core.requireProjectSlug();
    return _core.send(
      'GET',
      _path(''),
      decode: (d) {
        if (d is! List) throw invalidInternal();
        return [for (final e in d) StreamRecord.fromJson(_map(e))];
      },
    );
  }

  /// Get a stream by slug.
  Future<Envelope<StreamRecord>> get(String slug) async {
    _core.requireProjectSlug();
    return _core.send(
      'GET',
      _path(slug),
      decode: (d) => StreamRecord.fromJson(_map(d)),
    );
  }

  /// Retire a stream. It reads as absent afterwards.
  Future<Envelope<RetiredStream>> delete(String slug) async {
    _core.requireProjectSlug();
    return _core.send(
      'DELETE',
      _path(slug),
      decode: (d) {
        final m = _map(d);
        return RetiredStream(m['slug'] as String, m['status'] as String);
      },
    );
  }

  /// Append an event. [data] is any JSON value. [subject] is a routing suffix of up to 8
  /// dot-separated tokens of `[a-z0-9_-]`, each 1 to 64 characters.
  Future<Envelope<PublishResult>> publish(
    String slug,
    Object? data, {
    String? subject,
  }) async {
    _core.requireProjectSlug();
    return _core.send(
      'POST',
      _path(slug, '/publish'),
      body: {'data': data, if (subject != null) 'subject': subject},
      decode: (d) => PublishResult.fromJson(_map(d)),
    );
  }

  /// Read a bounded range of events. [fromSequence] is exclusive; [untilSequence] stops there;
  /// [limit] is 1 to 10000 (gateway default 100). Sequences are `int` or `String`.
  Future<Envelope<ReplayResult>> replay(
    String slug, {
    Object? fromSequence,
    Object? untilSequence,
    int? limit,
  }) async {
    _core.requireProjectSlug();
    for (final s in [fromSequence, untilSequence]) {
      if (s != null && s is! int && s is! String) {
        throw invalidValue('a sequence must be an int or a String');
      }
    }
    return _core.send(
      'POST',
      _path(slug, '/replay'),
      body: {
        if (fromSequence != null) 'fromSequence': fromSequence,
        if (untilSequence != null) 'untilSequence': untilSequence,
        if (limit != null) 'limit': limit,
      },
      decode: (d) => ReplayResult.fromJson(_map(d)),
    );
  }

  /// Tail a stream live. The connection reopens by itself from the last sequence received
  /// whenever the server closes it. Cancel the subscription to stop. A refused connection
  /// (for example 503) arrives as a [KError] on the stream and ends it.
  ///
  /// [fromSequence] is exclusive; omit it to start from the beginning of the stream.
  Stream<StreamEvent> subscribe(String slug, {Object? fromSequence}) {
    _core.requireProjectSlug();
    if (fromSequence != null &&
        fromSequence is! int &&
        fromSequence is! String) {
      throw invalidValue('fromSequence must be an int or a String');
    }
    var stopped = false;
    String? cursor = fromSequence?.toString();
    var delay = _defaultReconnectMs;
    StreamSubscription<String>? current;
    Completer<void>? waiting;
    late final StreamController<StreamEvent> ctl;

    void wake() {
      final w = waiting;
      if (w != null && !w.isCompleted) w.complete();
    }

    Future<void> run() async {
      while (!stopped) {
        final http.StreamedResponse? res = await _core
            .openStream(
              _path(slug, '/subscribe'),
              query: cursor == null ? null : {'fromSequence': cursor!},
            )
            .then<http.StreamedResponse?>(
              (r) => r,
              onError: (Object e, StackTrace st) {
                if (!stopped && !ctl.isClosed) ctl.addError(e, st);
                return null;
              },
            );
        if (res == null) break;
        if (stopped) {
          // Cancelled while connecting: drop the connection.
          try {
            await res.stream.listen((_) {}).cancel();
          } catch (_) {}
          break;
        }
        final parser = SseParser();
        final done = Completer<void>();
        waiting = done;
        void handle(SseFrame frame) {
          if (frame.retry != null) {
            delay = frame.retry! < _maxReconnectMs
                ? frame.retry!
                : _maxReconnectMs;
          }
          final text = frame.data;
          if (text == null) return;
          Object? parsed;
          try {
            parsed = jsonDecode(text);
          } catch (_) {
            return;
          }
          if (parsed is! Map || !parsed.containsKey('data')) return;
          final m = parsed.cast<String, dynamic>();
          final seq =
              frame.id ??
              (m['sequence'] == null ? null : m['sequence'].toString());
          if (seq != null) cursor = seq;
          if (!ctl.isClosed)
            ctl.add(StreamEvent.fromJson(m, sequence: seq ?? ''));
        }

        current = res.stream
            .transform(utf8.decoder)
            .listen(
              (chunk) {
                for (final f in parser.add(chunk)) {
                  handle(f);
                }
              },
              onDone: () {
                for (final f in parser.close()) {
                  handle(f);
                }
                if (!done.isCompleted) done.complete();
              },
              // A break in the connection is treated like the server closing it.
              onError: (Object _) {
                if (!done.isCompleted) done.complete();
              },
              cancelOnError: true,
            );
        await done.future;
        current = null;
        if (stopped) break;
        final pause = Completer<void>();
        waiting = pause;
        final timer = Timer(Duration(milliseconds: delay), () {
          if (!pause.isCompleted) pause.complete();
        });
        await pause.future;
        timer.cancel();
      }
      if (!ctl.isClosed) await ctl.close();
    }

    ctl = StreamController<StreamEvent>(
      onListen: () {
        run();
      },
      onCancel: () async {
        stopped = true;
        final c = current;
        current = null;
        wake();
        if (c != null) await c.cancel();
      },
    );
    return ctl.stream;
  }
}
