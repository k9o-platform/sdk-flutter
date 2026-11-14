import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'helpers.dart';

Future<String?> idFor(Map<String, dynamic> body, Map<String, String> headers) async {
  final c = mk(
    Cap(),
    handler: (req, n) async => http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(body))),
      404,
      headers: {'content-type': 'application/json', ...headers},
    ),
  );
  final e = await kerrorOf(() => c.ai.embed(input: 'a'));
  expect(e.status, 404);
  return e.requestId;
}

void main() {
  final body = {'code': 'K9O_NOT_FOUND', 'message': 'nope'};
  test('header fills requestId when the body has none', () async {
    expect(await idFor(body, {'x-k9o-request-id': 'req_abc'}), 'req_abc');
  });
  test('body requestId wins over the header', () async {
    expect(
      await idFor({...body, 'requestId': 'req_body'}, {'x-k9o-request-id': 'req_hdr'}),
      'req_body',
    );
  });
  test('no header and no body field gives null', () async {
    expect(await idFor(body, {}), isNull);
  });
  test('header name is case-insensitive', () async {
    expect(await idFor(body, {'X-K9O-Request-Id': 'req_abc'}), 'req_abc');
  });
}
