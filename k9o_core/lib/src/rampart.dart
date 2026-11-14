import 'dart:async';
import 'dart:convert';

import 'client.dart';
import 'ed25519.dart';
import 'envelope.dart';
import 'jcs.dart';
import 'kerror.dart';
import 'sha256.dart';

/// Rampart classifies content you hand it as `clear`, `suspicious` or `malicious` and signs
/// a receipt for the verdict. It is advisory: it returns a verdict or an error and blocks
/// nothing; your code decides what to do with the content.
///
/// A long input is not truncated: it is scored in overlapping windows and the highest
/// injection score decides. Past 16 windows (about 6,000 tokens) [RampartNamespace.classify]
/// throws [KError] 413 `K9O_RAMPART_INPUT_TOO_LONG` (`context.reason` is
/// `rampart_input_too_long`) and gives no verdict. While the classifier cannot answer it
/// throws [KError] 503 `K9O_RAMPART_CLASSIFIER_UNAVAILABLE`: you get no verdict, never a
/// default `clear`.

/// The type a receipt must carry in its header.
const String rampartReceiptTyp = 'k9o.rampart.classify.v1';

/// The verdict and its receipt, as the gateway sent them.
class RampartVerdict {
  /// `clear`, `suspicious` or `malicious`.
  final String classification;

  /// Risk in basis points, 0 to 10000.
  final int riskScore;

  /// Confidence in basis points, 0 to 10000.
  final int confidence;
  final List<String> categories;
  final String calibrationVersion;

  /// The signed receipt (a compact JWS), exactly as received. Pass it to `verifyReceipt`.
  final String classificationReceipt;

  /// The project id (`proj_...`) the receipt names, when the gateway reports it.
  final String? projectId;

  const RampartVerdict({
    required this.classification,
    required this.riskScore,
    required this.confidence,
    required this.categories,
    required this.calibrationVersion,
    required this.classificationReceipt,
    this.projectId,
  });
}

/// One public key of the feed (an Ed25519 JWK).
class RampartJwk {
  final String kid;
  final String? kty;
  final String? crv;
  final String? x;

  /// Every member of the JWK as received.
  final Map<String, dynamic> raw;

  RampartJwk({
    required this.kid,
    this.kty,
    this.crv,
    this.x,
    Map<String, dynamic>? raw,
  }) : raw = Map.unmodifiable(raw ?? const <String, dynamic>{});

  factory RampartJwk.fromJson(Map<String, dynamic> j) => RampartJwk(
    kid: j['kid'] as String,
    kty: j['kty'] is String ? j['kty'] as String : null,
    crv: j['crv'] is String ? j['crv'] as String : null,
    x: j['x'] is String ? j['x'] as String : null,
    raw: j,
  );
}

/// The key feed: the keys and the issuer receipts carry (`<issuer>/rampart`). [issuer] is
/// null when the gateway does not advertise one.
class RampartJwks {
  final List<RampartJwk> keys;
  final String? issuer;
  const RampartJwks(this.keys, {this.issuer});
}

/// Why a receipt was refused. The set is closed.
enum RampartReceiptReason {
  malformed('malformed'),
  keyUnavailable('key_unavailable'),
  keyUnknown('key_unknown'),
  alg('alg'),
  typ('typ'),
  signature('signature'),
  issuer('issuer'),
  project('project'),
  projectUnknown('project_unknown'),
  expired('expired'),
  notYetValid('not_yet_valid'),
  inputHash('input_hash');

  /// The cross-SDK name, for example `input_hash`.
  final String value;
  const RampartReceiptReason(this.value);
}

/// Thrown by `verifyReceipt` for every refusal.
class RampartReceiptError implements Exception {
  final RampartReceiptReason reason;
  final String detail;
  final Object? cause;
  RampartReceiptError(this.reason, this.detail, {this.cause});

  @override
  String toString() =>
      'rampart receipt refused (${reason.value}): $detail';
}

/// The claims of a receipt that passed every check.
class RampartVerified {
  final String classification;
  final int riskScore;
  final int confidence;
  final List<String> categories;
  final String calibrationVersion;
  final String projectId;

  /// Lowercase hex SHA-256 of the canonical input.
  final String inputSha256;
  final String issuer;

  /// Seconds since the epoch.
  final num issuedAt;
  final num expiresAt;
  final String kid;

  /// How many windows of the input were scored (1 when it fits one window). A receipt
  /// without the claim reads as 1.
  final int windows;

  const RampartVerified({
    required this.classification,
    required this.riskScore,
    required this.confidence,
    required this.categories,
    required this.calibrationVersion,
    required this.projectId,
    required this.inputSha256,
    required this.issuer,
    required this.issuedAt,
    required this.expiresAt,
    required this.kid,
    this.windows = 1,
  });
}

final RegExp _b64url = RegExp(r'^[A-Za-z0-9_-]*$');

List<int> _b64urlDecode(String s) {
  if (!_b64url.hasMatch(s) || s.length % 4 == 1) {
    throw RampartReceiptError(
      RampartReceiptReason.malformed,
      'a receipt part is not base64url',
    );
  }
  try {
    return base64Url.decode(s + '=' * ((4 - s.length % 4) % 4));
  } on FormatException {
    throw RampartReceiptError(
      RampartReceiptReason.malformed,
      'a receipt part is not base64url',
    );
  }
}

Map<String, dynamic> _b64urlJson(String s, String what) {
  Object? v;
  try {
    v = jsonDecode(utf8.decode(_b64urlDecode(s)));
  } on RampartReceiptError {
    rethrow;
  } catch (_) {
    throw RampartReceiptError(
      RampartReceiptReason.malformed,
      'the receipt $what is not JSON',
    );
  }
  if (v is! Map<String, dynamic>) {
    throw RampartReceiptError(
      RampartReceiptReason.malformed,
      'the receipt $what is not an object',
    );
  }
  return v;
}

bool _isBp(Object? v) =>
    v is num && v.isFinite && v == v.truncate() && v >= 0 && v <= 10000;

List<int> _importKey(RampartJwk jwk) {
  if (jwk.kty != 'OKP' || jwk.crv != 'Ed25519' || jwk.x == null) {
    throw RampartReceiptError(
      RampartReceiptReason.keyUnknown,
      'the key named by the receipt is not an Ed25519 key',
    );
  }
  try {
    final x = _b64urlDecode(jwk.x!);
    if (x.length != 32) throw const FormatException();
    return x;
  } catch (_) {
    throw RampartReceiptError(
      RampartReceiptReason.keyUnknown,
      'the key named by the receipt could not be loaded',
    );
  }
}

/// `core.rampart`: classify content, read the key feed, verify receipts.
class RampartNamespace {
  final K9oCore _core;
  Map<String, RampartJwk>? _cachedKeys;
  String? _cachedIssuer;
  Future<RampartJwks>? _inflight;

  RampartNamespace(this._core);

  /// Classify [input] (a JSON object). `POST /@<project>/rampart/classify`. The answer
  /// holds the verdict fields, `classificationReceipt` and, when the gateway reports it,
  /// `projectId`, as received; the verdict is not checked until you call [verifyReceipt].
  /// Nothing is checked about the input before it is sent; the server decides.
  ///
  /// A long input is scored in overlapping windows and the highest injection score decides.
  ///
  /// Errors: [KError] 413 `K9O_RAMPART_INPUT_TOO_LONG` (past 16 windows, about 6,000
  /// tokens; no verdict), 503 `K9O_RAMPART_CLASSIFIER_UNAVAILABLE` (the classifier could
  /// not answer; no verdict), 403 or 404 (not a project member). Needs `projectSlug` on the client.
  Future<Envelope<RampartVerdict>> classify(
    Map<String, dynamic> input, {
    String? label,
  }) async {
    _core.requireProjectSlug();
    if (label != null && (label.isEmpty || label.length > 128)) {
      throw ArgumentError.value(
        label,
        'label',
        'rampart.classify: label must be 1 to 128 characters',
      );
    }
    return _core.send<RampartVerdict>(
      'POST',
      'rampart/classify',
      body: {'input': input, if (label != null) 'label': label},
      decode: (data) {
        if (data is! Map) throw invalidInternal();
        final m = data.cast<String, dynamic>();
        final cls = m['classification'];
        final receipt = m['classificationReceipt'];
        final risk = m['riskScore'];
        final conf = m['confidence'];
        final cats = m['categories'];
        final cal = m['calibrationVersion'];
        final pid = m['projectId'];
        if (cls is! String ||
            receipt is! String ||
            risk is! num ||
            conf is! num ||
            cats is! List ||
            cal is! String) {
          throw invalidInternal();
        }
        return RampartVerdict(
          classification: cls,
          riskScore: risk.toInt(),
          confidence: conf.toInt(),
          categories: cats.whereType<String>().toList(),
          calibrationVersion: cal,
          classificationReceipt: receipt,
          projectId: pid is String ? pid : null,
        );
      },
    );
  }

  /// The public keys that verify receipts and the issuer they carry:
  /// `GET /rampart/jwks`, no project prefix, no token needed. The feed is kept for
  /// [verifyReceipt].
  Future<RampartJwks> jwks() =>
      _inflight ??= _fetchFeed().whenComplete(() => _inflight = null);

  Future<RampartJwks> _fetchFeed() async {
    final body = await _core.getPublicJson('rampart/jwks');
    final keys = body['keys'];
    if (keys is! List ||
        !keys.every((k) => k is Map<String, dynamic> && k['kid'] is String)) {
      throw KError(
        code: 'K9O_INTERNAL_ERROR',
        message: 'The Rampart key feed is malformed: expected { keys: [...] }',
      );
    }
    final issuer = body['issuer'];
    final feed = RampartJwks(
      keys.map((k) => RampartJwk.fromJson(k as Map<String, dynamic>)).toList(),
      issuer: issuer is String && issuer.isNotEmpty ? issuer : null,
    );
    _cachedKeys = {for (final k in feed.keys) k.kid: k};
    _cachedIssuer = feed.issuer;
    return feed;
  }

  Future<(RampartJwk, String?)> _keyFor(String kid, RampartJwks? injected) async {
    if (injected != null) {
      for (final k in injected.keys) {
        if (k.kid == kid) return (k, injected.issuer);
      }
      throw RampartReceiptError(
        RampartReceiptReason.keyUnknown,
        "no key with the receipt's kid in the key set you passed",
      );
    }
    try {
      var fresh = false;
      if (_cachedKeys == null) {
        await jwks();
        fresh = true;
      }
      var k = _cachedKeys![kid];
      if (k == null && !fresh) {
        await jwks(); // refetch once on an unknown kid
        k = _cachedKeys![kid];
      }
      if (k == null) {
        throw RampartReceiptError(
          RampartReceiptReason.keyUnknown,
          "no key with the receipt's kid in the key feed",
        );
      }
      return (k, _cachedIssuer);
    } on RampartReceiptError {
      rethrow;
    } catch (e) {
      throw RampartReceiptError(
        RampartReceiptReason.keyUnavailable,
        'the key feed could not be read',
        cause: e,
      );
    }
  }

  /// Check a receipt against the [input] you classified and return its verified claims.
  ///
  /// [result] is a classify result (an `Envelope<RampartVerdict>` or a [RampartVerdict];
  /// it carries the receipt and its `projectId`) or a bare receipt `String` (then also pass
  /// [projectId]). Throws [RampartReceiptError] with a [RampartReceiptReason] on any
  /// failure; there is no partial verdict. Keys come from [keys], else the SDK fetches the
  /// feed once and keeps it for the life of the client, fetching again once when a `kid`
  /// is not in it.
  ///
  /// The issuer is [issuer], else the one the key feed advertises; with neither the receipt
  /// is refused (`issuer`). The project is [projectId], else the classify result's
  /// `projectId`; with neither the receipt is refused (`project_unknown`).
  Future<RampartVerified> verifyReceipt(
    Object result,
    Object? input, {
    RampartJwks? keys,
    String? issuer,
    String? projectId,
    int clockSkewSeconds = 60,
    DateTime Function()? now,
  }) async {
    Object? receipt = result;
    String? carriedProjectId;
    RampartVerdict? verdict;
    if (result is Envelope<RampartVerdict>) verdict = result.data;
    if (result is RampartVerdict) verdict = result;
    if (verdict != null) {
      receipt = verdict.classificationReceipt;
      carriedProjectId = verdict.projectId;
    }
    if (receipt is! String) {
      throw RampartReceiptError(
        RampartReceiptReason.malformed,
        'the receipt is not a string',
      );
    }
    final parts = receipt.split('.');
    if (parts.length != 3 || parts.any((p) => p.isEmpty)) {
      throw RampartReceiptError(
        RampartReceiptReason.malformed,
        'a receipt has three dot-separated parts',
      );
    }
    final h = parts[0], p = parts[1], s = parts[2];
    final header = _b64urlJson(h, 'header');
    final claims = _b64urlJson(p, 'payload');
    final signature = _b64urlDecode(s);
    if (header.containsKey('crit') || header['b64'] == false) {
      throw RampartReceiptError(
        RampartReceiptReason.malformed,
        'the header carries unsupported critical parameters',
      );
    }

    // 1. The key is chosen by the header kid, from the feed; a key inside the receipt is
    //    never used.
    final kid = header['kid'];
    if (kid is! String) {
      throw RampartReceiptError(
        RampartReceiptReason.malformed,
        'the header has no kid',
      );
    }
    final (jwk, feedIssuer) = await _keyFor(kid, keys);
    // 2. and 3. Algorithm and type.
    if (header['alg'] != 'EdDSA') {
      throw RampartReceiptError(
        RampartReceiptReason.alg,
        'the algorithm is not EdDSA',
      );
    }
    if (header['typ'] != rampartReceiptTyp) {
      throw RampartReceiptError(
        RampartReceiptReason.typ,
        'the type is not $rampartReceiptTyp',
      );
    }
    // Signature, before any claim is trusted.
    final pub = _importKey(jwk);
    final good =
        signature.length == 64 &&
        ed25519Verify(pub, utf8.encode('$h.$p'), signature);
    if (!good) {
      throw RampartReceiptError(
        RampartReceiptReason.signature,
        'the signature does not verify',
      );
    }

    // 4. Issuer, project, time window.
    final wantIssuer = issuer ?? feedIssuer;
    if (wantIssuer == null) {
      throw RampartReceiptError(
        RampartReceiptReason.issuer,
        'no issuer is advertised: the key feed carries none and no issuer option was given',
      );
    }
    if (claims['iss'] != wantIssuer) {
      throw RampartReceiptError(
        RampartReceiptReason.issuer,
        'the issuer is not the expected one',
      );
    }
    final expectedProject =
        projectId ??
        (carriedProjectId != null && carriedProjectId.isNotEmpty
            ? carriedProjectId
            : null);
    if (expectedProject == null) {
      throw RampartReceiptError(
        RampartReceiptReason.projectUnknown,
        'no project id to compare: pass the classify result or projectId',
      );
    }
    if (claims['project_id'] != expectedProject) {
      throw RampartReceiptError(
        RampartReceiptReason.project,
        'the receipt names a different project',
      );
    }
    final iat = claims['iat'];
    final exp = claims['exp'];
    if (iat is! num || exp is! num || !iat.isFinite || !exp.isFinite) {
      throw RampartReceiptError(
        RampartReceiptReason.malformed,
        'iat and exp must be numbers',
      );
    }
    final nowSec = (now?.call() ?? DateTime.now()).millisecondsSinceEpoch / 1000;
    if (nowSec > exp + clockSkewSeconds) {
      throw RampartReceiptError(
        RampartReceiptReason.expired,
        'the receipt has expired',
      );
    }
    if (nowSec < iat - clockSkewSeconds) {
      throw RampartReceiptError(
        RampartReceiptReason.notYetValid,
        'the receipt was issued in the future',
      );
    }

    // 5. The receipt must attest this exact input.
    final String digest;
    try {
      digest = sha256Hex(canonicalize(input));
    } on JcsError catch (e) {
      throw RampartReceiptError(
        RampartReceiptReason.inputHash,
        'the input cannot be canonicalised: ${e.message}',
      );
    }
    final claimed = claims['input_sha256'];
    if (claimed is! String) {
      throw RampartReceiptError(
        RampartReceiptReason.malformed,
        'input_sha256 is missing',
      );
    }
    if (claimed != digest) {
      throw RampartReceiptError(
        RampartReceiptReason.inputHash,
        'the receipt does not attest this input',
      );
    }

    // 6. The verdict comes from the verified claims.
    final c = claims['classification'];
    final cats = claims['categories'];
    if (c != 'clear' && c != 'suspicious' && c != 'malicious') {
      throw RampartReceiptError(
        RampartReceiptReason.malformed,
        'unknown classification',
      );
    }
    if (!_isBp(claims['risk_bp']) || !_isBp(claims['confidence_bp'])) {
      throw RampartReceiptError(
        RampartReceiptReason.malformed,
        'risk_bp and confidence_bp must be integers 0 to 10000',
      );
    }
    if (cats is! List || !cats.every((x) => x is String)) {
      throw RampartReceiptError(
        RampartReceiptReason.malformed,
        'categories must be a list of strings',
      );
    }
    final cal = claims['calibration_version'];
    if (cal is! String) {
      throw RampartReceiptError(
        RampartReceiptReason.malformed,
        'calibration_version is missing',
      );
    }
    // `windows` is how many windows were scored; other claims this SDK does not know are
    // ignored.
    final w = claims['windows'];
    if (w != null && !(w is num && w.isFinite && w == w.truncate() && w >= 1)) {
      throw RampartReceiptError(
        RampartReceiptReason.malformed,
        'windows must be a positive integer',
      );
    }
    return RampartVerified(
      windows: w == null ? 1 : (w as num).toInt(),
      classification: c as String,
      riskScore: (claims['risk_bp'] as num).toInt(),
      confidence: (claims['confidence_bp'] as num).toInt(),
      categories: cats.cast<String>().toList(),
      calibrationVersion: cal,
      projectId: expectedProject,
      inputSha256: digest,
      issuer: wantIssuer,
      issuedAt: iat,
      expiresAt: exp,
      kid: kid,
    );
  }
}
