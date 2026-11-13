import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const _kRefreshTokenKey = 'k9o_gate_refresh_token';

/// Refresh-token persistence backed by `flutter_secure_storage`.
///
/// On iOS this wraps the Keychain; on Android it uses the Android
/// Keystore-backed `EncryptedSharedPreferences`. Token material never
/// leaves the device.
///
/// Use the [TokenStore] interface for dependency injection in tests.
class SecureTokenStore implements TokenStore {
  final FlutterSecureStorage _storage;

  const SecureTokenStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<void> save(String token) =>
      _storage.write(key: _kRefreshTokenKey, value: token);

  @override
  Future<String?> load() => _storage.read(key: _kRefreshTokenKey);

  @override
  Future<void> delete() => _storage.delete(key: _kRefreshTokenKey);
}

/// Minimal token-store interface for injection and testing.
abstract interface class TokenStore {
  Future<void> save(String token);
  Future<String?> load();
  Future<void> delete();
}
