import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Holds the Google Maps API key outside of normal app storage.
abstract class SecretStore {
  /// The key as loaded at startup (or last saved).
  String? get apiKey;

  /// Saves the key, or removes it when [key] is null or blank.
  Future<void> setApiKey(String? key);
}

/// Android Keystore / macOS Keychain, via flutter_secure_storage.
class SecureSecretStore implements SecretStore {
  SecureSecretStore._(this._storage, this._apiKey);

  static const _apiKeyName = 'google_maps_api_key';

  final FlutterSecureStorage _storage;
  String? _apiKey;

  static Future<SecureSecretStore> load() async {
    const storage = FlutterSecureStorage();
    String? key;
    try {
      key = await storage.read(key: _apiKeyName);
    } catch (_) {
      // Unreadable keychain entry: treat as not set; the user can re-enter it.
      key = null;
    }
    return SecureSecretStore._(storage, key);
  }

  @override
  String? get apiKey => _apiKey;

  @override
  Future<void> setApiKey(String? key) async {
    final trimmed = key?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      await _storage.delete(key: _apiKeyName);
      _apiKey = null;
    } else {
      await _storage.write(key: _apiKeyName, value: trimmed);
      _apiKey = trimmed;
    }
  }
}

/// In-memory store for tests.
class MemorySecretStore implements SecretStore {
  MemorySecretStore([this._apiKey]);
  String? _apiKey;

  @override
  String? get apiKey => _apiKey;

  @override
  Future<void> setApiKey(String? key) async {
    final trimmed = key?.trim();
    _apiKey = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }
}
