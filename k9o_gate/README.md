# k9o_gate

Official Flutter SDK for [Kilimanjaro](#115-about-kilimanjaro) Gate.
Sign users in from your Flutter app with Gate: sign in, refresh the session and sign out,
with the refresh token kept in the platform's secure storage.
A Gate token also scopes each data request to the signed-in user.

## Contents

**A. Get started**

1. [Links](#1-links)
2. [Install](#2-install)
3. [Choose the right package](#3-choose-the-right-package)
4. [Requirements](#4-requirements)
5. [Quick start](#5-quick-start)

**B. Sessions**

6. [Refresh and sign out](#6-refresh-and-sign-out)
   - 6.1 [Passkeys, authenticator apps, password reset and invitations](#61-passkeys-authenticator-apps-password-reset-and-invitations)
7. [Session lifetime](#7-session-lifetime)
8. [Secure storage](#8-secure-storage)

**C. Use the token**

9. [Read token claims](#9-read-token-claims)

**D. Troubleshoot**

10. [Handle errors](#10-handle-errors)

**E. Reference**

11. [Appendix](#11-appendix)
    - 11.1 [Client options](#111-client-options)
    - 11.2 [Error fields](#112-error-fields)
    - 11.3 [Methods](#113-methods)
    - 11.4 [Types](#114-types)
    - 11.5 [About Kilimanjaro](#115-about-kilimanjaro)
12. [License](#12-license)

## A. Get started

### 1. Links

- Website: <https://kilimanjaro.dev>
- Documentation / Developer Hub: <https://docs.kilimanjaro.dev>
- API: <https://api.k9o.io>
- Console: <https://console.k9o.io>
- Open source
  - Platform: <https://github.com/k9o-platform>
  - Community: <https://github.com/k9o-community>

### 2. Install

```bash
flutter pub add k9o_gate:^1.5.0
```

### 3. Choose the right package

| Package | Use it when you are… | Registry | Source |
| --- | --- | --- | --- |
| `k9o_core` | Calling the platform from a Flutter app as a signed-in user. | [pub.dev](https://pub.dev/packages/k9o_core) | [sdk-flutter](https://github.com/k9o-platform/sdk-flutter) |
| `k9o_gate` | Signing users in: sign in, refresh and sign out. | [pub.dev](https://pub.dev/packages/k9o_gate) | [sdk-flutter](https://github.com/k9o-platform/sdk-flutter) |
| `k9o_kibo` | Storing, listing and revealing secrets in the vault. | [pub.dev](https://pub.dev/packages/k9o_kibo) | [sdk-kibo-flutter](https://github.com/k9o-platform/sdk-kibo-flutter) |

### 4. Requirements

- Flutter 3.10 or later
- Dart 3.0 or later
- iOS or Android

### 5. Quick start

The examples sign in an end user of a project called `tasks-app`, which belongs to the organization `acme`.

```dart
import 'package:k9o_gate/k9o_gate.dart';

final gate = GateClient(
  orgBaseUrl: 'https://acme.api.k9o.io',
  projectSlug: 'tasks-app',
);

final result = await gate.signIn(
  email: 'alice@example.com',
  password: 'a-strong-password',
);

print('Signed in as ${result.user.email} (${result.user.id})');
print('Access token expires at ${result.session.expiresAt}');
```

```text
Signed in as alice@example.com (eu_...)
Access token expires at 2026-01-01T12:00:00Z
```

`orgBaseUrl` is your organization's address. The client asks it once, without credentials, which regional host serves your organization, remembers the answer and sends every request there. You can also pass the regional address (`https://acme.api-de01.k9o.io`) and it is used as given. `signIn` saves the refresh token in secure storage for you.

`signIn` first asks the project which region holds the email: one extra request that carries only the email. The SDK sends the password only to a region host of your own organization and apex, and otherwise to the base URL. Nothing from that step is cached, apart from a note of which region issued the session so that refresh and sign-out go to the same place. A `429` or `503` from that step is raised as the usual `GateError` (`GateError.rateLimited` or `GateError.regionUnavailable`) and is safe to retry. If the project's locate step answers 404, the client uses the base address.

See all [client options](#111-client-options).

## B. Sessions

### 6. Refresh and sign out

With no argument, `refreshToken()` uses the stored refresh token and returns a new access token, the next refresh token and the access token's expiry.
Each refresh replaces the refresh token: the one you sent stops working. The client saves the new one to secure storage before `refreshToken()` returns, and it refreshes one at a time, so calls made together share one request and a token is never sent twice.

```dart
final refreshed = await gate.refreshToken();

print('New access token expires at ${refreshed.expiresAt}');
```

```text
New access token expires at 2026-01-01T13:00:00Z
```

`signOut()` revokes the session and deletes the stored refresh token. It returns `true` when a live session was revoked.

```dart
final revoked = await gate.signOut();

print('Revoked: $revoked');
```

```text
Revoked: true
```

See all [methods](#113-methods).

#### 6.1 Passkeys, authenticator apps, password reset and invitations

These calls carry the data between your app and the gateway. The passkey calls are a wire layer: they do not call the platform's passkey API. Pass the options from `beginPasskeyRegistration` or `beginPasskeySignIn` (`options.raw`, the JSON form of the WebAuthn options) to that API, and pass the credential it makes, in its JSON form, to the matching `finish` call.

| Call | Needs | Answer |
|---|---|---|
| `beginPasskeyRegistration(accessToken:)` | The end user's access token | `PasskeyOptions` (`challenge`, `raw`) |
| `finishPasskeyRegistration(accessToken:, response:, label:)` | The end user's access token and the authenticator's credential | `RegisteredPasskey` (`id`, `credentialId`) |
| `beginPasskeySignIn(email:)` | Nothing; `email` is optional | `PasskeyOptions` |
| `finishPasskeySignIn(response:)` | The authenticator's assertion | `Session`; the refresh token is stored |
| `enrollTotp(accessToken:, label:)` | The end user's access token | `TotpEnrollment` (`factorId`, `secret`, `uri`); the secret is shown once |
| `confirmTotp(accessToken:, factorId:, code:, currentCode:)` | The end user's access token and a current code | `TotpConfirmation`; `session` is set for a first authenticator, and its refresh token is stored |
| `listMfaMethods(accessToken:)` | The end user's access token | `List<MfaMethod>` (`id`, `type`, `label`, `verifiedAt`, `createdAt`), oldest first; `verifiedAt` is null while setup is pending |
| `deleteMfaMethod(accessToken:, methodId:, code:)` | The end user's access token; `code` is the authenticator's current code, needed to remove a confirmed one | `true` when a method was removed, `false` when none matched |
| `requestPasswordReset(email:)` | Nothing | `PasswordResetRequest`; the answer is the same whether or not the address has an account |
| `redeemPasswordReset(token:, newPassword:)` | The token from the email | `PasswordResetResult` with a `session` (stored), or an `mfa` challenge and no session |
| `redeemInvitation(token:, password:, displayName:)` | The token from the invitation | `InvitationResult` (`userId`, `email`, `session`); the refresh token is stored |
| `verifySession(bearerToken:, token:)` | Your backend's credential as `bearerToken`, and the access token to check | `SessionVerification`; a refused token has `valid` `false` and a `reason` |

```dart
final enrollment = await gate.enrollTotp(accessToken: accessToken, label: 'Phone app');
// Show enrollment.uri as a QR code, then confirm with the first code the app shows.
final confirmed = await gate.confirmTotp(
  accessToken: accessToken,
  factorId: enrollment.factorId,
  code: '123456',
);
```

```dart
final methods = await gate.listMfaMethods(accessToken: accessToken);
final removed = await gate.deleteMfaMethod(
  accessToken: accessToken,
  methodId: methods.first.id,
  code: '123456',
);
```

Removing a confirmed authenticator without its current `code` throws a `GateError` with code `K9O_MFA_REQUIRED`.

A wrong or expired code, a used or expired token and a refused credential throw a `GateError`. To add a second authenticator, `confirmTotp` also needs `currentCode` from one already confirmed; without it the gateway answers `K9O_MFA_REQUIRED`.

### 7. Session lifetime

Three settings control how long an end user's session lasts. A project administrator sets them for the project in the Console, under the project's Gate settings, Sessions. The values below are the defaults, and each has a range:

| Setting | Default | Range |
|---|---|---|
| Access token lifetime | 30 minutes | 5 to 60 minutes |
| Sign out after inactivity | 30 days | 1 hour to 90 days |
| Maximum session length | 90 days | 1 hour to 365 days |

Refresh is where the limits are checked. Inactivity counts from the last successful refresh, so it is measured to within one access-token lifetime. A refresh token never outlasts either limit. A changed setting applies to existing sessions at their next refresh, and a shorter maximum ends the sessions already past it.

- **A refresh token works once.** Each refresh answers a new refresh token and the old one stops working. Sending an old one again counts as a replay: the gateway ends the session, and `refreshToken()` throws `GateError.unauthenticated` with `status` 401 and `sessionEndReason` `'replay'`. The new token then fails the same way, with `'revoked'`. The client deletes the stored token on any of these, and the user must sign in again.
- **A session that has ended says why.** `sessionEndReason` is `'inactive'` (past the sign-out-after-inactivity limit), `'max_length'` (past the maximum session length), `'revoked'` (signed out, ended by a password reset, or ended by `revokeAllSessions`) or `'replay'` (see above). It is kept when `errors` is `'redacted'`. A token the gateway does not know, or one for a locked user, throws `GateError.invalidCredentials` and also deletes the stored token.
- **Keep your own refresh token only if you must.** If your app keeps a copy outside the token store, replace it with the `refreshToken` that each refresh returns, and never refresh from two places at once.
- **`signOut` ends this device's session.** It revokes the session that the stored refresh token belongs to. The same user's sessions on other devices stay valid.
- **`revokeAllSessions(accessToken: ...)` ends every session of the user.** Pass the access token that `signIn` or `refreshToken` returned, not a refresh token. It ends the user's sessions on every device, this one included, deletes the stored refresh token and returns how many sessions ended. Each ended session's next refresh is refused with `K9O_SESSION_EXPIRED`; `GateError.sessionEndReason` is `'revoked'`. An operator's token is refused with `K9O_TRUST_ZONE_VIOLATION` (403), and a token issued for another project with `K9O_PROJECT_SCOPE_MISMATCH` (403). The stored token is left as it was when the call fails. Access tokens already issued keep working until they expire, so drop yours too.
- **An access token outlives sign-out.** One that was already issued keeps working until it expires, up to the access token lifetime you set, because it carries no session id and Gate keeps no list of revoked access tokens. The exception is a user who is no longer active: a locked or erased user's access tokens are refused at once.
- **A session that has passed a limit is refused.** The refresh answers 401 `K9O_SESSION_EXPIRED`, and `context.reason` is `inactive`, `max_length`, `revoked` (after sign-out) or `replay` (a used refresh token sent again). Send the user through sign-in again.
- **A password reset ends every existing session of that user.** The session the reset itself opens stays. Erasing a user locks them and revokes every session; an administrator's reset of a user's second factor also revokes every session.

### 8. Secure storage

By default the refresh token is kept with `flutter_secure_storage`. That is the Keychain on iOS and encrypted storage on Android.

To store tokens elsewhere, implement `TokenStore` and pass it to the client.

```dart
class MemoryTokenStore implements TokenStore {
  String? _token;

  @override
  Future<void> save(String token) async => _token = token;

  @override
  Future<String?> load() async => _token;

  @override
  Future<void> delete() async => _token = null;
}

final gate = GateClient(
  orgBaseUrl: 'https://acme.api.k9o.io',
  projectSlug: 'tasks-app',
  tokenStore: MemoryTokenStore(),
);
```

## C. Use the token

### 9. Read token claims

`AccessToken.decode` reads an access token on the device. It does not verify the signature, so do not use it for security decisions.

It returns `null` if the string is not a JWT.

Custom claims are flat keys of the form `ext.<namespace>.<name>`. `customClaim(namespace, name)` reads one of them.

```dart
final token = AccessToken.decode(result.session.accessToken);
if (token != null) {
  final role = token.customClaim('partners', 'partner_role');
  print('Partner role: $role');
}
```

```text
Partner role: extension_org_admin
```

`customClaims` returns every `ext.` claim, keyed by its full name, for example `ext.partners.partner_role`.

## D. Troubleshoot

### 10. Handle errors

Every call throws a `GateError`. Its `toString()` starts with the kind of error.

```dart
try {
  await gate.signIn(email: 'alice@example.com', password: 'wrong-password');
} on GateError catch (error) {
  print(error);
}
```

```text
GateError.invalidCredentials: Invalid credentials.
```

See all [error cases](#112-error-fields).

An app shows `publicMessage` to its users. It is a fixed sentence chosen by status class, never the gateway's text. Log `requestId` so support can find the request. `code`, `status`, `message`, `recommendation`, `context` and `retryAfterSec` are for logs. The `errors` option decides how much of the gateway's answer the error keeps: `'full'` (the default) keeps all of it, and `'redacted'` keeps only what is safe to show or to act on. An unknown code becomes `INTERNAL_ERROR` in redacted mode, and a known code keeps its `code`, `status`, `requestId` and `retryAfterSec`.

| Field or option | Meaning |
|---|---|
| `publicMessage` | A fixed sentence for your users, chosen by status class only |
| `requestId` | The `x-k9o-request-id` response header; null when the gateway sent none |
| `errors` | `GateClient` option: `'full'` (default) or `'redacted'`. Any other value throws a `K9OGateConfigError` |

## E. Reference

### 11. Appendix

- [Client options](#111-client-options)
- [Error fields](#112-error-fields)
- [Methods](#113-methods)
- [Types](#114-types)
- [About Kilimanjaro](#115-about-kilimanjaro)

#### 11.1 Client options

`GateClient(orgBaseUrl:, orgSlug:, projectSlug:, tokenStore:, httpClient:)`

| Option | Meaning |
|---|---|
| `orgBaseUrl` | Your organization's address, for example `https://acme.api.k9o.io`; a regional address such as `https://acme.api-de01.k9o.io` also works; optional when `orgSlug` is given |
| `orgSlug` | Your organization's slug, for example `acme`; the client uses `https://acme.api.k9o.io`. Optional when `orgBaseUrl` is given |
| `projectSlug` | The project's slug |
| `tokenStore` | A `TokenStore`; default is `SecureTokenStore` |
| `httpClient` | A `package:http` `Client`; useful in tests |

Pass `orgSlug` to use your organization's host without writing the address. A full organization `orgBaseUrl` or a custom domain is used as given, and `orgSlug` does not change it. With neither `orgBaseUrl` nor `orgSlug`, construction throws a `K9OGateConfigError` (an `ArgumentError`) with code `K9O_INVALID_BASE_URL` and context `{field: 'baseUrl'}`. A malformed `orgSlug` throws it with code `K9O_INVALID_FIELD_VALUE` and context `{field: 'orgSlug', slug: <the value>}`; read `code` and `context` on the error.

#### 11.2 Error fields

| Kind | Meaning |
|---|---|
| `GateError.invalidCredentials` | The email or password did not match |
| `GateError.rateLimited` | Too many sign-in attempts; safe to retry |
| `GateError.regionUnavailable` | The region that holds the email is unavailable; safe to retry |
| `GateError.unauthenticated` | The session is missing, expired or revoked, or no refresh token is stored. `sessionEndReason` says why when the gateway ended the session |
| `GateError.forbidden` | The session may not perform this operation |
| `GateError.network` | The request failed in transit |
| `GateError.decoding` | The response was not in the expected shape |
| `GateError.unknown` | Any other non-2xx response, with the status and raw body |

#### 11.3 Methods

| Method | Meaning |
|---|---|
| `signIn(email:, password:)` | Sign in; returns `AuthResult` |
| `refreshToken({refreshToken})` | Get a new access token; returns `RefreshResult` |
| `signOut({refreshToken})` | End the session; returns `true` when a live session was revoked |
| `revokeAllSessions({accessToken})` | End every session of the user, on every device, and delete the stored token; returns how many ended |
| `beginPasskeyRegistration`, `finishPasskeyRegistration`, `beginPasskeySignIn`, `finishPasskeySignIn` | Passkey calls (wire layer); see [6.1](#61-passkeys-authenticator-apps-password-reset-and-invitations) |
| `enrollTotp`, `confirmTotp` | Set up an authenticator app |
| `listMfaMethods`, `deleteMfaMethod` | List and remove the end user's second-factor methods |
| `requestPasswordReset`, `redeemPasswordReset` | Reset a password by email |
| `redeemInvitation(token:, password:, displayName:)` | Accept an invitation |
| `verifySession(bearerToken:, token:)` | Check an end user's access token from your backend |
| `AccessToken.decode(jwt)` | Read a token's claims on the device; `null` if not a JWT |
| `customClaim(namespace, name)` | One `ext.<namespace>.<name>` claim, or `null` |

#### 11.4 Types

| Type | Fields or purpose |
|---|---|
| `AuthResult` | `user`, `session` |
| `EndUser` | `id`, `email`, `status`, `createdAt`, `updatedAt`, `lastSigninAt`, `roles`, `groups` |
| `Session` | `accessToken`, `refreshToken`, `expiresAt` |
| `RefreshResult` | `accessToken`, `refreshToken`, `expiresAt` |
| `PasskeyOptions` | `challenge`, `raw` |
| `RegisteredPasskey` | `id`, `credentialId` |
| `TotpEnrollment` | `factorId`, `secret`, `uri` |
| `TotpConfirmation` | `factorId`, `verifiedAt`, `session` |
| `MfaMethod` | `id`, `type`, `label`, `verifiedAt`, `createdAt` |
| `MfaChallenge` | `challengeId`, `expiresAt`, `methodsAvailable`, `region`, `origin` |
| `PasswordResetRequest` | `requested`, `expiresAt`, `debugToken` |
| `PasswordResetResult` | `endUserId`, `session`, `mfa` |
| `InvitationResult` | `userId`, `email`, `session` |
| `SessionVerification` | `valid`, `subjectId`, `projectId`, `expiresAt`, `reason` |
| `AccessToken` | `subject`, `issuer`, `expiresAt`, `issuedAt`, `allClaims`, `customClaims` (flat `ext.` keys) |
| `TokenStore` | Interface with `save`, `load` and `delete` |
| `SecureTokenStore` | The default `TokenStore` |

#### 11.5 About Kilimanjaro

Kilimanjaro is a modular developer platform for building secure enterprise applications.
You define AI agents, functions and data pipelines on the platform.
The SDKs let you deploy and invoke them, read and write your data, publish to and subscribe to streams, sign users in, and encrypt with keys you hold.

It provides four building blocks:

- **Keep**: AI security and governance. Guardrails and policy for the agents you run.
- **Pulse**: data intelligence and real-time stream processing. Streams, analytics and live feeds.
- **Gate**: customer identity and access management. Sign-in and sessions, and automatic data scoping so a signed-in user reaches only their own data.
- **Kibo**: cryptographic keys and secrets management. Client-side encryption with keys you hold, and a secrets vault.

### 12. License

Apache-2.0 © Formelo Inc. See `LICENSE` and `NOTICE`.
