import 'saved_address.dart';

/// Someone in Let's Get This Dunn Club: from the club's interest form, or
/// added by hand. Members are virtual, so many aren't (and can't be)
/// clients; [client] is set for those who are.
class ClubMember {
  const ClubMember({
    required this.id,
    required this.email,
    this.name = '',
    this.phone = '',
    this.joined,
    this.mailingList = true,
    this.areas = '',
    this.topics = '',
    this.notes = '',
    this.fromForm = false,
    this.client,
  });

  /// `form:<email>` for someone from the form (until edited, their details
  /// follow their latest response); otherwise a generated ID.
  final String id;
  final String email;
  final String name;
  final String phone;

  /// When they joined (filled out the form, or as entered).
  final DateTime? joined;

  /// Gets the monthly invite email.
  final bool mailingList;

  /// From the form: areas they struggle with, and topics they want.
  final String areas;
  final String topics;
  final String notes;
  final bool fromForm;

  /// The client they are, if any. Worked out; not stored.
  final SavedAddress? client;

  String get displayName => name.isEmpty ? email : name;

  ClubMember copyWith({
    String? email,
    String? name,
    String? phone,
    DateTime? joined,
    bool? mailingList,
    String? notes,
    SavedAddress? client,
  }) => ClubMember(
    id: id,
    email: email ?? this.email,
    name: name ?? this.name,
    phone: phone ?? this.phone,
    joined: joined ?? this.joined,
    mailingList: mailingList ?? this.mailingList,
    areas: areas,
    topics: topics,
    notes: notes ?? this.notes,
    fromForm: fromForm,
    client: client ?? this.client,
  );

  Map<String, dynamic> toJson() => {
    'email': email,
    if (name.isNotEmpty) 'name': name,
    if (phone.isNotEmpty) 'phone': phone,
    if (joined != null) 'joined': joined!.toIso8601String(),
    if (!mailingList) 'mailingList': false,
    if (areas.isNotEmpty) 'areas': areas,
    if (topics.isNotEmpty) 'topics': topics,
    if (notes.isNotEmpty) 'notes': notes,
    if (fromForm) 'fromForm': true,
  };

  factory ClubMember.fromJson(String id, Map<String, dynamic> json) =>
      ClubMember(
        id: id,
        email: json['email'] as String? ?? '',
        name: json['name'] as String? ?? '',
        phone: json['phone'] as String? ?? '',
        joined: json['joined'] == null
            ? null
            : DateTime.parse(json['joined'] as String),
        mailingList: json['mailingList'] as bool? ?? true,
        areas: json['areas'] as String? ?? '',
        topics: json['topics'] as String? ?? '',
        notes: json['notes'] as String? ?? '',
        fromForm: json['fromForm'] as bool? ?? false,
      );
}
