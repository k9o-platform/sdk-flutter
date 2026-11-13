import 'package:http/http.dart' as http;

/// Structure of a gateway API host, read from the host itself (never matched against an apex list).
class ApiHost {
  /// First label of an org host (`acme` in `acme.api.corp.internal`); null for a platform host.
  final String? orgSlug;

  /// `api` or `api-staging`.
  final String family;

  /// 4-character region code when the host is regional (`api-de01`), else null (region-free).
  final String? region;

  /// Everything after the gateway label.
  final String apex;
  const ApiHost(this.orgSlug, this.family, this.region, this.apex);
}

final RegExp _apiLabel = RegExp(r'^(api|api-staging)(?:-([a-z]{2}\d{2}))?$');
final RegExp _slug = RegExp(r'^[a-z][a-z0-9-]{1,62}$');

/// Reads org slug and region out of a gateway host. Null for any other shape
/// (localhost, an IP, a single-label host), which callers use exactly as given.
ApiHost? parseApiHost(String host) {
  final labels = host.toLowerCase().split('.');
  if (labels.any((l) => l.isEmpty)) return null;
  ApiHost? mk(String gateway, String? org, List<String> rest) {
    final m = _apiLabel.firstMatch(gateway);
    if (m == null || rest.isEmpty) return null;
    return ApiHost(org, m.group(1)!, m.group(2), rest.join('.'));
  }

  if (labels.length >= 3 &&
      _slug.hasMatch(labels[0]) &&
      !labels[0].endsWith('-') &&
      _apiLabel.hasMatch(labels[1])) {
    return mk(labels[1], labels[0], labels.sublist(2));
  }
  if (labels.length >= 2 && _apiLabel.hasMatch(labels[0])) {
    return mk(labels[0], null, labels.sublist(1));
  }
  return null;
}

/// The default org host suffix used when only an `orgSlug` is given.
const String _defaultApex = 'api.k9o.io';

bool _validSlug(String s) => _slug.hasMatch(s) && !s.endsWith('-');

/// Resolves the org base URL from [baseUrl] and [orgSlug].
///
/// A base URL that is the platform host (`api.<apex>`, no org label, no region) combined with an
/// [orgSlug] becomes `<scheme>://<orgSlug>.<host>` (port kept). Any other base URL (an org host, a
/// regional host, a custom domain, localhost, an IP) is returned as given. With only an [orgSlug]
/// the result is `https://<orgSlug>.api.k9o.io`. With neither, [onMissing] is called and must throw.
String resolveBaseUrl(
  String? baseUrl,
  String? orgSlug, {
  required Never Function() onMissing,
  required Never Function(String slug) onBadSlug,
}) {
  final given = baseUrl == null ? '' : baseUrl.replaceAll(RegExp(r'/+$'), '');
  if (given.isEmpty) {
    if (orgSlug == null || orgSlug.isEmpty) onMissing();
    if (!_validSlug(orgSlug)) onBadSlug(orgSlug);
    return 'https://$orgSlug.$_defaultApex';
  }
  if (orgSlug != null && orgSlug.isNotEmpty) {
    final u = Uri.tryParse(given);
    if (u != null &&
        (u.scheme == 'http' || u.scheme == 'https') &&
        (u.path.isEmpty || u.path == '/') &&
        !u.hasQuery &&
        !u.hasFragment) {
      final h = parseApiHost(u.host);
      if (h != null && h.orgSlug == null && h.region == null) {
        if (!_validSlug(orgSlug)) onBadSlug(orgSlug);
        return '${u.scheme}://$orgSlug.${u.host}${u.hasPort ? ':${u.port}' : ''}';
      }
    }
  }
  return given;
}

/// The regional origin a `Location` may name for [host], or null if it is not exactly that
/// (https, no userinfo or port, same org, same family, same apex, with a region code).
String? regionalOriginFromLocation(String host, String location, String base) {
  final from = parseApiHost(host);
  if (from == null || from.orgSlug == null || from.region != null) return null;
  final Uri u;
  try {
    u = Uri.parse(base).resolve(location);
  } catch (_) {
    return null;
  }
  if (u.scheme != 'https' || u.userInfo.isNotEmpty || u.hasPort) return null;
  final to = parseApiHost(u.host);
  if (to == null || to.region == null) return null;
  if (to.orgSlug != from.orgSlug ||
      to.family != from.family ||
      to.apex != from.apex) {
    return null;
  }
  return 'https://${u.host}';
}

/// Result of one probe: [cacheable] is false after a network failure.
class RegionProbe {
  final String origin;
  final bool cacheable;
  const RegionProbe(this.origin, this.cacheable);
}

/// One credential-free `HEAD` to a region-free org host; takes the `308` `Location`.
/// A regional, platform, IP or localhost [configured] origin is returned as given with no request.
Future<RegionProbe> probeRegion(http.Client client, String configured) async {
  final String host;
  try {
    host = Uri.parse(configured).host;
  } catch (_) {
    return RegionProbe(configured, true);
  }
  final parsed = parseApiHost(host);
  if (parsed == null || parsed.orgSlug == null || parsed.region != null) {
    return RegionProbe(configured, true);
  }
  try {
    final req = http.Request('HEAD', Uri.parse('$configured/'))
      ..followRedirects = false
      ..headers['accept'] = '*/*';
    final res = await client.send(req);
    await res.stream.drain<void>();
    if (res.statusCode == 308) {
      final loc = res.headers['location'];
      final origin = loc == null
          ? null
          : regionalOriginFromLocation(host, loc, configured);
      if (origin != null) return RegionProbe(origin, true);
    }
    return RegionProbe(configured, true);
  } catch (_) {
    return RegionProbe(configured, false);
  }
}
