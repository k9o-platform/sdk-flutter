import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:k9o_core/k9o_core.dart';

class Cap {
  final List<http.BaseRequest> reqs = [];
  final List<List<int>> bodies = [];
  String get bodyText => utf8.decode(bodies.last, allowMalformed: true);
  http.BaseRequest get req => reqs.last;
  http.Request get plain => reqs.last as http.Request;
  Map<String, dynamic> get json => jsonDecode(bodyText) as Map<String, dynamic>;
  int get count => reqs.length;
}

K9oCore mk(
  Cap cap, {
  Object data = const <String, dynamic>{},
  Map<String, dynamic> meta = const {},
  int status = 200,
  String? slug = 'member-portal',
  Object? errorBody,
  Future<http.StreamedResponse> Function(http.BaseRequest, int n)? handler,
}) {
  final client = MockClient.streaming((req, body) async {
    // The region probe (credential-free HEAD to the region-free host) is not an API call.
    if (req.method == 'HEAD') {
      return http.StreamedResponse(const Stream.empty(), 200);
    }
    cap.reqs.add(req);
    cap.bodies.add(await body.toBytes());
    if (handler != null) return handler(req, cap.count);
    final payload = errorBody ?? {'data': data, 'meta': meta};
    final bytes = utf8.encode(jsonEncode(payload));
    return http.StreamedResponse(
      Stream.value(bytes),
      status,
      headers: {'content-type': 'application/json'},
    );
  });
  return K9oCore(
    baseUrl: 'https://acme.api.k9o.io/',
    projectSlug: slug,
    accessToken: 'tok_abc',
    httpClient: client,
  );
}

Future<KError> kerrorOf(Future<Object?> Function() f) async {
  try {
    await f();
  } on KError catch (e) {
    return e;
  }
  throw StateError('expected a KError');
}
