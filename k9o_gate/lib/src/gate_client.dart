import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'gate_error.dart';
import 'locate.dart';
import 'models.dart';
import 'region.dart';
import 'secure_token_store.dart';

Never _missingBaseUrl() => throw K9OGateConfigError(
  code: 'K9O_INVALID_BASE_URL',
  message: 'pass orgBaseUrl or orgSlug',
  context: {'field': 'baseUrl'},
);

Never _badOrgSlug(String slug) => throw K9OGateConfigError(
  code: 'K9O_INVALID_FIELD_VALUE',
  message: 'orgSlug "$slug" does not match the required format '
      '^[a-z][a-z0-9-]{1,62}\$ (must not end with \'-\')',
  context: {'field': 'orgSlug', 'slug': slug},
);

Never _badErrors(String value) => throw K9OGateConfigError(
  code: 'K9O_INVALID_FIELD_VALUE',
  message: 'errors "$value" must be "full" or "redacted"',
  context: {'field': 'errors', 'value': value},
);

bool _redactedFor(String errors) {
  if (errors == 'full') return false;
  if (errors == 'redacted') return true;
  return _badErrors(errors);
}

/// Kilimanjaro Gate Flutter SDK
///
/// [GateClient] is the primary entry point. Initialise once per project
/// and call `signIn`, `refreshToken`, or `signOut`.
///
/// Refresh tokens are automatically persisted via [tokenStore]
/// (defaults to [SecureTokenStore] backed by `flutter_secure_storage`),
/// and each refresh stores the next one.
/// Pass a custom [TokenStore] for testing or custom persistence.
///
/// Example:
/// ```dart
/// final gate = GateClient(
///   orgBaseUrl: 'https://acme.api.k9o.io', // or: orgSlug: 'acme'
///   projectSlug: 'my-project',
/// );
/// final result = await gate.signIn(email: 'user@example.com', password: 'pass');
/// ```
class GateClient {
  final String _orgBaseUrl;
  final String _projectSlug;
  final TokenStore _tokenStore;
  final http.Client _httpClient;
  final bool _redacted;

  /// [errors] is `"full"` (the default: a [GateError] carries the gateway's code, message,
  /// recommendation and context) or `"redacted"` (see [GateError]). Any other value throws a
  /// [K9OGateConfigError].
  GateClient({
    String? orgBaseUrl,
    required String projectSlug,
    TokenStore? tokenStore,
    http.Client? httpClient,
    String? orgSlug,
    String errors = 'full',
  })  : _orgBaseUrl = resolveBaseUrl(
          orgBaseUrl == null ? null : orgBaseUrl.replaceAll(RegExp(r'/$'), ''),
          orgSlug,
          onMissing: _missingBaseUrl,
          onBadSlug: _badOrgSlug,
        ),
        _projectSlug = projectSlug,
        _tokenStore = tokenStore ?? const SecureTokenStore(),
        _httpClient = httpClient ?? http.Client(),
        _redacted = _redactedFor(errors);

  // MARK: - Public API surface

  /// Sign in an existing end-user with email and password.
  ///
  /// Persists the refresh token on success.
  /// Throws [GateError.invalidCredentials] on bad credentials.
  ///
  /// Asks the project which region holds the email first (`POST /@<projectSlug>/gate/locate`,
  /// email only) and sends the password to that region's host. A 429 or 503 from that step is
  /// raised as [GateError.rateLimited] or [GateError.regionUnavailable], and no password is sent.
  ///
  /// Mirrors: `POST /@<projectSlug>/gate/signin`
  Future<AuthResult> signIn({
    required String email,
    required String password,
  }) async {
    final origin = await _locate(email);
    final result = await _post(
      'signin',
      body: {'email': email, 'password': password},
      origin: origin,
    );
    rememberSessionOrigin(result.session.refreshToken, origin);
    await _tokenStore.save(result.session.refreshToken);
    return result;
  }

  /// Mint a new access token from the stored (or supplied) refresh token.
  ///
  /// If [refreshToken] is null, loads the token from the store. Each refresh
  /// replaces the refresh token: the result carries the next one, the client
  /// stores it before this call returns, and the one you sent stops working.
  /// Refreshes run one at a time: a call made while another is in flight for the
  /// same token shares that answer, so a token is never sent twice (the gateway
  /// treats a second use as a replay and ends the session). The result has no
  /// `user`; read the subject from the access token with [AccessToken.decode].
  ///
  /// When the gateway has ended the session this throws
  /// [GateError.unauthenticated] with [GateError.sessionEndReason] set
  /// (`inactive`, `max_length`, `revoked` or `replay`), and the stored token is
  /// cleared: the user must sign in again. [GateError.invalidCredentials] (an
  /// unknown token or a locked user) clears it the same way.
  ///
  /// Mirrors: `POST /@<projectSlug>/gate/refresh` with body `{refreshToken}`.
  Future<RefreshResult> refreshToken({String? refreshToken}) {
    // The callbacks use a block: a returned Future would make `whenComplete` wait for it.
    if (refreshToken == null) {
      return _storedFlight ??= _refreshOnce(null).whenComplete(() {
        _storedFlight = null;
      });
    }
    return _flights[refreshToken] ??= _refreshOnce(refreshToken).whenComplete(() {
      _flights.remove(refreshToken);
    });
  }

  /// The refresh of the stored token in flight, if any. Loading, sending and storing are one
  /// step, so a late caller never sends the old token.
  Future<RefreshResult>? _storedFlight;

  /// Refreshes of a token passed in by the caller, by token.
  final Map<String, Future<RefreshResult>> _flights = {};

  Future<RefreshResult> _refreshOnce(String? explicit) async {
    final stored = await _tokenStore.load();
    final token = explicit ?? stored;
    if (token == null) throw const GateError.unauthenticated();
    final origin = sessionOriginHint(token);
    final Map<String, dynamic> data;
    try {
      data = await _postData('refresh', body: {'refreshToken': token}, origin: origin);
    } on GateError catch (e) {
      if (e.status == 401 && (e.code == 'SESSION_EXPIRED' || e.code == 'UNAUTHENTICATED' || e.code == 'INVALID_CREDENTIALS')) {
        forgetSessionOrigin(token);
        if (token == stored) await _tokenStore.delete();
      }
      rethrow;
    }
    final RefreshResult result;
    try {
      result = RefreshResult.fromJson(data);
    } catch (e) {
      throw GateError.decoding(e);
    }
    forgetSessionOrigin(token);
    if (origin != null) rememberSessionOrigin(result.refreshToken, origin);
    // Stored before returning, so the next refresh sends the new token.
    if (token == stored || explicit == null) await _tokenStore.save(result.refreshToken);
    return result;
  }

  /// Sign out the current session. Clears the token store.
  ///
  /// If [refreshToken] is null, loads the token from the store; with none,
  /// nothing is sent. Returns `true` when the gateway revoked a live session
  /// and `false` when the token was unknown or already revoked (sign-out is
  /// idempotent; the store is cleared either way).
  ///
  /// Mirrors: `POST /@<projectSlug>/gate/signout` with body `{refreshToken}`.
  Future<bool> signOut({String? refreshToken}) async {
    // A refresh in flight is about to replace the stored token; sign out the new one.
    if (refreshToken == null) {
      try {
        await _storedFlight;
      } catch (_) {}
    }
    final token = refreshToken ?? await _tokenStore.load();
    if (token == null) return false;
    final data = await _postData('signout',
        body: {'refreshToken': token}, origin: sessionOriginHint(token));
    forgetSessionOrigin(token);
    await _tokenStore.delete();
    return data['revoked'] == true;
  }

  /// End every live session of this end user, on every device, this one included, and clear the token store.
  ///
  /// Call it with the end user's [accessToken] (the one `signIn` or `refreshToken` returned), not a refresh token.
  /// Returns how many sessions ended. Each ended session's next refresh is refused with
  /// [GateError.sessionEndReason] `revoked`; access tokens already issued keep working until they expire, so drop
  /// yours too. An operator's token raises a [GateError] with code `K9O_TRUST_ZONE_VIOLATION` (403), and a token
  /// issued for another project one with code `K9O_PROJECT_SCOPE_MISMATCH` (403); the store is left as it was.
  ///
  /// A refresh in flight finishes first, so it cannot store a token for a session that is about to end.
  ///
  /// Mirrors: `POST /@<projectSlug>/auth/sessions/revoke-all`
  Future<int> revokeAllSessions({required String accessToken}) async {
    try {
      await _storedFlight;
    } catch (_) {}
    final stored = await _tokenStore.load();
    final data = await _postData('sessions/revoke-all',
        area: 'auth',
        bearer: accessToken,
        origin: stored == null ? null : sessionOriginHint(stored));
    final count = data['revokedCount'];
    if (count is! num) {
      throw GateError.decoding(const FormatException('revokedCount is not a number'));
    }
    if (stored != null) forgetSessionOrigin(stored);
    await _tokenStore.delete();
    return count.toInt();
  }

  // MARK: - End-user flows

  /// Start adding a passkey to the signed-in end user.
  ///
  /// Needs the end user's [accessToken] as the bearer. The answer is the registration options; the challenge is
  /// single-use and short-lived. This is the wire layer: hand [PasskeyOptions.raw] to the platform's passkey API and
  /// pass the credential it makes to [finishPasskeyRegistration]. The SDK does not call that API.
  ///
  /// Mirrors: `POST /@<projectSlug>/gate/passkeys/register/begin`
  Future<PasskeyOptions> beginPasskeyRegistration({
    required String accessToken,
  }) async {
    final data = await _postData('passkeys/register/begin', bearer: accessToken);
    return _decode(data, PasskeyOptions.fromJson);
  }

  /// Finish adding a passkey. Needs the end user's [accessToken] as the bearer.
  ///
  /// [response] is the credential the authenticator made from the options, in its JSON form
  /// (`RegistrationResponseJSON`: `id` and `response`, plus `rawId`, `type` and the rest). [label] names the passkey
  /// (1 to 256 characters). Throws a [GateError] with status 400 when the challenge is invalid, expired or used, or
  /// the credential does not verify.
  ///
  /// Mirrors: `POST /@<projectSlug>/gate/passkeys/register/finish`
  Future<RegisteredPasskey> finishPasskeyRegistration({
    required String accessToken,
    required Map<String, dynamic> response,
    String? label,
  }) async {
    final data = await _postData(
      'passkeys/register/finish',
      body: {'response': response, if (label != null) 'label': label},
      bearer: accessToken,
    );
    return _decode(data, RegisteredPasskey.fromJson);
  }

  /// Start a passkey sign-in. No bearer token is sent.
  ///
  /// Pass [email] to name the account (3 to 254 characters), or omit it to let the authenticator offer the passkeys it
  /// holds for this site. This is the wire layer: hand [PasskeyOptions.raw] to the platform's passkey API and pass the
  /// assertion it makes to [finishPasskeySignIn].
  ///
  /// Mirrors: `POST /@<projectSlug>/gate/passkeys/signin/begin`
  Future<PasskeyOptions> beginPasskeySignIn({String? email}) async {
    final data = await _postData(
      'passkeys/signin/begin',
      body: {if (email != null) 'email': email},
    );
    return _decode(data, PasskeyOptions.fromJson);
  }

  /// Finish a passkey sign-in. No bearer token is sent.
  ///
  /// [response] is the assertion the authenticator made from the options, in its JSON form
  /// (`AuthenticationResponseJSON`). Persists the refresh token on success. Throws a [GateError] with status 400 when
  /// the challenge is invalid, expired or used, the passkey is unknown, or the assertion does not verify.
  ///
  /// Mirrors: `POST /@<projectSlug>/gate/passkeys/signin/finish`
  Future<Session> finishPasskeySignIn({
    required Map<String, dynamic> response,
  }) async {
    final data = await _postData('passkeys/signin/finish', body: {'response': response});
    final session = _decode(
      data,
      (d) => Session.fromJson(d['session'] as Map<String, dynamic>),
    );
    await _tokenStore.save(session.refreshToken);
    return session;
  }

  /// Start setting up an authenticator app for the signed-in end user.
  ///
  /// Needs the end user's [accessToken] as the bearer. [label] names the authenticator (1 to 256 characters; the
  /// gateway uses `TOTP` when it is omitted). The secret and the `otpauth://` uri, for a QR code, are in this answer
  /// only. The factor does nothing until [confirmTotp] succeeds.
  ///
  /// Mirrors: `POST /@<projectSlug>/gate/mfa/totp/enroll`
  Future<TotpEnrollment> enrollTotp({
    required String accessToken,
    String? label,
  }) async {
    final data = await _postData(
      'mfa/totp/enroll',
      body: {if (label != null) 'label': label},
      bearer: accessToken,
    );
    return _decode(data, TotpEnrollment.fromJson);
  }

  /// Finish setting up an authenticator app with its first [code] (4 to 10 characters). Needs the end user's
  /// [accessToken] as the bearer.
  ///
  /// To add a second authenticator, also pass [currentCode] from one already confirmed. When this is the person's first
  /// confirmed authenticator, their other sessions end and [TotpConfirmation.session] carries a new one (stored
  /// refresh token replaced). Throws a [GateError] with code `K9O_MFA_REQUIRED` when a second authenticator is added
  /// without [currentCode], and status 401 on a wrong or expired code.
  ///
  /// Mirrors: `POST /@<projectSlug>/gate/mfa/totp/confirm`
  Future<TotpConfirmation> confirmTotp({
    required String accessToken,
    required String factorId,
    required String code,
    String? currentCode,
  }) async {
    final data = await _postData(
      'mfa/totp/confirm',
      body: {
        'factorId': factorId,
        'code': code,
        if (currentCode != null) 'currentCode': currentCode,
      },
      bearer: accessToken,
    );
    final result = _decode(data, TotpConfirmation.fromJson);
    final session = result.session;
    if (session != null) await _tokenStore.save(session.refreshToken);
    return result;
  }

  /// List the end user's second-factor methods, confirmed and pending, oldest first. Needs the end user's
  /// [accessToken] as the bearer. A pending method ([MfaMethod.verifiedAt] null) is not yet usable.
  ///
  /// Mirrors: `GET /@<projectSlug>/gate/mfa/methods`
  Future<List<MfaMethod>> listMfaMethods({required String accessToken}) async {
    final data = await _getData('mfa/methods', bearer: accessToken);
    return _decode(data, (d) => (d['methods'] as List)
        .map((m) => MfaMethod.fromJson(m as Map<String, dynamic>))
        .toList());
  }

  /// Remove one second-factor method by [methodId] (an [MfaMethod.id] from [listMfaMethods]). Needs the end user's
  /// [accessToken] as the bearer. Removing a confirmed authenticator app needs its current [code] (4 to 10
  /// characters); a pending one needs none. Returns `true` when a method was removed and `false` when none matched.
  /// Throws a [GateError] with code `K9O_MFA_REQUIRED` when the code is missing, status 401 on a wrong or expired code,
  /// and status 429 after too many wrong codes.
  ///
  /// Mirrors: `DELETE /@<projectSlug>/gate/mfa/methods/<methodId>` with an optional body `{code}`
  Future<bool> deleteMfaMethod({
    required String accessToken,
    required String methodId,
    String? code,
  }) async {
    final data = await _deleteData(
      'mfa/methods/${Uri.encodeComponent(methodId)}',
      body: code == null ? null : {'code': code},
      bearer: accessToken,
    );
    final deleted = data['deleted'];
    if (deleted is! bool) {
      throw GateError.decoding(const FormatException('deleted is not a boolean'));
    }
    return deleted;
  }

  /// Email a password-reset link to [email]. No bearer token is sent.
  ///
  /// The answer is the same whether or not the address has an account. The token is valid for one hour and works
  /// once. A deployment without a mail relay answers 503 `EMAIL_NOT_CONFIGURED`. Like [signIn], it asks the project
  /// which region holds the email first and sends the request to that region's host.
  ///
  /// Mirrors: `POST /@<projectSlug>/gate/password-reset/request`
  Future<PasswordResetRequest> requestPasswordReset({
    required String email,
  }) async {
    final origin = await _locate(email);
    final data = await _postData(
      'password-reset/request',
      body: {'email': email},
      origin: origin,
    );
    return _decode(data, PasswordResetRequest.fromJson);
  }

  /// Set a new password with the [token] from the email. No bearer token is sent.
  ///
  /// The result carries a [PasswordResetResult.session] (its refresh token is stored), or an
  /// [PasswordResetResult.mfa] challenge and no session when the account has a confirmed authenticator. Throws a
  /// [GateError] with status 400 on a wrong, expired or used token, or a password the project refuses.
  ///
  /// Mirrors: `POST /@<projectSlug>/gate/password-reset/redeem`
  Future<PasswordResetResult> redeemPasswordReset({
    required String token,
    required String newPassword,
  }) async {
    final data = await _postData(
      'password-reset/redeem',
      body: {'token': token, 'newPassword': newPassword},
    );
    final result = _decode(data, PasswordResetResult.fromJson);
    final session = result.session;
    if (session != null) await _tokenStore.save(session.refreshToken);
    return result;
  }

  /// Accept an invitation: the [token] from the invitation and a [password] create the end user. No bearer token is
  /// sent. [displayName] is optional (1 to 256 characters). The refresh token is stored. Throws a [GateError] with
  /// status 400 on a wrong, expired or used token, or a password the project refuses.
  ///
  /// Mirrors: `POST /@<projectSlug>/gate/invitations/redeem`
  Future<InvitationResult> redeemInvitation({
    required String token,
    required String password,
    String? displayName,
  }) async {
    final data = await _postData(
      'invitations/redeem',
      body: {
        'token': token,
        'password': password,
        if (displayName != null) 'displayName': displayName,
      },
    );
    final result = _decode(data, InvitationResult.fromJson);
    await _tokenStore.save(result.session.refreshToken);
    return result;
  }

  /// Check an end user's access token from your backend.
  ///
  /// The call is authenticated with [bearerToken] (the credential your backend holds); the token to check goes in
  /// [token]. A token that is invalid, expired, issued for another project, or belongs to an end user who is no longer
  /// active is an answer with [SessionVerification.valid] `false` and a reason, not an error.
  ///
  /// Mirrors: `POST /@<projectSlug>/gate/verify-session`
  Future<SessionVerification> verifySession({
    required String bearerToken,
    required String token,
  }) async {
    final data = await _postData(
      'verify-session',
      body: {'token': token},
      bearer: bearerToken,
    );
    return _decode(data, SessionVerification.fromJson);
  }

  T _decode<T>(Map<String, dynamic> data, T Function(Map<String, dynamic>) parse) {
    try {
      return parse(data);
    } catch (e) {
      throw GateError.decoding(e);
    }
  }

  // MARK: - Internal helpers

  Future<String>? _origin;

  /// The origin requests go to: the regional host once learned (one credential-free
  /// probe of a region-free `<org>.api[-staging].<rest>` address), else the configured one.
  /// A network failure of the probe is not remembered.
  Future<String> _resolveOrigin() {
    final hit = _origin;
    if (hit != null) return hit;
    final p = probeRegion(_httpClient, _orgBaseUrl).then((r) {
      if (!r.cacheable) _origin = null;
      return r.origin;
    });
    return _origin = p;
  }

  Future<Uri> _uri(String suffix, String? origin, String area) async {
    final o = origin ?? await _resolveOrigin();
    return Uri.parse('$o/@$_projectSlug/$area/$suffix');
  }

  /// Ask the project which region holds [email]: the located origin if it passes the rule in
  /// `locate.dart`, else the base. A 404 (the project's locate step is off) means the base. Any
  /// other non-2xx answer is raised like any other gateway error and nothing is retried; a 2xx with a malformed body means the base.
  Future<String> _locate(String email) async {
    final base = await _resolveOrigin();
    final raw = await _postRaw('locate',
        body: {'email': email}, origin: base, notFoundIsEmpty: true);
    Object? data;
    try {
      data = (jsonDecode(raw) as Map<String, dynamic>)['data'];
    } catch (_) {
      data = null;
    }
    return chooseLocatedOrigin(base, data);
  }

  Future<AuthResult> _post(String path,
      {required Map<String, dynamic> body, String? origin}) async {
    final data = await _postData(path, body: body, origin: origin);
    try {
      return AuthResult.fromJson(data);
    } catch (e) {
      throw GateError.decoding(e);
    }
  }

  /// POST and return the envelope's `data` object.
  Future<Map<String, dynamic>> _postData(String path,
      {Map<String, dynamic>? body,
      String? origin,
      String area = 'gate',
      String? bearer}) async {
    final response = await _postRaw(path,
        body: body, origin: origin, area: area, bearer: bearer);
    try {
      final json = jsonDecode(response) as Map<String, dynamic>;
      return json['data'] as Map<String, dynamic>;
    } catch (e) {
      throw GateError.decoding(e);
    }
  }

  /// GET and return the envelope's `data` object.
  Future<Map<String, dynamic>> _getData(String path,
      {String? origin, String area = 'gate', String? bearer}) =>
      _dataOf(_postRaw(path, method: 'GET', origin: origin, area: area, bearer: bearer));

  /// DELETE and return the envelope's `data` object.
  Future<Map<String, dynamic>> _deleteData(String path,
      {Map<String, dynamic>? body,
      String? origin,
      String area = 'gate',
      String? bearer}) =>
      _dataOf(_postRaw(path,
          method: 'DELETE', body: body, origin: origin, area: area, bearer: bearer));

  Future<Map<String, dynamic>> _dataOf(Future<String> raw) async {
    final response = await raw;
    try {
      final json = jsonDecode(response) as Map<String, dynamic>;
      return json['data'] as Map<String, dynamic>;
    } catch (e) {
      throw GateError.decoding(e);
    }
  }

  Future<String> _postRaw(String path,
      {String method = 'POST',
      Map<String, dynamic>? body,
      String? origin,
      String area = 'gate',
      String? bearer,
      bool notFoundIsEmpty = false}) async {
    try {
      final headers = {
        if (body != null) HttpHeaders.contentTypeHeader: 'application/json',
        HttpHeaders.acceptHeader: 'application/json',
        if (bearer != null) HttpHeaders.authorizationHeader: 'Bearer $bearer',
        'User-Agent': 'k9o-gate-flutter',
      };
      final uri = await _uri(path, origin, area);
      final encoded = body == null ? null : jsonEncode(body);
      final http.Response response;
      switch (method) {
        case 'GET':
          response = await _httpClient.get(uri, headers: headers);
        case 'DELETE':
          response = await _httpClient.delete(uri, headers: headers, body: encoded);
        default:
          response = await _httpClient.post(uri, headers: headers, body: encoded);
      }
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return response.body;
      }
      if (notFoundIsEmpty && response.statusCode == 404) return '{}';
      throw gateErrorFromResponse(
        response.statusCode,
        response.body,
        requestId: response.headers['x-k9o-request-id'],
        redacted: _redacted,
      );
    } on GateError {
      rethrow;
    } catch (e) {
      throw GateError.network(e);
    }
  }
}
