import 'package:k9o_core/k9o_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

const base = 'https://acme.api.k9o.io/@member-portal/data';

Map<String, dynamic> queuedData(
  String operation,
  String? target,
  Map<String, dynamic> payload,
) =>
    {
      'id': 'apr_5oLshD2MVT27',
      'status': 'pending_approval',
      'collection': 'conformance_kv',
      'operation': operation,
      'makerId': 'usr_conformance0001',
      'proposedPayload': payload,
      'targetRecordId': target,
    };

const queuedMeta = {
  'cost': {},
  'timing': {},
  'context': {'requestId': 'req_1', 'traceId': 'req_1', 'projectId': 'proj_1'},
  'approval': {'status': 'pending_approval'},
};

void main() {
  group('requireApproval', () {
    test('insert sends ?requireApproval=true and decodes the 202 queued change',
        () async {
      final cap = Cap();
      final record = {'id': 'contract2-probe-0001', 'val': 'contract2-probe'};
      final r = await mk(
        cap,
        status: 202,
        data: queuedData('insert', null, record),
        meta: queuedMeta,
      ).from('conformance_kv').insert(record).requireApproval();
      expect(cap.req.method, 'POST');
      expect(
          cap.req.url.toString(), '$base/conformance_kv?requireApproval=true');
      expect(cap.json, record);
      expect(r, isA<QueuedWrite>());
      final q = r as QueuedWrite;
      expect(q.change.id, 'apr_5oLshD2MVT27');
      expect(q.change.status, 'pending_approval');
      expect(q.change.operation, 'insert');
      expect(q.change.collection, 'conformance_kv');
      expect(q.change.makerId, 'usr_conformance0001');
      expect(q.change.proposedPayload, record);
      expect(q.change.targetRecordId, isNull);
      expect((q.meta['approval'] as Map)['status'], 'pending_approval');
    });

    test(
        'insert decodes the applied row when an auto_approve policy applied the write',
        () async {
      final cap = Cap();
      final r = await mk(
        cap,
        status: 201,
        data: {'id': 'r1', 'val': 'x'},
      )
          .from('conformance_kv')
          .insert({'id': 'r1', 'val': 'x'}).requireApproval();
      expect(cap.req.url.query, 'requireApproval=true');
      switch (r) {
        case QueuedWrite():
          fail('expected an applied write');
        case AppliedWrite(:final envelope):
          expect(envelope.data, {'id': 'r1', 'val': 'x'});
      }
    });

    test('update sends the flag and a queued answer carries the target record',
        () async {
      final cap = Cap();
      final r = await mk(
        cap,
        status: 202,
        data: queuedData('update', 'r 1', {'val': 'n'}),
        meta: queuedMeta,
      )
          .from('conformance_kv')
          .update({'val': 'n'})
          .eq('id', 'r 1')
          .requireApproval();
      expect(cap.req.method, 'PATCH');
      expect(cap.req.url.toString(),
          '$base/conformance_kv/r%201?requireApproval=true');
      expect(cap.json, {'val': 'n'});
      final q = r as QueuedWrite;
      expect(q.change.operation, 'update');
      expect(q.change.targetRecordId, 'r 1');
    });

    test('update decodes the applied row', () async {
      final cap = Cap();
      final r = await mk(cap, data: {'id': 'r1', 'val': 'n'})
          .from('conformance_kv')
          .update({'val': 'n'})
          .eq('id', 'r1')
          .requireApproval();
      expect(r, isA<AppliedWrite>());
      expect((r as AppliedWrite).envelope.data['val'], 'n');
    });

    test(
        'delete sends the flag with no body; a queued delete has an empty payload',
        () async {
      final cap = Cap();
      final r = await mk(
        cap,
        status: 202,
        data: queuedData('delete', 'r1', {}),
        meta: queuedMeta,
      ).from('conformance_kv').delete().eq('id', 'r1').requireApproval();
      expect(cap.req.method, 'DELETE');
      expect(cap.req.url.toString(),
          '$base/conformance_kv/r1?requireApproval=true');
      expect(cap.bodyText, isEmpty);
      final q = r as QueuedWrite;
      expect(q.change.operation, 'delete');
      expect(q.change.proposedPayload, isEmpty);
    });

    test('delete decodes the applied answer', () async {
      final cap = Cap();
      final r = await mk(cap, data: {'id': 'r1'})
          .from('conformance_kv')
          .delete()
          .eq('id', 'r1')
          .requireApproval();
      expect(r, isA<AppliedWrite>());
    });

    test('writes without requireApproval() send no query', () async {
      final cap = Cap();
      final core = mk(cap, data: {'id': 'r1'});
      await core.from('conformance_kv').insert({'id': 'r1'});
      await core.from('conformance_kv').update({'a': 1}).eq('id', 'r1');
      await core.from('conformance_kv').delete().eq('id', 'r1');
      expect(cap.reqs.map((r) => r.url.query).toList(), ['', '', '']);
    });

    test(
        'a requireApproval write still checks the id filter before any request',
        () async {
      final cap = Cap();
      final e = await kerrorOf(
        () =>
            mk(cap).from('notes').update({'a': 1}).requireApproval().execute(),
      );
      expect(e.code, 'K9O_INVALID_FIELD_VALUE');
      expect(cap.count, 0);
    });
  });
}
