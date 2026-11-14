import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'client.dart';
import 'envelope.dart';
import 'kerror.dart';
import 'sse.dart';

const int _defaultReconnectMs = 1000;
const int _maxReconnectMs = 30000;
const int _defaultIdleTimeoutMs = 45000;
const int _defaultDedupeMax = 1000;
const int _replayMaxLimit = 10000;

final RegExp _auditEventId = RegExp(r'^evt_[0-9A-Za-z]{1,40}$');
final RegExp _digits = RegExp(r'^[0-9]+$');

/// One realtime event, as the gateway frames it.
class RealtimeEvent {
  /// The topic the event belongs to.
  final String topic;

  /// The event type within the topic family (for example `row_inserted`).
  final String eventType;

  /// The event's payload (any JSON value).
  final Object? payload;
  final String occurredAt;

  /// The event's id, the same on every gateway replica (`evt_...`). Empty when the frame carries none.
  final String eventId;
  const RealtimeEvent({
    required this.topic,
    required this.eventType,
    required this.payload,
    required this.occurredAt,
    required this.eventId,
  });
}

/// Why the gateway could not resume a feed, from its `resync` frame. Events may have been
/// missed: re-read current state from the data plane.
class RealtimeResync {
  final String reason;
  final String action;
  const RealtimeResync(this.reason, this.action);
}

/// One event from [RealtimeNamespace.replay]: the realtime event shape, plus the ledger's
/// [sequence] (a string, as the gateway sends it). [eventId] is null when the ledger row has none.
class RealtimeReplayEvent {
  final String topic;
  final String eventType;
  final Object? payload;
  final String occurredAt;
  final String? eventId;
  final String? sequence;
  const RealtimeReplayEvent({
    required this.topic,
    required this.eventType,
    required this.payload,
    required this.occurredAt,
    this.eventId,
    this.sequence,
  });
}

/// Result of [RealtimeNamespace.replay].
class RealtimeReplayPage {
  final String topic;
  final List<RealtimeReplayEvent> events;

  /// Where the next call starts (the last event's sequence), or null when there is none.
  final String? nextCursor;

  /// True when more events follow this page.
  final bool hasMore;

  /// `reread-source` when the topic keeps no ledger: read current state from the data plane, then subscribe.
  final String? resync;
  const RealtimeReplayPage({
    required this.topic,
    required this.events,
    required this.nextCursor,
    required this.hasMore,
    this.resync,
  });

  factory RealtimeReplayPage.fromJson(Object? data, String topic) {
    final o = data is Map ? data.cast<String, dynamic>() : <String, dynamic>{};
    final events = <RealtimeReplayEvent>[];
    final raw = o['events'];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map || item['eventType'] is! String) continue;
        final id = item['eventId'];
        final seq = item['sequence'];
        events.add(
          RealtimeReplayEvent(
            topic: item['topic'] is String ? item['topic'] as String : topic,
            eventType: item['eventType'] as String,
            payload: item['payload'],
            occurredAt: item['occurredAt'] is String
                ? item['occurredAt'] as String
                : '',
            eventId: id is String && id.isNotEmpty ? id : null,
            sequence: seq is String || seq is num ? seq.toString() : null,
          ),
        );
      }
    }
    final cursor = o['nextCursor'];
    return RealtimeReplayPage(
      topic: o['topic'] is String ? o['topic'] as String : topic,
      events: events,
      nextCursor: cursor is String || cursor is num ? cursor.toString() : null,
      hasMore: o['hasMore'] == true,
      resync: o['resync'] is String ? o['resync'] as String : null,
    );
  }
}

/// `core.realtime`: the project change feed (subscribe, replay).
///
/// `K9O_INVALID_FILTER` and `K9O_SUBSCRIPTION_LIMIT_EXCEEDED` arrive as [KError].
class RealtimeNamespace {
  final K9oCore _core;
  RealtimeNamespace(this._core);

  static void _checkTopic(String topic, String call) {
    if (topic.isEmpty || topic.length > 200) {
      throw invalidValue(
        'realtime.$call: topic must be a non-empty string of at most 200 characters',
        {'field': 'topic'},
      );
    }
  }

  static void _checkSequence(String name, Object? v) {
    if (v == null) return;
    if (v is int && v >= 0) return;
    if (v is String && _digits.hasMatch(v)) return;
    throw invalidValue(
      'realtime.replay: $name must be a non-negative integer',
      {'field': name},
    );
  }

  /// One call of the topic's ledger catch-up (`POST /@<slug>/realtime/replay`). The answer is
  /// topic, events, nextCursor, hasMore and, when the topic keeps no ledger, `resync`.
  /// Page on with [fromSequence] while `hasMore` is true. [fromSequence] and [untilSequence]
  /// are non-negative `int` or digit `String`; [limit] is 1 to 10000.
  ///
  /// Only `audit.project.*` topics keep a ledger (they need the audit log's access: 403
  /// `K9O_RBAC_DENY` otherwise; an unknown [afterAuditEventId] answers 400 `K9O_INVALID_CURSOR`).
  /// For the other topics the answer has no events and `resync` is `reread-source`.
  Future<Envelope<RealtimeReplayPage>> replay(
    String topic, {
    Object? fromSequence,
    Object? untilSequence,
    int? limit,
    String? afterAuditEventId,
  }) async {
    _core.requireProjectSlug();
    _checkTopic(topic, 'replay');
    _checkSequence('fromSequence', fromSequence);
    _checkSequence('untilSequence', untilSequence);
    if (afterAuditEventId != null &&
        !_auditEventId.hasMatch(afterAuditEventId)) {
      throw invalidValue(
        'realtime.replay: afterAuditEventId must look like evt_ followed by letters and digits',
        {'field': 'afterAuditEventId'},
      );
    }
    if (limit != null && (limit < 1 || limit > _replayMaxLimit)) {
      throw invalidValue(
        'realtime.replay: limit must be an integer from 1 to 10000',
        {'field': 'limit'},
      );
    }
    return _core.send(
      'POST',
      'realtime/replay',
      body: {
        'topic': topic,
        if (fromSequence != null) 'fromSequence': fromSequence,
        if (untilSequence != null) 'untilSequence': untilSequence,
        if (limit != null) 'limit': limit,
        if (afterAuditEventId != null) 'afterAuditEventId': afterAuditEventId,
      },
      decode: (d) => RealtimeReplayPage.fromJson(d, topic),
    );
  }

  /// Subscribe to a topic over SSE (`GET /@<slug>/realtime/subscribe?topic=&filter=<json>`).
  /// The connection reopens by itself with `Last-Event-ID` set to the last event received, and
  /// an event already delivered (by `eventId`) is dropped. Cancel the subscription to stop.
  /// A 4xx answer arrives as a [KError] on the stream and ends it; a 5xx answer or a broken
  /// connection is retried.
  ///
  /// [filter] narrows the topic (row-level access still applies). When the gateway cannot
  /// resume the feed (`resync` frame), events may have been missed: [onResync] is called, you
  /// re-read current state, and the feed carries on live from a fresh connection. Without
  /// [onResync] the stream ends there.
  ///
  /// [retryDelay] is the wait before reconnecting (default: the server's hint, else one
  /// second; it backs off to 30 seconds on repeated failures). [idleTimeout] reconnects when no
  /// bytes arrive for that long (default 45 seconds). [dedupeMax] is how many recent event ids
  /// are remembered (default 1000).
  Stream<RealtimeEvent> subscribe(
    String topic, {
    Map<String, dynamic>? filter,
    FutureOr<void> Function(RealtimeResync resync)? onResync,
    Duration? retryDelay,
    Duration? idleTimeout,
    int? dedupeMax,
  }) {
    _core.requireProjectSlug();
    _checkTopic(topic, 'subscribe');
    final idleMs = idleTimeout?.inMilliseconds ?? _defaultIdleTimeoutMs;
    final baseRetry = retryDelay?.inMilliseconds;
    final maxSeen = dedupeMax ?? _defaultDedupeMax;
    final query = <String, String>{
      'topic': topic,
      if (filter != null) 'filter': jsonEncode(filter),
    };

    var stopped = false;
    String? lastEventId;
    var seen = LinkedHashSet<String>();
    var serverRetry = _defaultReconnectMs;
    var failures = 0;
    StreamSubscription<String>? current;
    Completer<void>? waiting;
    Timer? idle;
    late final StreamController<RealtimeEvent> ctl;

    void wake() {
      final w = waiting;
      if (w != null && !w.isCompleted) w.complete();
    }

    bool firstTime(String id) {
      if (seen.contains(id)) return false;
      seen.add(id);
      if (seen.length > maxSeen) seen.remove(seen.first);
      return true;
    }

    Future<void> run() async {
      while (!stopped) {
        var gotFrame = false;
        var resynced = false;
        var sawData = false;
        http.StreamedResponse? res;
        KError? fatal;
        try {
          res = await _core.openStream(
            'realtime/subscribe',
            query: query,
            extraHeaders: lastEventId == null
                ? null
                : {'last-event-id': lastEventId!},
          );
        } on KError catch (e) {
          final s = e.status;
          // A client error will not get better by asking again.
          if (s != null && s >= 400 && s < 500) fatal = e;
        } catch (_) {
          res = null;
        }
        if (stopped) {
          final r = res;
          if (r != null) {
            try {
              await r.stream.listen((_) {}).cancel();
            } catch (_) {}
          }
          break;
        }
        if (fatal != null) {
          if (!ctl.isClosed) ctl.addError(fatal);
          break;
        }
        if (res != null) {
          final parser = SseParser();
          final done = Completer<void>();
          waiting = done;
          Object? callbackError;
          StackTrace? callbackStack;
          void bump() {
            idle?.cancel();
            idle = Timer(Duration(milliseconds: idleMs), () {
              // Quiet connection: treat it like the server closing it.
              final c = current;
              current = null;
              c?.cancel();
              if (!done.isCompleted) done.complete();
            });
          }

          Future<void> handle(SseFrame frame) async {
            if (frame.retry != null) {
              serverRetry = frame.retry! < _maxReconnectMs
                  ? frame.retry!
                  : _maxReconnectMs;
            }
            if (frame.event == 'resync') {
              // A resync that opens a connection made without Last-Event-ID, before any data
              // frame, only reports the head of the stream: keep reading.
              if (lastEventId == null && !sawData) {
                gotFrame = true;
                failures = 0;
                return;
              }
              gotFrame = true;
              failures = 0;
              resynced = true;
              lastEventId = null;
              seen = LinkedHashSet<String>();
              // The position is lost: with nobody to re-read, the subscription ends here.
              if (onResync != null) {
                var reason = 'cursor-unknown';
                var action = 'reread-source';
                try {
                  final p = frame.data == null ? null : jsonDecode(frame.data!);
                  if (p is Map) {
                    if (p['reason'] is String) reason = p['reason'] as String;
                    if (p['action'] is String) action = p['action'] as String;
                  }
                } catch (_) {}
                try {
                  await onResync(RealtimeResync(reason, action));
                } catch (e, st) {
                  callbackError = e;
                  callbackStack = st;
                }
              }
              if (!done.isCompleted) done.complete();
              return;
            }
            final text = frame.data;
            if (text == null) return;
            sawData = true;
            Object? parsed;
            try {
              parsed = jsonDecode(text);
            } catch (_) {
              return;
            }
            if (parsed is! Map || parsed['eventType'] is! String) return;
            final m = parsed.cast<String, dynamic>();
            final wire = m['eventId'];
            final eventId = wire is String ? wire : (frame.id ?? '');
            gotFrame = true;
            failures = 0;
            // Resume from the SSE id (the cursor the gateway issues); the event's own id is for dedupe only.
            final cursor = frame.id != null && frame.id!.isNotEmpty
                ? frame.id!
                : eventId;
            if (cursor.isNotEmpty) lastEventId = cursor;
            if (eventId.isNotEmpty && !firstTime(eventId)) return;
            if (!ctl.isClosed) {
              ctl.add(
                RealtimeEvent(
                  topic: m['topic'] is String ? m['topic'] as String : topic,
                  eventType: m['eventType'] as String,
                  payload: m['payload'],
                  occurredAt: m['occurredAt'] is String
                      ? m['occurredAt'] as String
                      : '',
                  eventId: eventId,
                ),
              );
            }
          }

          // Frames are handled one at a time, in order, even when onResync is slow.
          var chain = Future<void>.value();
          void enqueue(List<SseFrame> frames) {
            for (final f in frames) {
              chain = chain.then((_) async {
                if (done.isCompleted) return;
                await handle(f);
              });
            }
          }

          bump();
          current = res.stream
              .transform(utf8.decoder)
              .listen(
                (chunk) {
                  bump();
                  enqueue(parser.add(chunk));
                },
                onDone: () {
                  enqueue(parser.close());
                  chain = chain.then((_) {
                    if (!done.isCompleted) done.complete();
                  });
                },
                // A break in the connection is treated like the server closing it.
                onError: (Object _) {
                  chain = chain.then((_) {
                    if (!done.isCompleted) done.complete();
                  });
                },
                cancelOnError: true,
              );
          await done.future;
          idle?.cancel();
          idle = null;
          final c = current;
          current = null;
          if (c != null) {
            try {
              await c.cancel();
            } catch (_) {}
          }
          final err = callbackError;
          if (err != null) {
            if (!ctl.isClosed) ctl.addError(err, callbackStack);
            break;
          }
          if (resynced && onResync == null) break;
        }
        if (stopped) break;
        if (!gotFrame) failures += 1;
        final base = baseRetry ?? serverRetry;
        var wait = base;
        if (!resynced && failures > 0) {
          wait = base * (1 << (failures - 1 > 20 ? 20 : failures - 1));
          if (wait > _maxReconnectMs) wait = _maxReconnectMs;
        }
        final pause = Completer<void>();
        waiting = pause;
        final timer = Timer(Duration(milliseconds: wait), () {
          if (!pause.isCompleted) pause.complete();
        });
        await pause.future;
        timer.cancel();
      }
      if (!ctl.isClosed) await ctl.close();
    }

    ctl = StreamController<RealtimeEvent>(
      onListen: () {
        run();
      },
      onCancel: () async {
        stopped = true;
        idle?.cancel();
        final c = current;
        current = null;
        wake();
        if (c != null) await c.cancel();
      },
    );
    return ctl.stream;
  }
}
