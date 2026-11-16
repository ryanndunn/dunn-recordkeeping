import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';
import '../models/saved_address.dart';
import '../models/trip.dart';

/// On-device copy of clients, trips and settings, so the app works
/// offline. Settings and clients sync through Google Drive; trips go to the
/// spreadsheet.
class LocalStore {
  LocalStore(this._prefs);

  final SharedPreferences _prefs;

  static const _addressesKey = 'addresses_v1';
  static const _tripsKey = 'trips_v1';
  static const _settingsKey = 'settings_v1';
  static const _distanceCacheKey = 'distance_cache_v1';
  static const _pendingDeletesKey = 'pending_sheet_deletes_v1';
  static const _autoTripsKey = 'auto_trips_enabled_v1';
  static const _googleEmailKey = 'google_account_email_v1';
  static const _clientDeletionsKey = 'client_deletions_v1';

  /// Whether the phone logs trips on arrival at saved addresses.
  bool get autoTripsEnabled => _prefs.getBool(_autoTripsKey) ?? false;

  Future<void> setAutoTripsEnabled(bool on) =>
      _prefs.setBool(_autoTripsKey, on);

  /// Signed-in Google account, so background uploads use the right one.
  String? get googleEmail => _prefs.getString(_googleEmailKey);

  Future<void> setGoogleEmail(String? email) => email == null
      ? _prefs.remove(_googleEmailKey)
      : _prefs.setString(_googleEmailKey, email);

  /// Trips deleted here that still need removing from the spreadsheet.
  Set<String> loadPendingDeletes() =>
      (_prefs.getStringList(_pendingDeletesKey) ?? const []).toSet();

  Future<void> savePendingDeletes(Set<String> ids) =>
      _prefs.setStringList(_pendingDeletesKey, ids.toList());

  /// Clients deleted on this device and when, so the deletion reaches the
  /// other device instead of the client coming back from it.
  Map<String, DateTime> loadClientDeletions() {
    final raw = _prefs.getString(_clientDeletionsKey);
    if (raw == null) return {};
    return (jsonDecode(raw) as Map<String, dynamic>).map(
      (id, at) => MapEntry(id, DateTime.parse(at as String)),
    );
  }

  Future<void> saveClientDeletions(Map<String, DateTime> deletions) =>
      _prefs.setString(
        _clientDeletionsKey,
        jsonEncode(
          deletions.map((id, at) => MapEntry(id, at.toUtc().toIso8601String())),
        ),
      );

  Map<String, double>? _distanceCache;

  Map<String, double> _distances() => _distanceCache ??= () {
    final raw = _prefs.getString(_distanceCacheKey);
    if (raw == null) return <String, double>{};
    return (jsonDecode(raw) as Map<String, dynamic>).map(
      (k, v) => MapEntry(k, (v as num).toDouble()),
    );
  }();

  /// Miles previously measured for a from>to key, if any.
  double? cachedMiles(String key) => _distances()[key];

  Future<void> cacheMiles(String key, double miles) async {
    final cache = _distances()..[key] = miles;
    await _prefs.setString(_distanceCacheKey, jsonEncode(cache));
  }

  List<SavedAddress> loadAddresses() =>
      _loadList(_addressesKey).map((e) => SavedAddress.fromJson(e)).toList();

  Future<void> saveAddresses(List<SavedAddress> addresses) => _prefs.setString(
    _addressesKey,
    jsonEncode([for (final a in addresses) a.toJson()]),
  );

  List<Trip> loadTrips() =>
      _loadList(_tripsKey).map((e) => Trip.fromJson(e)).toList();

  Future<void> saveTrips(List<Trip> trips) => _prefs.setString(
    _tripsKey,
    jsonEncode([for (final t in trips) t.toJson()]),
  );

  AppSettings loadSettings() {
    final raw = _prefs.getString(_settingsKey);
    if (raw == null) return const AppSettings();
    return AppSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> saveSettings(AppSettings settings) =>
      _prefs.setString(_settingsKey, jsonEncode(settings.toJson()));

  List<Map<String, dynamic>> _loadList(String key) {
    final raw = _prefs.getString(key);
    if (raw == null) return [];
    return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
  }
}
