import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:k9o_core/k9o_core.dart';
import 'package:k9o_core/src/sse.dart';
import 'package:test/test.dart';

import 'helpers.dart';

const base = 'https://acme.api.k9o.io/@member-portal/data-streams/user';

const recordJson = {
  'id': 'pstr_1',
  'slug': 'orders',
  'projectId': 'p1',
  'displayName': 'Orders',
  'subjectPrefix': 'k9o.x.user.pstr_1',
  'region': 'de01',
  'retentionSeconds': 86400,
  'retentionClass': 'standard',
  'maxBytes': 1073741824,
  'status': 'active',
  'createdAt': '2026-10-26T10:00:00.000Z',
  'createdBy': null,
};

String frame(int seq, Object? data, {String extra = ''}) {
  final ev = {
    'sequence': '$seq',
    'subject': 'k9o.x.user.pstr_1._',
    'data': data,
    'publishedAt': '2026-10-26T10:00:00.000Z',
  };
  return '${extra}id: $seq\ndata: ${jsonEncode(ev)}\n\n';
}

http.StreamedResponse sse(String text, {int status = 200}) =>
    http.StreamedResponse(
      Stream.value(utf8.encode(text)),
      status,
      headers: {'content-type': 'text/event-stream'},
    );

void main() {
  group('control plane', () {
    test('create, list, get, delete use the user stream routes', () async {
      final cap = Cap();
      final core = mk(cap, data: recordJson);
      final c = await core.streams.create(
        displayName: 'Orders',
        maxBytes: 1073741824,
      );
      expect('${cap.req.method} ${cap.req.url}', 'POST $base');
      expect(cap.json, {'displayName': 'Orders', 'maxBytes': 1073741824});
      expect(c.data.slug, 'orders');
      expect(c.data.maxBytes, 1073741824);

      await mk(cap, data: [recordJson]).streams.list();
      expect('${cap.req.method} ${cap.req.url}', 'GET $base');

      await core.streams.get('orders');
      expect('${cap.req.method} ${cap.req.url}', 'GET $base/orders');

      final d = await mk(
        cap,
        data: {'slug': 'orders', 'status': 'retired'},
      ).streams.delete('orders');
      expect('${cap.req.method} ${cap.req.url}', 'DELETE $base/orders');
      expect(d.data.status, 'retired');
    });

    test('create sends retentionSeconds when given', () async {
      final cap = Cap();
      await mk(
        cap,
        data: recordJson,
      ).streams.create(displayName: 'O', maxBytes: 1, retentionSeconds: 7200);
      expect(cap.json['retentionSeconds'], 7200);
    });

    test('slugs are URL-encoded', () async {
      final cap = Cap();
      await mk(cap, data: recordJson).streams.get('a b/c');
      expect(cap.req.url.toString(), '$base/a%20b%2Fc');
    });

    test('a missing projectSlug is refused before any request', () async {
      final cap = Cap();
      expect(
        (await kerrorOf(() => mk(cap, slug: null).streams.list())).code,
        'K9O_MISSING_PROJECT_CONTEXT',
      );
      expect(
        () => mk(cap, slug: null).streams.subscribe('orders'),
        throwsA(isA<KError>()),
      );
      expect(cap.count, 0);
    });

    test('stream error codes pass through', () async {
      final cap = Cap();
      final core = mk(
        cap,
        status: 503,
        errorBody: {
          'code': 'K9O_STREAM_UNAVAILABLE',
          'message': 'no data plane',
        },
      );
      final e = await kerrorOf(() => core.streams.list());
      expect(e.code, 'K9O_STREAM_UNAVAILABLE');
      expect(e.status, 503);
      expect(streamErrorCodes, contains('K9O_STREAM_INVALID'));
    });
  });

  group('publish', () {
    test('sends { data, subject } exactly', () async {
      final cap = Cap();
      final r = await mk(
        cap,
        data: {
          'streamSlug': 'orders',
          'subject': 'k9o.x.user.pstr_1.eu',
          'bytes': 12,
          'accepted': true,
        },
        status: 202,
      ).streams.publish('orders', {'id': 1}, subject: 'eu');
      expect('${cap.req.method} ${cap.req.url}', 'POST $base/orders/publish');
      expect(cap.json, {
        'data': {'id': 1},
        'subject': 'eu',
      });
      expect(r.data.accepted, isTrue);
      expect(r.data.bytes, 12);
    });

    test('omits subject when absent and sends null for null data', () async {
      final cap = Cap();
      await mk(
        cap,
        data: {'streamSlug': 'o', 'subject': 's', 'bytes': 1, 'accepted': true},
      ).streams.publish('orders', null);
      expect(cap.json, {'data': null});
    });
  });

  group('replay', () {
    test('sends only the options given and decodes events', () async {
      final cap = Cap();
      final r = await mk(
        cap,
        data: {
          'streamSlug': 'orders',
          'events': [
            {
              'sequence': '5',
              'subject': 's',
              'data': {'a': 1},
              'publishedAt': 't',
            },
          ],
          'nextCursor': '5',
          'hasMore': true,
        },
      ).streams.replay('orders', fromSequence: 4, limit: 100);
      expect('${cap.req.method} ${cap.req.url}', 'POST $base/orders/replay');
      expect(cap.json, {'fromSequence': 4, 'limit': 100});
      expect(r.data.events.single.sequence, '5');
      expect(r.data.events.single.data, {'a': 1});
      expect(r.data.nextCursor, '5');
      expect(r.data.hasMore, isTrue);
    });

    test(
      'an empty call sends an empty body; string sequences are passed as given',
      () async {
        final cap = Cap();
        final core = mk(
          cap,
          data: {
            'streamSlug': 'o',
            'events': [],
            'nextCursor': null,
            'hasMore': false,
          },
        );
        final r = await core.streams.replay('orders');
        expect(cap.json, isEmpty);
        expect(r.data.nextCursor, isNull);
        await core.streams.replay(
          'orders',
          fromSequence: '9',
          untilSequence: '12',
        );
        expect(cap.json, {'fromSequence': '9', 'untilSequence': '12'});
      },
    );

    test('a non int/String sequence is refused', () async {
      final cap = Cap();
      expect(
        (await kerrorOf(() => mk(cap).streams.replay('o', fromSequence: 1.5)))
            .code,
        'K9O_INVALID_FIELD_VALUE',
      );
      expect(cap.count, 0);
    });
  });

  group('subscribe', () {
    test(
      'GETs /subscribe with SSE accept and yields events in order',
      () async {
        final cap = Cap();
        final core = mk(
          cap,
          handler: (req, n) async =>
              sse('retry: 5\n\n${frame(1, 'a')}${frame(2, {'b': 2})}'),
        );
        final events = await core.streams.subscribe('orders').take(2).toList();
        expect(events.map((e) => e.sequence), ['1', '2']);
        expect(events[0].data, 'a');
        expect(events[1].data, {'b': 2});
        expect(events[0].subject, 'k9o.x.user.pstr_1._');
        expect(cap.reqs.first.method, 'GET');
        expect(cap.reqs.first.url.toString(), '$base/orders/subscribe');
        expect(cap.reqs.first.headers['accept'], 'text/event-stream');
        expect(cap.reqs.first.headers['authorization'], 'Bearer tok_abc');
      },
    );

    test('fromSequence is sent; the connection reopens after the last sequence received', () async {
      final cap = Cap();
      final core = mk(
        cap,
        handler: (req, n) async {
          if (n == 1)
            return sse('retry: 5\n\n${frame(7, 'x')}${frame(8, 'y')}');
          return sse(frame(9, 'z'));
        },
      );
      final events = await core.streams
          .subscribe('orders', fromSequence: 6)
          .take(3)
          .toList();
      expect(events.map((e) => e.sequence), ['7', '8', '9']);
      expect(cap.reqs[0].url.queryParameters, {'fromSequence': '6'});
      expect(cap.reqs[1].url.queryParameters, {'fromSequence': '8'});
    });

    test('comments, junk frames and non-event data are skipped', () async {
      final cap = Cap();
      final core = mk(
        cap,
        handler: (req, n) async {
          return sse(
            ': heartbeat\n\nretry: 5\n\ndata: not json\n\ndata: {"no":"data key"}\n\n${frame(1, 'ok')}',
          );
        },
      );
      final events = await core.streams.subscribe('orders').take(1).toList();
      expect(events.single.data, 'ok');
    });

    test(
      'a refused connection arrives as a KError and ends the stream',
      () async {
        final cap = Cap();
        final core = mk(
          cap,
          handler: (req, n) async => http.StreamedResponse(
            Stream.value(
              utf8.encode(
                jsonEncode({
                  'code': 'K9O_STREAM_UNAVAILABLE',
                  'message': 'down',
                }),
              ),
            ),
            503,
          ),
        );
        await expectLater(
          core.streams.subscribe('orders'),
          emitsInOrder([
            emitsError(
              isA<KError>().having(
                (e) => e.code,
                'code',
                'K9O_STREAM_UNAVAILABLE',
              ),
            ),
            emitsDone,
          ]),
        );
        expect(cap.count, 1);
      },
    );

    test('cancelling the subscription stops reconnecting', () async {
      final cap = Cap();
      final core = mk(
        cap,
        handler: (req, n) async => sse('retry: 5\n\n${frame(n, 'e')}'),
      );
      final sub = core.streams.subscribe('orders').listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await sub.cancel();
      final seen = cap.count;
      expect(seen, greaterThan(1));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(cap.count, seen);
    });
  });

  group('SSE parser', () {
    test('assembles id, event, retry and multi-line data across chunks', () {
      final p = SseParser();
      expect(p.add('id: 3\nevent: x\nda'), isEmpty);
      final f = p.add('ta: one\ndata: two\nretry: 250\n\n').single;
      expect(f.id, '3');
      expect(f.event, 'x');
      expect(f.data, 'one\ntwo');
      expect(f.retry, 250);
    });

    test(
      'handles CRLF boundaries and a trailing frame without a blank line',
      () {
        final p = SseParser();
        expect(p.add('data: a\r\n\r\ndata: b').map((f) => f.data), ['a']);
        expect(p.close().map((f) => f.data), ['b']);
      },
    );

    test('an invalid retry value is ignored', () {
      final f = SseParser().add('retry: soon\ndata: x\n\n').single;
      expect(f.retry, isNull);
    });
  });
}
