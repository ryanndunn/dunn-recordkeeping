import 'place.dart';

enum NavApp {
  googleMaps('Google Maps'),
  waze('Waze');

  const NavApp(this.label);
  final String label;
}

/// Setting names that sync between devices. The API key is stored
/// separately (secure storage) but its change time is tracked here too.
abstract final class SyncedField {
  static const home = 'home';
  static const navApp = 'navApp';
  static const ratePerMile = 'ratePerMile';
  static const spreadsheetId = 'spreadsheetId';
  static const apiKey = 'apiKey';
  static const bookingUrl = 'bookingUrl';
  static const policyDocName = 'policyDocName';

  static const all = [
    home,
    navApp,
    ratePerMile,
    spreadsheetId,
    apiKey,
    bookingUrl,
    policyDocName,
  ];
}

class AppSettings {
  const AppSettings({
    this.home,
    this.navApp = NavApp.googleMaps,
    this.ratePerMile,
    this.spreadsheetId,
    this.bookingUrl,
    this.policyDocName,
    this.changedAt = const {},
  });

  /// Where the first trip of each day starts from.
  final Place? home;

  /// Which app the Navigate button opens (Phase 4).
  final NavApp navApp;

  /// Optional reimbursement / deduction rate, in dollars per mile.
  final double? ratePerMile;

  /// The Google Sheet the log is written to (Phase 3).
  final String? spreadsheetId;

  /// The Google Calendar booking page for consultations, shown on the
  /// Availability tab.
  final String? bookingUrl;

  /// Signed policy PDFs in Drive have this in their name (null: the
  /// default, see `defaultPolicyDocName`).
  final String? policyDocName;

  /// When each [SyncedField] was last changed on this device (or arrived
  /// from another). The newer change wins when devices sync.
  final Map<String, DateTime> changedAt;

  AppSettings copyWith({
    Place? home,
    NavApp? navApp,
    double? ratePerMile,
    bool clearRatePerMile = false,
    String? spreadsheetId,
    String? bookingUrl,
    bool clearBookingUrl = false,
    String? policyDocName,
    Map<String, DateTime>? changedAt,
  }) => AppSettings(
    home: home ?? this.home,
    navApp: navApp ?? this.navApp,
    ratePerMile: clearRatePerMile ? null : (ratePerMile ?? this.ratePerMile),
    spreadsheetId: spreadsheetId ?? this.spreadsheetId,
    bookingUrl: clearBookingUrl ? null : (bookingUrl ?? this.bookingUrl),
    policyDocName: policyDocName ?? this.policyDocName,
    changedAt: changedAt ?? this.changedAt,
  );

  /// Same settings with [field] marked as changed at [when].
  AppSettings stamped(String field, DateTime when) =>
      copyWith(changedAt: {...changedAt, field: when.toUtc()});

  Map<String, dynamic> toJson() => {
    if (home != null) 'home': home!.toJson(),
    'navApp': navApp.name,
    if (ratePerMile != null) 'ratePerMile': ratePerMile,
    if (spreadsheetId != null) 'spreadsheetId': spreadsheetId,
    if (bookingUrl != null) 'bookingUrl': bookingUrl,
    if (policyDocName != null) 'policyDocName': policyDocName,
    if (changedAt.isNotEmpty)
      'changedAt': {
        for (final e in changedAt.entries) e.key: e.value.toIso8601String(),
      },
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
    home: json['home'] == null
        ? null
        : Place.fromJson(json['home'] as Map<String, dynamic>),
    navApp: NavApp.values.firstWhere(
      (n) => n.name == json['navApp'],
      orElse: () => NavApp.googleMaps,
    ),
    ratePerMile: (json['ratePerMile'] as num?)?.toDouble(),
    spreadsheetId: json['spreadsheetId'] as String?,
    bookingUrl: json['bookingUrl'] as String?,
    policyDocName: json['policyDocName'] as String?,
    changedAt: {
      for (final e
          in ((json['changedAt'] as Map<String, dynamic>?) ?? const {}).entries)
        e.key: DateTime.parse(e.value as String),
    },
  );
}
