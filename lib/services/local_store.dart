import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';
import '../models/job.dart';
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
  // Bump the version when restyleRequests changes, so it runs again.
  static const _styledSheetKey = 'styled_sheet_id_v5';

  /// The spreadsheet already given the current look (see
  /// MileageSheet.restyle), so the update runs once per spreadsheet.
  String? get styledSheetId => _prefs.getString(_styledSheetKey);

  Future<void> setStyledSheetId(String id) =>
      _prefs.setString(_styledSheetKey, id);

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

  // ------------------------------------------------- donation centers

  static const _donationCentersKey = 'donation_centers_v1';
  static const _donationDeletionsKey = 'donation_deletions_v1';

  /// Where donated items are dropped off. Saved like clients (name and a
  /// Google-picked address); other client fields are unused.
  List<SavedAddress> loadDonationCenters() =>
      _loadList(_donationCentersKey)
          .map((e) => SavedAddress.fromJson(e))
          .toList();

  Future<void> saveDonationCenters(List<SavedAddress> centers) =>
      _prefs.setString(
        _donationCentersKey,
        jsonEncode([for (final c in centers) c.toJson()]),
      );

  Map<String, DateTime> loadDonationDeletions() =>
      _loadTimes(_donationDeletionsKey);

  Future<void> saveDonationDeletions(Map<String, DateTime> deletions) =>
      _saveTimes(_donationDeletionsKey, deletions);

  Map<String, DateTime> _loadTimes(String key) {
    final raw = _prefs.getString(key);
    if (raw == null) return {};
    return (jsonDecode(raw) as Map<String, dynamic>).map(
      (id, at) => MapEntry(id, DateTime.parse(at as String)),
    );
  }

  Future<void> _saveTimes(String key, Map<String, DateTime> times) =>
      _prefs.setString(
        key,
        jsonEncode(
          times.map((id, at) => MapEntry(id, at.toUtc().toIso8601String())),
        ),
      );

  // ------------------------------------------------------------------ jobs
  //
  // Written by the phone's background handlers as well as the app, so
  // callers [reload] first when the other side may have written.

  static const _jobsKey = 'jobs_v1';
  static const _lastStopKey = 'last_stop_v1';
  static const _lastDepartureKey = 'last_departure_v1';

  /// Picks up changes made by the background handlers.
  Future<void> reload() => _prefs.reload();

  List<Job> loadJobs() =>
      _loadList(_jobsKey).map((e) => Job.fromJson(e)).toList();

  Future<void> saveJobs(List<Job> jobs) => _prefs.setString(
    _jobsKey,
    jsonEncode([for (final j in jobs) j.toJson()]),
  );

  /// Where the phone last stopped (logged as a trip or not).
  PlaceVisit? get lastStop => _loadVisit(_lastStopKey);

  Future<void> setLastStop(PlaceVisit visit) =>
      _prefs.setString(_lastStopKey, jsonEncode(visit.toJson()));

  /// The saved place the phone last left, and when.
  PlaceVisit? get lastDeparture => _loadVisit(_lastDepartureKey);

  Future<void> setLastDeparture(PlaceVisit visit) =>
      _prefs.setString(_lastDepartureKey, jsonEncode(visit.toJson()));

  PlaceVisit? _loadVisit(String key) {
    final raw = _prefs.getString(key);
    if (raw == null) return null;
    return PlaceVisit.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  static const _otherJobsKey = 'other_device_jobs_v1';

  /// Jobs recorded on the other device (as received from sync), shown on
  /// client pages.
  String? get otherDeviceJobsRaw => _prefs.getString(_otherJobsKey);

  Future<void> setOtherDeviceJobsRaw(String raw) =>
      _prefs.setString(_otherJobsKey, raw);

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
