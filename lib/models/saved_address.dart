import 'place.dart';

/// A client: who they are, how to reach them, and where appointments are.
/// Logging a trip to a client's address is a single tap, and arriving there
/// logs the trip automatically.
class SavedAddress {
  const SavedAddress({
    required this.id,
    required this.name,
    required this.address,
    this.email = '',
    this.phone = '',
    this.placeId,
    this.lat,
    this.lng,
    this.updatedAt,
  });

  final String id;
  final String name;
  final String address;

  /// Optional contact details. Empty when not given.
  final String email;
  final String phone;

  final String? placeId;
  final double? lat;
  final double? lng;

  /// When this client was last added or edited, for syncing between
  /// devices. Null for clients saved before syncing existed.
  final DateTime? updatedAt;

  /// True when the address was picked from Google Maps.
  bool get isVerified => placeId != null;

  Place toPlace() => Place(
    label: name,
    address: address,
    placeId: placeId,
    lat: lat,
    lng: lng,
  );

  SavedAddress copyWith({
    String? name,
    String? address,
    String? email,
    String? phone,
    String? placeId,
    double? lat,
    double? lng,
    DateTime? updatedAt,
  }) => SavedAddress(
    id: id,
    name: name ?? this.name,
    address: address ?? this.address,
    email: email ?? this.email,
    phone: phone ?? this.phone,
    placeId: placeId ?? this.placeId,
    lat: lat ?? this.lat,
    lng: lng ?? this.lng,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  /// [withTime] false leaves out [updatedAt] (the sync file keeps it
  /// alongside instead).
  Map<String, dynamic> toJson({bool withTime = true}) => {
    'id': id,
    'name': name,
    'address': address,
    if (email.isNotEmpty) 'email': email,
    if (phone.isNotEmpty) 'phone': phone,
    if (placeId != null) 'placeId': placeId,
    if (lat != null) 'lat': lat,
    if (lng != null) 'lng': lng,
    if (withTime && updatedAt != null)
      'updatedAt': updatedAt!.toUtc().toIso8601String(),
  };

  factory SavedAddress.fromJson(Map<String, dynamic> json) => SavedAddress(
    id: json['id'] as String,
    name: json['name'] as String,
    address: json['address'] as String,
    email: json['email'] as String? ?? '',
    phone: json['phone'] as String? ?? '',
    placeId: json['placeId'] as String?,
    lat: (json['lat'] as num?)?.toDouble(),
    lng: (json['lng'] as num?)?.toDouble(),
    updatedAt: json['updatedAt'] == null
        ? null
        : DateTime.parse(json['updatedAt'] as String),
  );
}
