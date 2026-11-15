import 'place.dart';

/// An address in the user's saved list. Logging a trip to one of these is a
/// single tap.
class SavedAddress {
  const SavedAddress({
    required this.id,
    required this.name,
    required this.address,
    this.placeId,
    this.lat,
    this.lng,
  });

  final String id;
  final String name;
  final String address;
  final String? placeId;
  final double? lat;
  final double? lng;

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
    String? placeId,
    double? lat,
    double? lng,
  }) => SavedAddress(
    id: id,
    name: name ?? this.name,
    address: address ?? this.address,
    placeId: placeId ?? this.placeId,
    lat: lat ?? this.lat,
    lng: lng ?? this.lng,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'address': address,
    if (placeId != null) 'placeId': placeId,
    if (lat != null) 'lat': lat,
    if (lng != null) 'lng': lng,
  };

  factory SavedAddress.fromJson(Map<String, dynamic> json) => SavedAddress(
    id: json['id'] as String,
    name: json['name'] as String,
    address: json['address'] as String,
    placeId: json['placeId'] as String?,
    lat: (json['lat'] as num?)?.toDouble(),
    lng: (json['lng'] as num?)?.toDouble(),
  );
}
