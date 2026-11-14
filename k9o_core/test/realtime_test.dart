import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:k9o_core/k9o_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

const base = 'https://acme.api.k9o.io/@member-portal/realtime';

http.StreamedResponse sse(String text, {int status = 200}) =>
    http.StreamedResponse(
      Stream.value(utf8.encode(text)),
      status,
      headers: {'content-type': 'text/event-stream'},
    );

String frame(String eventId, Object? payload, {String? id, String? type}) {
  final ev = {
    'topic': 'collections.orders.*',
    'eventType': type ?? 'row_inserted',
    'payload': payload,
    'occurredAt': '2026-11-13T10:00:00.000Z',
    'eventId': eventId,
  };
  return 'id: ${id ?? eventId}\ndata: ${jsonEncode(ev)}\n\n';
}

const retry = 'retry: 5\n\n';

void main() {
  group('replay', () {
    test('POSTs /realtime/replay with only the given fields', () async {
      final cap = Cap();
      final core = mk(
        cap,
        data: {
          'topic': 'audit.project.*',
          'events': [
            {
              'topic': 'audit.project.member.added',
              'eventType': 'member.added',
              'payload': {'who': 'u1'},
              'occurredAt': '2026-11-13T10:00:00.000Z',
              'eventId': 'evt_abc123',
              'sequence': '41',
            },
            {
              'eventType': 'member.removed',
              'payload': null,
              'occurredAt': '2026-11-13T10:01:00.000Z',
              'sequence': 42,
            },
            {'payload': 'no type: dropped'},
          ],
          'nextCursor': 42,
          'hasMore': true,
        },
        meta: {'requestId': 'req_1'},
      );
      final r = await core.realtime.replay(
        'audit.project.*',
        fromSequence: 40,
        untilSequence: '100',
        limit: 2,
        afterAuditEventId: 'evt_Z9',
      );
      expect('${cap.req.method} ${cap.req.url}', 'POST $base/replay');
      expect(cap.json, {
        'topic': 'audit.project.*',
        'fromSequence': 40,
        'untilSequence': '100',
        'limit': 2,
        'afterAuditEventId': 'evt_Z9',
      });
      expect(cap.req.headers['authorization'], 'Bearer tok_abc');
      expect(r.data.topic, 'audit.project.*');
      expect(r.data.events, hasLength(2));
      final a = r.data.events[0];
      expect(a.topic, 'audit.project.member.added');
      expect(a.eventType, 'member.added');
      expect(a.payload, {'who': 'u1'});
      expect(a.occurredAt, '2026-11-13T10:00:00.000Z');
      expect(a.eventId, 'evt_abc123');
      expect(a.sequence, '41');
      final b = r.data.events[1];
      expect(b.topic, 'audit.project.*'); // falls back to the page topic
      expect(b.eventId, isNull);
      expect(b.sequence, '42'); // a number becomes a string
      expect(r.data.nextCursor, '42');
      expect(r.data.hasMore, isTrue);
      expect(r.data.resync, isNull);
    });

    test('a topic without a ledger answers resync and no events', () async {
      final cap = Cap();
      final r = await mk(
        cap,
        data: {
          'topic': 'collections.orders.*',
          'events': [],
          'nextCursor': null,
          'hasMore': false,
          'resync': 'reread-source',
        },
      ).realtime.replay('collections.orders.*');
      expect(cap.json, {'topic': 'collections.orders.*'});
      expect(r.data.events, isEmpty);
      expect(r.data.nextCursor, isNull);
      expect(r.data.hasMore, isFalse);
      expect(r.data.resync, 'reread-source');
    });

    test('a missing body falls back to the requested topic', () async {
      final r = await mk(Cap()).realtime.replay('t.x');
      expect(r.data.topic, 't.x');
      expect(r.data.events, isEmpty);
    });

    test('validation happens before any request', () async {
      final cap = Cap();
      final core = mk(cap);
      Future<void> bad(Future<Object?> Function() f, String field) async {
        final e = await kerrorOf(f);
        expect(e.code, 'K9O_INVALID_FIELD_VALUE');
        expect(e.context['field'], field);
      }

      await bad(() => core.realtime.replay(''), 'topic');
      await bad(() => core.realtime.replay('a' * 201), 'topic');
      await bad(() => core.realtime.replay('t', fromSequence: -1), 'fromSequence');
      await bad(() => core.realtime.replay('t', fromSequence: '1x'), 'fromSequence');
      await bad(() => core.realtime.replay('t', fromSequence: 1.5), 'fromSequence');
      await bad(() => core.realtime.replay('t', untilSequence: -2), 'untilSequence');
      await bad(() => core.realtime.replay('t', limit: 0), 'limit');
      await bad(() => core.realtime.replay('t', limit: 10001), 'limit');
      await bad(
        () => core.realtime.replay('t', afterAuditEventId: 'abc'),
        'afterAuditEventId',
      );
      await bad(
        () => core.realtime.replay('t', afterAuditEventId: 'evt_${'a' * 41}'),
        'afterAuditEventId',
      );
      expect(cap.count, 0);
      // Edges that are valid.
      await core.realtime.replay('a' * 200, limit: 10000, fromSequence: '0');
      expect(cap.count, 1);
    });

    test('needs a project slug', () async {
      final cap = Cap();
      final e = await kerrorOf(() => mk(cap, slug: null).realtime.replay('t'));
      expect(e.code, 'K9O_MISSING_PROJECT_CONTEXT');
      expect(cap.count, 0);
    });

    test('gateway errors pass through', () async {
      final core = mk(
        Cap(),
        status: 403,
        errorBody: {'code': 'K9O_RBAC_DENY', 'message': 'no'},
      );
      final e = await kerrorOf(() => core.realtime.replay('audit.project.*'));
      expect(e.code, 'K9O_RBAC_DENY');
      expect(e.status, 403);
    });
  });

  group('subscribe', () {
    test('GETs /realtime/subscribe with topic and filter, yields events', () async {
      final cap = Cap();
      final core = mk(
        cap,
        handler: (req, n) async =>
            sse('$retry${frame('evt_1', {'id': 1})}${frame('evt_2', {'id': 2}, type: 'row_updated')}'),
      );
      final events = await core.realtime
          .subscribe('collections.orders.*', filter: {'status': 'open'})
          .take(2)
          .toList();
      expect(events.map((e) => e.eventId), ['evt_1', 'evt_2']);
      expect(events[0].topic, 'collections.orders.*');
      expect(events[0].eventType, 'row_inserted');
      expect(events[0].payload, {'id': 1});
      expect(events[0].occurredAt, '2026-11-13T10:00:00.000Z');
      expect(events[1].eventType, 'row_updated');
      final req = cap.reqs.first;
      expect(req.method, 'GET');
      expect(req.url.path, '/@member-portal/realtime/subscribe');
      expect(req.url.queryParameters['topic'], 'collections.orders.*');
      expect(jsonDecode(req.url.queryParameters['filter']!), {'status': 'open'});
      expect(req.headers['accept'], 'text/event-stream');
      expect(req.headers['authorization'], 'Bearer tok_abc');
      expect(req.headers.containsKey('last-event-id'), isFalse);
    });

    test('no filter is sent when none is given', () async {
      final cap = Cap();
      final core = mk(cap, handler: (req, n) async => sse(frame('evt_1', 1)));
      await core.realtime.subscribe('t.x').take(1).toList();
      expect(cap.reqs.first.url.queryParameters, {'topic': 't.x'});
    });

    test('reconnects with Last-Event-ID and drops re-sent events', () async {
      final cap = Cap();
      final core = mk(
        cap,
        handler: (req, n) async {
          if (n == 1) {
            return sse('$retry${frame('evt_1', 'a', id: 'c1')}${frame('evt_2', 'b', id: 'c2')}');
          }
          // The resume's lookback re-sends evt_2.
          return sse('${frame('evt_2', 'b', id: 'c2')}${frame('evt_3', 'c', id: 'c3')}');
        },
      );
      final events = await core.realtime.subscribe('t.x').take(3).toList();
      expect(events.map((e) => e.payload), ['a', 'b', 'c']);
      expect(cap.reqs[0].headers.containsKey('last-event-id'), isFalse);
      expect(cap.reqs[1].headers['last-event-id'], 'c2');
    });

    test('comments, junk frames and non-event data are skipped', () async {
      final core = mk(
        Cap(),
        handler: (req, n) async => sse(
          ': heartbeat\n\n${retry}data: not json\n\ndata: {"no":"type"}\n\ndata: [1]\n\n${frame('evt_1', 'ok')}',
        ),
      );
      final events = await core.realtime.subscribe('t.x').take(1).toList();
      expect(events.single.payload, 'ok');
    });

    test('the SSE id fills in for a missing eventId', () async {
      final core = mk(
        Cap(),
        handler: (req, n) async => sse(
          'id: evt_9\ndata: ${jsonEncode({'eventType': 'x', 'payload': 1, 'occurredAt': 'z'})}\n\n',
        ),
      );
      final e = (await core.realtime.subscribe('t.x').take(1).toList()).single;
      expect(e.eventId, 'evt_9');
      expect(e.topic, 't.x');
    });

    test('a 4xx answer arrives as a KError and ends the stream', () async {
      final cap = Cap();
      final core = mk(
        cap,
        handler: (req, n) async => http.StreamedResponse(
          Stream.value(
            utf8.encode(
              jsonEncode({'code': 'K9O_INVALID_FILTER', 'message': 'bad'}),
            ),
          ),
          400,
        ),
      );
      await expectLater(
        core.realtime.subscribe('t.x'),
        emitsInOrder([
          emitsError(
            isA<KError>().having((e) => e.code, 'code', 'K9O_INVALID_FILTER'),
          ),
          emitsDone,
        ]),
      );
      expect(cap.count, 1);
    });

    test('a 5xx answer is retried', () async {
      final cap = Cap();
      final core = mk(
        cap,
        handler: (req, n) async {
          if (n == 1) {
            return http.StreamedResponse(
              Stream.value(
                utf8.encode(jsonEncode({'code': 'K9O_INTERNAL_ERROR', 'message': 'x'})),
              ),
              503,
            );
          }
          return sse(frame('evt_1', 'late'));
        },
      );
      final events = await core.realtime
          .subscribe('t.x', retryDelay: const Duration(milliseconds: 5))
          .take(1)
          .toList();
      expect(events.single.payload, 'late');
      expect(cap.count, 2);
    });

    test('resync: onResync is called and the feed carries on live', () async {
      final cap = Cap();
      final core = mk(
        cap,
        handler: (req, n) async {
          if (n == 1) {
            return sse(
              '$retry${frame('evt_1', 'a', id: 'c1')}event: resync\ndata: {"reason":"cursor-expired","action":"reread-source"}\n\n',
            );
          }
          return sse(frame('evt_1', 'again', id: 'c9'));
        },
      );
      final seen = <RealtimeResync>[];
      final events = await core.realtime
          .subscribe('t.x', onResync: seen.add)
          .take(2)
          .toList();
      // The id table was cleared, and the fresh connection carries no Last-Event-ID.
      expect(events.map((e) => e.payload), ['a', 'again']);
      expect(seen.single.reason, 'cursor-expired');
      expect(seen.single.action, 'reread-source');
      expect(cap.reqs[1].headers.containsKey('last-event-id'), isFalse);
    });

    test('resync without onResync ends the stream', () async {
      final cap = Cap();
      final core = mk(
        cap,
        handler: (req, n) async => sse(
          '$retry${frame('evt_1', 'a', id: 'c1')}event: resync\ndata: {}\n\n',
        ),
      );
      final events = await core.realtime.subscribe('t.x').toList();
      expect(events.single.payload, 'a');
      expect(cap.count, 1);
    });

    test('a resync that opens a fresh connection only reports the head', () async {
      final core = mk(
        Cap(),
        handler: (req, n) async => sse(
          'event: resync\ndata: {"reason":"head","action":"reread-source"}\n\n${frame('evt_1', 'a')}',
        ),
      );
      var called = false;
      final events = await core.realtime
          .subscribe('t.x', onResync: (_) => called = true)
          .take(1)
          .toList();
      expect(events.single.payload, 'a');
      expect(called, isFalse);
    });

    test('a quiet connection is reopened after the idle timeout', () async {
      final cap = Cap();
      final core = mk(
        cap,
        handler: (req, n) async {
          if (n == 1) {
            // Never sends and never closes.
            return http.StreamedResponse(
              StreamController<List<int>>().stream,
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }
          return sse(frame('evt_1', 'back'));
        },
      );
      final events = await core.realtime
          .subscribe(
            't.x',
            idleTimeout: const Duration(milliseconds: 30),
            retryDelay: const Duration(milliseconds: 5),
          )
          .take(1)
          .toList();
      expect(events.single.payload, 'back');
      expect(cap.count, 2);
    });

    test('the dedupe table is bounded by dedupeMax', () async {
      final core = mk(
        Cap(),
        handler: (req, n) async {
          if (n == 1) {
            return sse('$retry${frame('evt_1', 'a', id: 'c1')}${frame('evt_2', 'b', id: 'c2')}');
          }
          // With dedupeMax 1, evt_1 was forgotten and is delivered again.
          return sse(frame('evt_1', 'a2', id: 'c3'));
        },
      );
      final events = await core.realtime
          .subscribe('t.x', dedupeMax: 1)
          .take(3)
          .toList();
      expect(events.map((e) => e.payload), ['a', 'b', 'a2']);
    });

    test('validation and missing slug throw before any request', () async {
      final cap = Cap();
      expect(() => mk(cap).realtime.subscribe(''), throwsA(isA<KError>()));
      expect(
        () => mk(cap).realtime.subscribe('a' * 201),
        throwsA(isA<KError>()),
      );
      expect(
        () => mk(cap, slug: null).realtime.subscribe('t'),
        throwsA(
          isA<KError>().having((e) => e.code, 'code', 'K9O_MISSING_PROJECT_CONTEXT'),
        ),
      );
      expect(cap.count, 0);
    });

    test('cancelling the subscription stops reconnecting', () async {
      final cap = Cap();
      final core = mk(
        cap,
        handler: (req, n) async => sse('$retry${frame('evt_$n', 'e')}'),
      );
      final sub = core.realtime.subscribe('t.x').listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await sub.cancel();
      final seen = cap.count;
      expect(seen, greaterThan(1));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(cap.count, seen);
    });
  });
}
