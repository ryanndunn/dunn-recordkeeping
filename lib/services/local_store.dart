import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';
import '../models/job.dart';
import '../models/saved_address.dart';
import '../models/trip.dart';
import 'tracking_log.dart';

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
  static const _styledSheetKey = 'styled_sheet_id_v6';

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

  /// What automatic tracking saw and did, newest first.
  List<TrackingEvent> loadTrackingLog() => TrackingLog.read(_prefs);

  Future<void> clearTrackingLog() => TrackingLog.clear(_prefs);

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

  static const _clientSortKey = 'clients_sort_v1';

  /// How the client list was last sorted on this device.
  String? get clientSort => _prefs.getString(_clientSortKey);

  Future<void> setClientSort(String sort) =>
      _prefs.setString(_clientSortKey, sort);

  static const _otherJobsKey = 'other_device_jobs_v1';

  /// Jobs recorded on the other device (as received from sync), shown on
  /// client pages.
  String? get otherDeviceJobsRaw => _prefs.getString(_otherJobsKey);

  Future<void> setOtherDeviceJobsRaw(String raw) =>
      _prefs.setString(_otherJobsKey, raw);

  static const _leadsKey = 'leads_v1';
  static const _leadStatesKey = 'lead_states_v1';

  /// Leads as last read from the form's responses tab (JSON), or null if
  /// never read. "null" (the JSON) means no form is linked.
  String? get leadsRaw => _prefs.getString(_leadsKey);

  Future<void> setLeadsRaw(String raw) => _prefs.setString(_leadsKey, raw);

  /// What's been done with each lead, as synced (JSON).
  String? get leadStatesRaw => _prefs.getString(_leadStatesKey);

  Future<void> setLeadStatesRaw(String raw) =>
      _prefs.setString(_leadStatesKey, raw);

  static const manualPaymentsKey = 'manual_payments_v1';
  static const expensesKey = 'expenses_v1';
  static const clubSeatsKey = 'club_payments_v1';
  static const clubMembersKey = 'club_members_v1';
  static const clubRegistrationsKey = 'club_registrations_v1';
  static const webinarsKey = 'webinars_v1';

  /// The spreadsheet already given the Payments/Expenses/Tax Summary tabs.
  static const recordsSheetKey = 'records_sheet_v1';

  /// What was last written to those tabs (spreadsheet ID and a hash).
  static const ledgerWrittenKey = 'ledger_written_v1';

  /// Records kept as JSON under [key] (payments, expenses, Dunn Club
  /// sign-ups and decisions, and what was last written to the sheet).
  String? recordsRaw(String key) => _prefs.getString(key);

  Future<void> setRecordsRaw(String key, String raw) =>
      _prefs.setString(key, raw);

  static const _stripePaymentsKey = 'stripe_payments_v1';
  static const _stripeKeyChangedKey = 'stripe_key_changed_v1';

  /// Synced decisions about Stripe payments (records, see
  /// SyncedRecordsNotifier).
  static const stripeDecisionsKey = 'stripe_decisions_v1';

  /// Stripe payments as last fetched (JSON), with when.
  String? get stripePaymentsRaw => _prefs.getString(_stripePaymentsKey);

  Future<void> setStripePaymentsRaw(String? raw) => raw == null
      ? _prefs.remove(_stripePaymentsKey)
      : _prefs.setString(_stripePaymentsKey, raw);

  /// When the Stripe key was last entered or removed (on either device),
  /// so the newer one wins when syncing.
  DateTime? get stripeKeyChangedAt {
    final raw = _prefs.getString(_stripeKeyChangedKey);
    return raw == null ? null : DateTime.parse(raw);
  }

  Future<void> setStripeKeyChangedAt(DateTime? at) => at == null
      ? _prefs.remove(_stripeKeyChangedKey)
      : _prefs.setString(_stripeKeyChangedKey, at.toUtc().toIso8601String());

  static const _calendarsShownKey = 'calendars_shown_v1';

  /// The Google calendars shown on the Calendar tab (JSON list of IDs), or
  /// null for the ones checked in Google Calendar.
  String? get calendarsShownRaw => _prefs.getString(_calendarsShownKey);

  Future<void> setCalendarsShownRaw(String raw) =>
      _prefs.setString(_calendarsShownKey, raw);

  static const _signaturesKey = 'policy_signatures_v1';
  static const _signatureDecisionsKey = 'policy_signature_decisions_v1';

  /// Policies form responses as last read from the spreadsheet (JSON).
  String? get policySignaturesRaw => _prefs.getString(_signaturesKey);

  Future<void> setPolicySignaturesRaw(String raw) =>
      _prefs.setString(_signaturesKey, raw);

  /// Whose each policies form response is, as synced (JSON).
  String? get signatureDecisionsRaw => _prefs.getString(_signatureDecisionsKey);

  Future<void> setSignatureDecisionsRaw(String raw) =>
      _prefs.setString(_signatureDecisionsKey, raw);

  static const _dataAccountKey = 'data_account_v1';

  /// The Google account this device's data and spreadsheet belong to (the
  /// last one signed in), or null if none yet.
  String? get dataAccount => _prefs.getString(_dataAccountKey);

  Future<void> setDataAccount(String email) =>
      _prefs.setString(_dataAccountKey, email);

  /// Forgets everything tied to the Google account in use: its
  /// spreadsheet, form responses (leads, Dunn Club sign-ups), signed docs,
  /// calendars, the Stripe connection and the other device's sessions. Unless [keepData], also
  /// erases clients, trips, sessions, payments and expenses. Kept either
  /// way: home address, donation centers, the Maps API key and this
  /// device's own preferences.
  Future<void> forgetAccount({required bool keepData}) async {
    final settings = loadSettings();
    await saveSettings(
      AppSettings(
        home: settings.home,
        navApp: settings.navApp,
        ratePerMile: settings.ratePerMile,
        bookingUrl: settings.bookingUrl,
        changedAt: {...settings.changedAt}..remove(SyncedField.spreadsheetId),
      ),
    );
    for (final key in [
      _dataAccountKey,
      _styledSheetKey,
      _pendingDeletesKey,
      _otherJobsKey,
      _leadsKey,
      _leadStatesKey,
      _calendarsShownKey,
      _signaturesKey,
      _signatureDecisionsKey,
      _stripePaymentsKey,
      _stripeKeyChangedKey,
      stripeDecisionsKey,
      clubRegistrationsKey,
      clubSeatsKey,
      recordsSheetKey,
      ledgerWrittenKey,
      if (!keepData) ...[
        _addressesKey,
        _clientDeletionsKey,
        _tripsKey,
        _jobsKey,
        _lastStopKey,
        _lastDepartureKey,
        manualPaymentsKey,
        expensesKey,
        webinarsKey,
        clubMembersKey,
      ],
    ]) {
      await _prefs.remove(key);
    }
  }

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
