import 'place.dart';

/// Every address of every client you still work with (see
/// [SavedAddress.stops]). Archived clients are left out, so going there
/// isn't treated as a client visit.
List<SavedAddress> clientStops(List<SavedAddress> clients) => [
  for (final c in clients)
    if (c.status != ClientStatus.archived) ...c.stops,
];

/// Where a client is in getting started: a free in-person consultation
/// first, then the policies document, which makes them active.
enum ClientStatus {
  newClient('New', 'New'),
  consultation('Pending consultation', 'Consultation'),
  policyDoc('Pending policy doc', 'Policy doc'),
  active('Active', 'Active'),
  archived('Archived', 'Archived');

  const ClientStatus(this.label, this.shortLabel);

  final String label;

  /// For the list filter.
  final String shortLabel;
}

/// A job booked with a client for a future day and time.
class ScheduledJob {
  const ScheduledJob({required this.id, required this.start, this.notes = ''});

  final String id;

  /// When the job is booked to start (local time).
  final DateTime start;
  final String notes;

  ScheduledJob copyWith({DateTime? start, String? notes}) => ScheduledJob(
    id: id,
    start: start ?? this.start,
    notes: notes ?? this.notes,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    // Local wall-clock time, so both devices show the same time.
    'start': _localIso(start),
    if (notes.isNotEmpty) 'notes': notes,
  };

  factory ScheduledJob.fromJson(Map<String, dynamic> json) => ScheduledJob(
    id: json['id'] as String,
    start: DateTime.parse(json['start'] as String),
    notes: json['notes'] as String? ?? '',
  );
}

/// One of a client's other addresses (second home, storage unit, …),
/// always picked from Google Maps.
class ClientLocation {
  const ClientLocation({
    required this.id,
    required this.label,
    required this.address,
    this.placeId,
    this.lat,
    this.lng,
  });

  final String id;

  /// What this place is to the client, e.g. "Storage unit".
  final String label;
  final String address;
  final String? placeId;
  final double? lat;
  final double? lng;

  ClientLocation copyWith({String? label, Place? place}) => ClientLocation(
    id: id,
    label: label ?? this.label,
    address: place?.address ?? address,
    placeId: place == null ? placeId : place.placeId,
    lat: place == null ? lat : place.lat,
    lng: place == null ? lng : place.lng,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'address': address,
    if (placeId != null) 'placeId': placeId,
    if (lat != null) 'lat': lat,
    if (lng != null) 'lng': lng,
  };

  factory ClientLocation.fromJson(Map<String, dynamic> json) => ClientLocation(
    id: json['id'] as String,
    label: json['label'] as String? ?? '',
    address: json['address'] as String,
    placeId: json['placeId'] as String?,
    lat: (json['lat'] as num?)?.toDouble(),
    lng: (json['lng'] as num?)?.toDouble(),
  );
}

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
    this.locations = const [],
    this.hourlyRate = defaultHourlyRate,
    this.policiesSignedOn,
    this.consultationOn,
    this.storedStatus,
    this.scheduled = const [],
    this.updatedAt,
  });

  /// Rate for new clients (and clients saved before rates existed).
  static const defaultHourlyRate = 75.0;

  final String id;
  final String name;

  /// The main address.
  final String address;

  /// Optional contact details. Empty when not given.
  final String email;
  final String phone;

  final String? placeId;
  final double? lat;
  final double? lng;

  /// The client's other addresses, besides the main one.
  final List<ClientLocation> locations;

  /// What this client pays per hour, in dollars.
  final double hourlyRate;

  /// The day the client signed the policies document (a calendar date,
  /// no time). Null until they sign.
  final DateTime? policiesSignedOn;

  /// The day of the free consultation (a calendar date), once done.
  final DateTime? consultationOn;

  /// The status as set in the app. Null for clients saved before the
  /// five statuses existed (see [status]).
  final ClientStatus? storedStatus;

  /// Jobs booked with this client, soonest first.
  final List<ScheduledJob> scheduled;

  /// Where the client is: as set, or for older clients, active if they
  /// signed the policies and waiting on the policy doc if not.
  ClientStatus get status =>
      storedStatus ??
      (policiesSignedOn != null ? ClientStatus.active : ClientStatus.policyDoc);

  bool get isActive => status == ClientStatus.active;

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

  /// Every place this client is visited, each as its own entry so trip
  /// search, matching and automatic trips treat them all alike: the main
  /// address (with the client's ID and name), then each other address
  /// (ID "clientId/locationId", named "Client (Label)").
  List<SavedAddress> get stops => [
    this,
    for (final l in locations)
      SavedAddress(
        id: '$id/${l.id}',
        name: '$name (${l.label})',
        address: l.address,
        placeId: l.placeId,
        lat: l.lat,
        lng: l.lng,
      ),
  ];

  SavedAddress copyWith({
    String? name,
    String? address,
    String? email,
    String? phone,
    String? placeId,
    double? lat,
    double? lng,
    List<ClientLocation>? locations,
    double? hourlyRate,
    DateTime? policiesSignedOn,
    bool clearPoliciesSigned = false,
    DateTime? consultationOn,
    bool clearConsultation = false,
    ClientStatus? status,
    List<ScheduledJob>? scheduled,
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
    locations: locations ?? this.locations,
    hourlyRate: hourlyRate ?? this.hourlyRate,
    policiesSignedOn: clearPoliciesSigned
        ? null
        : policiesSignedOn ?? this.policiesSignedOn,
    consultationOn: clearConsultation
        ? null
        : consultationOn ?? this.consultationOn,
    storedStatus: status ?? storedStatus,
    scheduled: scheduled ?? this.scheduled,
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
    if (locations.isNotEmpty)
      'locations': [for (final l in locations) l.toJson()],
    // Left out at the default, so clients saved before rates existed
    // sync unchanged.
    if (hourlyRate != defaultHourlyRate) 'hourlyRate': hourlyRate,
    if (policiesSignedOn != null)
      'policiesSignedOn': _dateOnly(policiesSignedOn!),
    if (consultationOn != null) 'consultationOn': _dateOnly(consultationOn!),
    // Left out for older clients until changed, so they sync unchanged.
    if (storedStatus != null) 'status': storedStatus!.name,
    if (scheduled.isNotEmpty)
      'scheduled': [for (final j in scheduled) j.toJson()],
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
    locations: [
      for (final l in (json['locations'] as List?) ?? const [])
        ClientLocation.fromJson(l as Map<String, dynamic>),
    ],
    hourlyRate: (json['hourlyRate'] as num?)?.toDouble() ?? defaultHourlyRate,
    policiesSignedOn: json['policiesSignedOn'] == null
        ? null
        : _parseDate(json['policiesSignedOn'] as String),
    consultationOn: json['consultationOn'] == null
        ? null
        : _parseDate(json['consultationOn'] as String),
    storedStatus: ClientStatus.values
        .where((s) => s.name == json['status'])
        .firstOrNull,
    scheduled: [
      for (final j in (json['scheduled'] as List?) ?? const [])
        ScheduledJob.fromJson(j as Map<String, dynamic>),
    ]..sort((a, b) => a.start.compareTo(b.start)),
    updatedAt: json['updatedAt'] == null
        ? null
        : DateTime.parse(json['updatedAt'] as String),
  );
}

String _two(int n) => n.toString().padLeft(2, '0');

/// "2026-11-17": a calendar date that reads the same in any time zone.
String _dateOnly(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

DateTime _parseDate(String s) {
  final d = DateTime.parse(s);
  return DateTime(d.year, d.month, d.day);
}

/// "2026-11-17T09:30:00": local time with no zone.
String _localIso(DateTime d) {
  final l = d.isUtc ? d.toLocal() : d;
  return '${_dateOnly(l)}T${_two(l.hour)}:${_two(l.minute)}:00';
}
