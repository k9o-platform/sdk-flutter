# k9o_gate Flutter SDK — Changelog

## 1.5.2

### Changed

- README: Architecture at a glance, illustrations, and the package table lists only the packages for that SDK.

## 1.5.0

### Added

- The end-user flow calls: `beginPasskeyRegistration`, `finishPasskeyRegistration`, `beginPasskeySignIn`, `finishPasskeySignIn` (a wire layer: they carry the WebAuthn options and credentials and do not call the platform's passkey API), `enrollTotp`, `confirmTotp`, `listMfaMethods`, `deleteMfaMethod`, `requestPasswordReset`, `redeemPasswordReset`, `redeemInvitation` and `verifySession`, with the result types `PasskeyOptions`, `RegisteredPasskey`, `TotpEnrollment`, `TotpConfirmation`, `MfaMethod`, `MfaChallenge`, `PasswordResetRequest`, `PasswordResetResult`, `InvitationResult` and `SessionVerification`. The calls that return a session store its refresh token.
- `orgSlug` as an alternative to `orgBaseUrl`: `GateClient(orgSlug: 'acme', ...)` uses `https://acme.api.k9o.io`, and `orgBaseUrl: 'https://api.k9o.io'` with `orgSlug` gives the same. A full organization address, a regional address or a custom domain is used as given. With neither, the constructor throws a `K9OGateConfigError` (a subclass of `ArgumentError` with `code` and `context`) with code `K9O_INVALID_BASE_URL` and context `{field: 'baseUrl'}`; a malformed slug throws it with code `K9O_INVALID_FIELD_VALUE` and context `{field: 'orgSlug', slug}`.
- `signIn` first asks the project which region holds the email (one extra request with only the email) and sends the password to that region's host, if it is a region host of your own organization and apex; otherwise to the base URL. If the project's locate step answers 404, the client uses the base address. `refreshToken` and `signOut` go to the region that issued the session.
- `GateError.rateLimited` and `GateError.regionUnavailable`, raised when that step answers `429` or `503`. Nothing is retried and no password is sent.
- An unknown `K9O_*` code keeps its full wire code on `GateError.code` (for example `K9O_MAGIC_LINK_REDIRECT_NOT_CONFIGURED`), with `status`, `message`, `recommendation`, `context` and `retryAfterSec`, instead of only the raw body.
- `GateError.publicMessage`, a fixed sentence chosen by status class that an app shows to its users; `GateError.requestId` from the `x-k9o-request-id` response header.
- `GateClient(errors: 'full' | 'redacted')`, default `'full'`. Redacted mode turns an unknown code into `INTERNAL_ERROR` and drops the message, recommendation, context and raw body; a known code keeps its code, status, request id and retry hint. Any other value throws a `K9OGateConfigError`.

### Fixed

- The client follows the region-free address. Against `https://<org>.api.<host>` it asks once, without credentials, which regional host serves the org, remembers the answer and sends every request there. Sign-in and the other calls no longer answer `400 K9O_INVALID_REQUEST_SHAPE`. A regional address, `localhost` or any other host is used as given.

## 1.4.0 — 2026-10-26

### Changed

- README description.

## 1.3.0 — 2026-10-26

### Changed

- `refreshToken({refreshToken})` takes only the refresh token and returns a `RefreshResult` with `accessToken` and `expiresAt`.
- `refreshToken` no longer replaces the stored refresh token. The gateway does not rotate it.
- `signOut({refreshToken})` returns a `bool`: `true` when a live session was revoked.
- `AccessToken.customClaims` returns the flat `ext.<namespace>.<name>` keys of the token.
- Response fields are read as the gateway sends them (camelCase).

### Removed

- The `projectHint` argument of `refreshToken`. The gateway rejects it.

### Added

- `RefreshResult`.
- `AccessToken.customClaim(namespace, name)` reads one custom claim.


## 1.2.0 — 2026-10-25

- The README now introduces the Kilimanjaro building blocks (Keep, Pulse, Gate, Kibo). No change to the public API.

## 1.1.1 — 2026-10-25

- Documentation links corrected: the documentation hub is https://docs.kilimanjaro.dev,
  with the website, platform API and console listed in a Links section.
  Package metadata points at the same places.

## 1.1.0 — 2026-10-25

- Documentation rewritten with runnable examples and expected output; internal cross-references removed from the published sources.
  No change to the public API.

## 1.0.0 — 2026-10-23

First public release. See the README for the full API overview.
