import 'billing.dart';
import 'place.dart';

export 'billing.dart';

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

/// A session booked with a client: day, start and end time. The booked
/// time is what's billed (see [billFor]).
class ScheduledJob {
  const ScheduledJob({
    required this.id,
    required this.start,
    this.end,
    this.notes = '',
  });

  final String id;

  /// When the session is booked to start and end (local time). [end] is
  /// null for sessions booked before end times existed.
  final DateTime start;
  final DateTime? end;
  final String notes;

  /// The booked length, if it has an end time.
  Duration? get duration => end?.difference(start);

  /// What the session bills at [hourlyRate], or null without an end time.
  double? billFor(double hourlyRate) {
    final d = duration;
    if (d == null || d.isNegative) return null;
    return (d.inMinutes / 60 * hourlyRate * 100).round() / 100;
  }

  ScheduledJob copyWith({DateTime? start, DateTime? end, String? notes}) =>
      ScheduledJob(
        id: id,
        start: start ?? this.start,
        end: end ?? this.end,
        notes: notes ?? this.notes,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    // Local wall-clock time, so both devices show the same time.
    'start': _localIso(start),
    if (end != null) 'end': _localIso(end!),
    if (notes.isNotEmpty) 'notes': notes,
  };

  factory ScheduledJob.fromJson(Map<String, dynamic> json) => ScheduledJob(
    id: json['id'] as String,
    start: DateTime.parse(json['start'] as String),
    end: json['end'] == null ? null : DateTime.parse(json['end'] as String),
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

/// Someone else to reach about a client (and who may pay): a spouse,
/// an adult child, a property manager, …
class ClientContact {
  const ClientContact({
    required this.id,
    required this.name,
    this.phone = '',
    this.email = '',
    this.label = '',
    this.signsPolicies = false,
  });

  final String id;
  final String name;
  final String phone;
  final String email;

  /// Who they are to the client, e.g. "Spouse" or "Pays". May be empty.
  final String label;

  /// They need to sign the policies form before the client is signed.
  final bool signsPolicies;

  ClientContact copyWith({
    String? name,
    String? phone,
    String? email,
    String? label,
    bool? signsPolicies,
  }) => ClientContact(
    id: id,
    name: name ?? this.name,
    phone: phone ?? this.phone,
    email: email ?? this.email,
    label: label ?? this.label,
    signsPolicies: signsPolicies ?? this.signsPolicies,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (phone.isNotEmpty) 'phone': phone,
    if (email.isNotEmpty) 'email': email,
    if (label.isNotEmpty) 'label': label,
    if (signsPolicies) 'signsPolicies': true,
  };

  factory ClientContact.fromJson(Map<String, dynamic> json) => ClientContact(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    phone: json['phone'] as String? ?? '',
    email: json['email'] as String? ?? '',
    label: json['label'] as String? ?? '',
    signsPolicies: json['signsPolicies'] as bool? ?? false,
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
    this.addressLabel = '',
    this.locations = const [],
    this.contacts = const [],
    this.contactLabel = '',
    this.primarySigns = true,
    this.billing = const {},
    this.hourlyRate = defaultHourlyRate,
    this.policiesSignedOn,
    this.consultationOn,
    this.storedStatus,
    this.scheduled = const [],
    this.notes = '',
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

  /// What the first address is (e.g. "Home"); may be empty.
  final String addressLabel;

  /// The client's other addresses. All addresses are equal in the app;
  /// the first one is kept in [address] for trips and older data.
  final List<ClientLocation> locations;

  /// Other people to reach about the client (and who may pay).
  final List<ClientContact> contacts;

  /// The label on the client's own contact details (empty: "Primary").
  final String contactLabel;

  /// The client themself needs to sign the policies form (usually; not
  /// when, say, a family member signs for them).
  final bool primarySigns;

  /// Who needs to sign the policies form: contact IDs, and null for the
  /// client themself.
  Set<String?> get policySigners => {
    if (primarySigns) null,
    for (final c in contacts)
      if (c.signsPolicies) c.id,
  };

  /// The client themself, as the first contact (ID [primaryContactId]).
  ClientContact get primaryContact => ClientContact(
    id: primaryContactId,
    signsPolicies: primarySigns,
    name: name,
    phone: phone,
    email: email,
    label: contactLabel.isEmpty ? 'Primary' : contactLabel,
  );

  static const primaryContactId = 'primary';

  /// Billing status of each session, by session key (see
  /// `ClientJobEntry.billingKeys`).
  final Map<String, SessionBilling> billing;

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

  /// Free-form notes about the client.
  final String notes;

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
        name:
            '$name (${l.label.isEmpty ? l.address.split(',').first : l.label})',
        address: l.address,
        placeId: l.placeId,
        lat: l.lat,
        lng: l.lng,
      ),
  ];

  /// Every address as a [ClientLocation], the first one (kept in
  /// [address]) with ID [mainAddressId].
  List<ClientLocation> get allAddresses => [
    ClientLocation(
      id: mainAddressId,
      label: addressLabel,
      address: address,
      placeId: placeId,
      lat: lat,
      lng: lng,
    ),
    ...locations,
  ];

  static const mainAddressId = 'main';

  /// This client with [addresses] (at least one) as their addresses, the
  /// first becoming the one trips and older app versions use.
  SavedAddress withAddresses(List<ClientLocation> addresses) {
    final first = addresses.first;
    return SavedAddress(
      id: id,
      name: name,
      address: first.address,
      email: email,
      phone: phone,
      placeId: first.placeId,
      lat: first.lat,
      lng: first.lng,
      addressLabel: first.label,
      locations: addresses.skip(1).toList(),
      contacts: contacts,
      contactLabel: contactLabel,
      primarySigns: primarySigns,
      billing: billing,
      hourlyRate: hourlyRate,
      policiesSignedOn: policiesSignedOn,
      consultationOn: consultationOn,
      storedStatus: storedStatus,
      scheduled: scheduled,
      notes: notes,
      updatedAt: updatedAt,
    );
  }

  SavedAddress copyWith({
    String? name,
    String? address,
    String? email,
    String? phone,
    String? placeId,
    double? lat,
    double? lng,
    String? addressLabel,
    List<ClientLocation>? locations,
    List<ClientContact>? contacts,
    String? contactLabel,
    bool? primarySigns,
    Map<String, SessionBilling>? billing,
    double? hourlyRate,
    DateTime? policiesSignedOn,
    bool clearPoliciesSigned = false,
    DateTime? consultationOn,
    bool clearConsultation = false,
    ClientStatus? status,
    List<ScheduledJob>? scheduled,
    String? notes,
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
    addressLabel: addressLabel ?? this.addressLabel,
    locations: locations ?? this.locations,
    contacts: contacts ?? this.contacts,
    contactLabel: contactLabel ?? this.contactLabel,
    primarySigns: primarySigns ?? this.primarySigns,
    billing: billing ?? this.billing,
    hourlyRate: hourlyRate ?? this.hourlyRate,
    policiesSignedOn: clearPoliciesSigned
        ? null
        : policiesSignedOn ?? this.policiesSignedOn,
    consultationOn: clearConsultation
        ? null
        : consultationOn ?? this.consultationOn,
    storedStatus: status ?? storedStatus,
    scheduled: scheduled ?? this.scheduled,
    notes: notes ?? this.notes,
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
    if (addressLabel.isNotEmpty) 'addressLabel': addressLabel,
    if (locations.isNotEmpty)
      'locations': [for (final l in locations) l.toJson()],
    if (contacts.isNotEmpty) 'contacts': [for (final c in contacts) c.toJson()],
    if (contactLabel.isNotEmpty) 'contactLabel': contactLabel,
    if (!primarySigns) 'primarySigns': false,
    if (billing.isNotEmpty)
      'billing': {for (final e in billing.entries) e.key: e.value.toJson()},
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
    if (notes.isNotEmpty) 'notes': notes,
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
    addressLabel: json['addressLabel'] as String? ?? '',
    locations: [
      for (final l in (json['locations'] as List?) ?? const [])
        ClientLocation.fromJson(l as Map<String, dynamic>),
    ],
    contacts: [
      for (final c in (json['contacts'] as List?) ?? const [])
        ClientContact.fromJson(c as Map<String, dynamic>),
    ],
    contactLabel: json['contactLabel'] as String? ?? '',
    primarySigns: json['primarySigns'] as bool? ?? true,
    billing: {
      for (final e
          in ((json['billing'] as Map<String, dynamic>?) ?? const {}).entries)
        e.key: SessionBilling.fromJson(e.value as Map<String, dynamic>),
    },
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
    notes: json['notes'] as String? ?? '',
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
