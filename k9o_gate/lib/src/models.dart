import 'dart:convert';

// MARK: - Core model types

/// Project-level end-user identity. IDs carry the `eu_` prefix.
class EndUser {
  final String id;
  final String email;
  final String status;
  final String createdAt;
  final String? updatedAt;
  final String? lastSigninAt;
  final List<String> roles;
  final List<String> groups;

  const EndUser({
    required this.id,
    required this.email,
    required this.status,
    required this.createdAt,
    this.updatedAt,
    this.lastSigninAt,
    required this.roles,
    required this.groups,
  });

  factory EndUser.fromJson(Map<String, dynamic> json) => EndUser(
        id: json['id'] as String,
        email: json['email'] as String,
        status: json['status'] as String,
        createdAt: json['createdAt'] as String,
        updatedAt: json['updatedAt'] as String?,
        lastSigninAt: json['lastSigninAt'] as String?,
        roles: (json['roles'] as List<dynamic>).cast<String>(),
        groups: (json['groups'] as List<dynamic>).cast<String>(),
      );
}

/// Session tokens returned by sign-in.
class Session {
  final String accessToken;
  final String refreshToken;
  final String expiresAt;

  const Session({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });

  factory Session.fromJson(Map<String, dynamic> json) => Session(
        accessToken: json['accessToken'] as String,
        refreshToken: json['refreshToken'] as String,
        expiresAt: json['expiresAt'] as String,
      );
}

/// Returned by refreshToken: a new access token, the next refresh token and
/// the access token's expiry. No user.
class RefreshResult {
  final String accessToken;

  /// The next refresh token. The client has already stored it; the one you
  /// sent no longer works.
  final String refreshToken;
  final String expiresAt;

  const RefreshResult({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });

  factory RefreshResult.fromJson(Map<String, dynamic> json) => RefreshResult(
        accessToken: json['accessToken'] as String,
        refreshToken: json['refreshToken'] as String,
        expiresAt: json['expiresAt'] as String,
      );
}

/// Returned by signIn.
class AuthResult {
  final EndUser user;
  final Session session;

  const AuthResult({required this.user, required this.session});

  factory AuthResult.fromJson(Map<String, dynamic> json) => AuthResult(
        user: EndUser.fromJson(json['user'] as Map<String, dynamic>),
        session: Session.fromJson(json['session'] as Map<String, dynamic>),
      );
}

// MARK: - End-user flows (passkeys, authenticator apps, password reset, invitations, session check)

/// WebAuthn options as the gateway returns them: the JSON form of `PublicKeyCredentialCreationOptions` (registration)
/// or `PublicKeyCredentialRequestOptions` (sign-in), with the challenge and ids base64url-encoded. [raw] is the whole
/// object, to hand to the platform's passkey API; the SDK does not call that API.
class PasskeyOptions {
  final String challenge;
  final Map<String, dynamic> raw;

  const PasskeyOptions({required this.challenge, required this.raw});

  factory PasskeyOptions.fromJson(Map<String, dynamic> json) =>
      PasskeyOptions(challenge: json['challenge'] as String, raw: json);
}

/// The passkey `finishPasskeyRegistration` stored.
class RegisteredPasskey {
  final String id;
  final String credentialId;

  const RegisteredPasskey({required this.id, required this.credentialId});

  factory RegisteredPasskey.fromJson(Map<String, dynamic> json) {
    final passkey = json['passkey'] as Map<String, dynamic>;
    return RegisteredPasskey(
      id: passkey['id'] as String,
      credentialId: passkey['credentialId'] as String,
    );
  }
}

/// A started authenticator-app setup. The secret and the `otpauth://` uri are shown once; the factor does nothing
/// until `confirmTotp` succeeds.
class TotpEnrollment {
  final String factorId;
  final String secret;
  final String uri;

  const TotpEnrollment({
    required this.factorId,
    required this.secret,
    required this.uri,
  });

  factory TotpEnrollment.fromJson(Map<String, dynamic> json) {
    final factor = json['factor'] as Map<String, dynamic>;
    return TotpEnrollment(
      factorId: factor['id'] as String,
      secret: factor['secret'] as String,
      uri: factor['uri'] as String,
    );
  }
}

/// One second-factor method of an end user. [type] is `totp` or `webauthn`. [verifiedAt] is null while setup is
/// pending, and the method is not usable until then.
class MfaMethod {
  final String id;
  final String type;
  final String? label;
  final String? verifiedAt;
  final String createdAt;

  const MfaMethod({
    required this.id,
    required this.type,
    this.label,
    this.verifiedAt,
    required this.createdAt,
  });

  factory MfaMethod.fromJson(Map<String, dynamic> json) => MfaMethod(
        id: json['id'] as String,
        type: json['type'] as String,
        label: json['label'] as String?,
        verifiedAt: json['verifiedAt'] as String?,
        createdAt: json['createdAt'] as String,
      );
}

/// A confirmed authenticator app. [session] is set when this is the person's first confirmed authenticator: their
/// other sessions end and this one is returned.
class TotpConfirmation {
  final String factorId;
  final String verifiedAt;
  final Session? session;

  const TotpConfirmation({
    required this.factorId,
    required this.verifiedAt,
    this.session,
  });

  factory TotpConfirmation.fromJson(Map<String, dynamic> json) {
    final factor = json['factor'] as Map<String, dynamic>;
    final session = json['session'];
    return TotpConfirmation(
      factorId: factor['id'] as String,
      verifiedAt: factor['verifiedAt'] as String,
      session: session == null
          ? null
          : Session.fromJson(session as Map<String, dynamic>),
    );
  }
}

/// A sign-in that needs a second step: a code from a confirmed authenticator, redeemed with [challengeId].
class MfaChallenge {
  final String challengeId;
  final String expiresAt;
  final List<String> methodsAvailable;
  final String region;
  final String origin;

  const MfaChallenge({
    required this.challengeId,
    required this.expiresAt,
    required this.methodsAvailable,
    required this.region,
    required this.origin,
  });

  factory MfaChallenge.fromJson(Map<String, dynamic> json) {
    final resident = json['resident'] as Map<String, dynamic>;
    return MfaChallenge(
      challengeId: json['challengeId'] as String,
      expiresAt: json['expiresAt'] as String,
      methodsAvailable: (json['methodsAvailable'] as List<dynamic>).cast<String>(),
      region: resident['region'] as String,
      origin: resident['origin'] as String,
    );
  }
}

/// The answer to `requestPasswordReset`. It is the same whether or not the address has an account.
class PasswordResetRequest {
  final bool requested;
  final String? expiresAt;

  /// Only set on a deployment configured to return the token in the response (development).
  final String? debugToken;

  const PasswordResetRequest({
    required this.requested,
    this.expiresAt,
    this.debugToken,
  });

  factory PasswordResetRequest.fromJson(Map<String, dynamic> json) {
    final reset = json['reset'] as Map<String, dynamic>;
    return PasswordResetRequest(
      requested: reset['requested'] == true,
      expiresAt: reset['expiresAt'] as String?,
      debugToken: json['debugToken'] as String?,
    );
  }
}

/// The answer to `redeemPasswordReset`: a [session], or an [mfa] challenge when the account has a confirmed
/// authenticator (then there is no session).
class PasswordResetResult {
  final String endUserId;
  final Session? session;
  final MfaChallenge? mfa;

  const PasswordResetResult({required this.endUserId, this.session, this.mfa});

  factory PasswordResetResult.fromJson(Map<String, dynamic> json) {
    final session = json['session'];
    final mfa = json['mfa'];
    return PasswordResetResult(
      endUserId: json['endUserId'] as String,
      session: session == null
          ? null
          : Session.fromJson(session as Map<String, dynamic>),
      mfa: mfa == null ? null : MfaChallenge.fromJson(mfa as Map<String, dynamic>),
    );
  }
}

/// The answer to `redeemInvitation`: the new end user and a session.
class InvitationResult {
  final String userId;
  final String email;
  final Session session;

  const InvitationResult({
    required this.userId,
    required this.email,
    required this.session,
  });

  factory InvitationResult.fromJson(Map<String, dynamic> json) {
    final user = json['user'] as Map<String, dynamic>;
    return InvitationResult(
      userId: user['id'] as String,
      email: user['email'] as String,
      session: Session.fromJson(json['session'] as Map<String, dynamic>),
    );
  }
}

/// The answer to `verifySession`. A refused token is an answer with [valid] `false` and a [reason], not an error.
class SessionVerification {
  final bool valid;
  final String? subjectId;
  final String? projectId;
  final String? expiresAt;
  final String? reason;

  const SessionVerification({
    required this.valid,
    this.subjectId,
    this.projectId,
    this.expiresAt,
    this.reason,
  });

  factory SessionVerification.fromJson(Map<String, dynamic> json) {
    final claims = json['claims'];
    final c = claims is Map<String, dynamic> ? claims : null;
    return SessionVerification(
      valid: json['valid'] == true,
      subjectId: c?['subjectId'] as String?,
      projectId: c?['projectId'] as String?,
      expiresAt: c?['expiresAt'] as String?,
      reason: json['reason'] as String?,
    );
  }
}

// MARK: - Lightweight JWT access-token decoder

/// Lightweight access-token decoder. Decodes the JWT payload without
/// signature verification. Custom claims are FLAT top-level keys of the form
/// `ext.<namespace>.<name>` (the dots are part of the key; there is no nested
/// object).
class AccessToken {
  final String? subject;
  final DateTime? expiresAt;
  final DateTime? issuedAt;
  final String? issuer;
  final Map<String, dynamic> allClaims;

  const AccessToken({
    required this.subject,
    required this.expiresAt,
    required this.issuedAt,
    required this.issuer,
    required this.allClaims,
  });

  /// Custom claims keyed by their full wire key (`ext.<namespace>.<name>`):
  /// `customClaims['ext.partners.partner_role']` → "extension_org_admin".
  Map<String, dynamic> get customClaims => {
        for (final e in allClaims.entries)
          if (e.key.startsWith('ext.')) e.key: e.value,
      };

  /// One custom claim by namespace and name: reads the flat key
  /// `ext.<namespace>.<name>`.
  dynamic customClaim(String namespace, String name) =>
      allClaims['ext.$namespace.$name'];

  /// Decode a raw JWT string. Returns null if not a valid 3-part JWT.
  static AccessToken? decode(String jwt) {
    final parts = jwt.split('.');
    if (parts.length != 3) return null;
    try {
      var payload = parts[1]
          .replaceAll('-', '+')
          .replaceAll('_', '/');
      final rem = payload.length % 4;
      if (rem == 2) payload += '==';
      if (rem == 3) payload += '=';
      final decoded = utf8.decode(base64Decode(payload));
      final Map<String, dynamic> claims =
          jsonDecode(decoded) as Map<String, dynamic>;
      return AccessToken(
        subject: claims['sub'] as String?,
        expiresAt: claims['exp'] != null
            ? DateTime.fromMillisecondsSinceEpoch(
                ((claims['exp'] as num) * 1000).toInt(),
                isUtc: true)
            : null,
        issuedAt: claims['iat'] != null
            ? DateTime.fromMillisecondsSinceEpoch(
                ((claims['iat'] as num) * 1000).toInt(),
                isUtc: true)
            : null,
        issuer: claims['iss'] as String?,
        allClaims: claims,
      );
    } catch (_) {
      return null;
    }
  }
}
