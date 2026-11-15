/// A location the app can route to or from.
///
/// [placeId], [lat] and [lng] are filled in once Google Places is wired up
/// (Phase 2); until then a place is identified by its address text.
class Place {
  const Place({
    required this.label,
    required this.address,
    this.placeId,
    this.lat,
    this.lng,
  });

  /// Short display name, e.g. "Home" or "Dr. Patel".
  final String label;

  /// Full street address.
  final String address;

  final String? placeId;
  final double? lat;
  final double? lng;

  bool get hasCoordinates => lat != null && lng != null;

  /// True when the address was picked from Google Maps.
  bool get isVerified => placeId != null;

  /// Same location under a different display name.
  Place relabel(String newLabel) => Place(
    label: newLabel,
    address: address,
    placeId: placeId,
    lat: lat,
    lng: lng,
  );

  Map<String, dynamic> toJson() => {
    'label': label,
    'address': address,
    if (placeId != null) 'placeId': placeId,
    if (lat != null) 'lat': lat,
    if (lng != null) 'lng': lng,
  };

  factory Place.fromJson(Map<String, dynamic> json) => Place(
    label: json['label'] as String,
    address: json['address'] as String,
    placeId: json['placeId'] as String?,
    lat: (json['lat'] as num?)?.toDouble(),
    lng: (json['lng'] as num?)?.toDouble(),
  );

  @override
  bool operator ==(Object other) =>
      other is Place &&
      other.label == label &&
      other.address == address &&
      other.placeId == placeId &&
      other.lat == lat &&
      other.lng == lng;

  @override
  int get hashCode => Object.hash(label, address, placeId, lat, lng);

  @override
  String toString() => 'Place($label, $address)';
}
