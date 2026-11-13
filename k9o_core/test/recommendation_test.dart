import 'package:test/test.dart';

import 'helpers.dart';

Future<void> check(
  int status,
  Object? rec,
  String? text,
  double? wait,
) async {
  final c = mk(
    Cap(),
    status: status,
    errorBody: {
      'code': 'K9O_X',
      'message': 'msg',
      'context': {'x': 1},
      'recommendation': rec,
    },
  );
  final e = await kerrorOf(() => c.ai.embed(input: 'a'));
  expect(e.code, 'K9O_X');
  expect(e.message, 'msg');
  expect(e.status, status);
  expect(e.context, {'x': 1});
  expect(e.recommendation, text);
  expect(e.retryAfterSec, wait);
}

void main() {
  test('object with action',
      () => check(403, {'action': 'Open Billing'}, 'Open Billing', null));
  test('object with retryAfterSec and note',
      () => check(429, {'retryAfterSec': 30, 'note': 'retry'}, 'retry', 30));
  test('null', () => check(429, null, null, null));
  test('string', () => check(400, 'do this', 'do this', null));
  test('number', () => check(400, 5, null, null));
  test('array', () => check(400, ['a', 'b'], null, null));
  test('negative retryAfterSec ignored',
      () => check(429, {'retryAfterSec': -1}, null, null));
}
