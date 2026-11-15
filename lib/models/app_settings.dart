import 'place.dart';

enum NavApp {
  googleMaps('Google Maps'),
  waze('Waze');

  const NavApp(this.label);
  final String label;
}

class AppSettings {
  const AppSettings({
    this.home,
    this.navApp = NavApp.googleMaps,
    this.ratePerMile,
    this.spreadsheetId,
  });

  /// Where the first trip of each day starts from.
  final Place? home;

  /// Which app the Navigate button opens (Phase 4).
  final NavApp navApp;

  /// Optional reimbursement / deduction rate, in dollars per mile.
  final double? ratePerMile;

  /// The Google Sheet the log is written to (Phase 3).
  final String? spreadsheetId;

  AppSettings copyWith({
    Place? home,
    NavApp? navApp,
    double? ratePerMile,
    bool clearRatePerMile = false,
    String? spreadsheetId,
  }) => AppSettings(
    home: home ?? this.home,
    navApp: navApp ?? this.navApp,
    ratePerMile: clearRatePerMile ? null : (ratePerMile ?? this.ratePerMile),
    spreadsheetId: spreadsheetId ?? this.spreadsheetId,
  );

  Map<String, dynamic> toJson() => {
    if (home != null) 'home': home!.toJson(),
    'navApp': navApp.name,
    if (ratePerMile != null) 'ratePerMile': ratePerMile,
    if (spreadsheetId != null) 'spreadsheetId': spreadsheetId,
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
  );
}
