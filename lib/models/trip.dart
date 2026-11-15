import 'place.dart';

/// One logged drive. Becomes one row on the "Mileage Log" sheet.
class Trip {
  const Trip({
    required this.id,
    required this.date,
    required this.from,
    required this.to,
    required this.miles,
    this.notes = '',
    this.estimated = false,
    this.synced = false,
  });

  /// Stable ID, also written to the sheet's hidden column so edits and
  /// deletes can find the right row.
  final String id;

  /// When the trip was logged (local time).
  final DateTime date;

  final Place from;
  final Place to;
  final double miles;
  final String notes;

  /// True when [miles] is a rough estimate (logged without a Google API
  /// key) rather than Google's driving distance.
  final bool estimated;

  /// True once the row has been written to the Google Sheet (Phase 3).
  final bool synced;

  Trip copyWith({double? miles, String? notes, bool? synced}) => Trip(
    id: id,
    date: date,
    from: from,
    to: to,
    miles: miles ?? this.miles,
    notes: notes ?? this.notes,
    estimated: estimated,
    synced: synced ?? this.synced,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'date': date.toIso8601String(),
    'from': from.toJson(),
    'to': to.toJson(),
    'miles': miles,
    'notes': notes,
    if (estimated) 'estimated': true,
    'synced': synced,
  };

  factory Trip.fromJson(Map<String, dynamic> json) => Trip(
    id: json['id'] as String,
    date: DateTime.parse(json['date'] as String),
    from: Place.fromJson(json['from'] as Map<String, dynamic>),
    to: Place.fromJson(json['to'] as Map<String, dynamic>),
    miles: (json['miles'] as num).toDouble(),
    notes: json['notes'] as String? ?? '',
    estimated: json['estimated'] as bool? ?? false,
    synced: json['synced'] as bool? ?? false,
  );
}
