import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Holds secrets (the Google Maps API key, the Mac's Google sign-in)
/// outside of normal app storage.
abstract class SecretStore {
  /// The key as loaded at startup (or last saved).
  String? get apiKey;

  /// Saves the key, or removes it when [key] is null or blank.
  Future<void> setApiKey(String? key);

  /// The Stripe restricted (read-only) key, as loaded at startup (or last
  /// saved).
  String? get stripeKey;

  /// Saves the Stripe key, or removes it when [key] is null or blank.
  Future<void> setStripeKey(String? key);

  Future<String?> read(String name);

  /// Writes [value], or deletes the entry when [value] is null.
  Future<void> write(String name, String? value);
}

/// Android Keystore / macOS Keychain, via flutter_secure_storage.
class SecureSecretStore implements SecretStore {
  SecureSecretStore._(this._storage, this._apiKey, this._stripeKey);

  static const _apiKeyName = 'google_maps_api_key';
  static const _stripeKeyName = 'stripe_restricted_key';

  final FlutterSecureStorage _storage;
  String? _apiKey;
  String? _stripeKey;

  static Future<SecureSecretStore> load() async {
    // On macOS, use the regular login keychain. The default "data
    // protection" keychain only accepts apps signed with an Apple
    // Developer team, so unsigned builds fail to save there.
    const storage = FlutterSecureStorage(
      mOptions: MacOsOptions(usesDataProtectionKeychain: false),
    );
    // Unreadable keychain entries: treat as not set; they can be re-entered.
    Future<String?> load(String name) async {
      try {
        return await storage.read(key: name);
      } catch (_) {
        return null;
      }
    }

    return SecureSecretStore._(
      storage,
      await load(_apiKeyName),
      await load(_stripeKeyName),
    );
  }

  @override
  String? get stripeKey => _stripeKey;

  @override
  Future<void> setStripeKey(String? key) async {
    final trimmed = key?.trim();
    final value = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    await write(_stripeKeyName, value);
    _stripeKey = value;
  }

  @override
  String? get apiKey => _apiKey;

  @override
  Future<void> setApiKey(String? key) async {
    final trimmed = key?.trim();
    final value = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    await write(_apiKeyName, value);
    _apiKey = value;
  }

  @override
  Future<String?> read(String name) async {
    try {
      return await _storage.read(key: name);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String name, String? value) => value == null
      ? _storage.delete(key: name)
      : _storage.write(key: name, value: value);
}

/// In-memory store for tests.
class MemorySecretStore implements SecretStore {
  MemorySecretStore([this._apiKey]);
  String? _apiKey;
  String? _stripeKey;
  final Map<String, String> _values = {};

  @override
  String? get stripeKey => _stripeKey;

  @override
  Future<void> setStripeKey(String? key) async {
    final trimmed = key?.trim();
    _stripeKey = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  @override
  String? get apiKey => _apiKey;

  @override
  Future<void> setApiKey(String? key) async {
    final trimmed = key?.trim();
    _apiKey = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  @override
  Future<String?> read(String name) async => _values[name];

  @override
  Future<void> write(String name, String? value) async {
    if (value == null) {
      _values.remove(name);
    } else {
      _values[name] = value;
    }
  }
}
