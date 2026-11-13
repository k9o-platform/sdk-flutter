// Locating the end user's region for password sign-in.
//
// `region.dart` finds the org's regional API host. An end user can live in another region of the project, so sign-in first
// asks the project which region holds the address (`POST /@<projectSlug>/gate/locate { email }` at that regional base)
// and sends the credential to the origin it names. The answer is the same for a known and an unknown address.
//
// Rules:
//   - The located origin is used for that one attempt. It is never cached as authority. The one thing kept is a hint, per
//     refresh token, so that refresh and sign-out reach the region that issued the session; a stale hint gets a 401.
//   - An origin is used only if it is `https` (`http` only when the base is itself `http` on a loopback host), has no
//     userinfo, port, path, query or fragment, and its host is exactly the base host's org, family and apex with the
//     region code `[a-z]{2}\d{2}` added or swapped in the service label, and that code equals the answer's `region`.
//     Anything else, or `origin: null`, means the base is used. A password never goes to a host that fails this.

import 'region.dart';

final RegExp _regionCode = RegExp(r'^[a-z]{2}\d{2}$');

bool _isLoopback(String host) {
  final h = host.toLowerCase();
  return h == 'localhost' ||
      h.endsWith('.localhost') ||
      h == '127.0.0.1' ||
      h == '::1' ||
      h == '[::1]';
}

/// The origin the credential goes to: the located one if it passes the rule, else [base]. Pure; never throws.
/// [answer] is the `data` of the locate envelope.
String chooseLocatedOrigin(String base, Object? answer) {
  try {
    if (answer is! Map) return base;
    final region = answer['region'];
    final origin = answer['origin'];
    if (origin is! String || region is! String || !_regionCode.hasMatch(region)) {
      return base;
    }
    final b = Uri.parse(base);
    final u = Uri.parse(origin);
    if (!b.hasScheme || !u.hasScheme || b.host.isEmpty || u.host.isEmpty) return base;
    if (u.userInfo.isNotEmpty || u.hasPort || u.hasQuery || u.hasFragment) return base;
    if (u.path != '' && u.path != '/') return base;
    if (u.scheme != 'https' &&
        !(u.scheme == 'http' &&
            b.scheme == 'http' &&
            _isLoopback(b.host) &&
            _isLoopback(u.host))) {
      return base;
    }
    final baseHost = b.hasPort ? '${b.host}:${b.port}' : b.host;
    if (u.scheme == b.scheme && u.host == b.host && !b.hasPort) {
      return '${b.scheme}://$baseHost';
    }
    final from = parseApiHost(b.host);
    final to = parseApiHost(u.host);
    if (from == null || to == null || to.region != region) return base;
    if (from.orgSlug != to.orgSlug ||
        from.family != to.family ||
        from.apex != to.apex) {
      return base;
    }
    return '${u.scheme}://${u.host}';
  } catch (_) {
    return base;
  }
}

const int _hintLimit = 64;
final Map<String, String> _hints = <String, String>{};

/// Remember which origin issued the session with this refresh token (a hint, not authority).
void rememberSessionOrigin(String? refreshToken, String origin) {
  if (refreshToken == null || refreshToken.isEmpty) return;
  _hints.remove(refreshToken);
  _hints[refreshToken] = origin;
  while (_hints.length > _hintLimit) {
    _hints.remove(_hints.keys.first);
  }
}

String? sessionOriginHint(String refreshToken) => _hints[refreshToken];

void forgetSessionOrigin(String refreshToken) => _hints.remove(refreshToken);
