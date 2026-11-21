/// Someone who filled out the website's contact form ("Want me to contact
/// you?"). Read from the form's responses tab in the spreadsheet. (Dunn
/// Club sign-ups are club members, not leads.)
class Lead {
  const Lead({
    required this.id,
    required this.submitted,
    this.submittedAt,
    this.name = '',
    this.phone = '',
    this.email = '',
    this.address = '',
    this.help = '',
    this.heardFrom = '',
  });

  /// Stable across reads: the form's timestamp and the name.
  final String id;

  /// The timestamp as the sheet shows it, and parsed (null if it can't be).
  final String submitted;
  final DateTime? submittedAt;

  final String name;
  final String phone;
  final String email;
  final String address;

  /// "What can I help you with?"
  final String help;

  /// "How did you hear about me?"
  final String heardFrom;

  Map<String, dynamic> toJson() => {
    'id': id,
    'submitted': submitted,
    if (submittedAt != null) 'submittedAt': submittedAt!.toIso8601String(),
    if (name.isNotEmpty) 'name': name,
    if (phone.isNotEmpty) 'phone': phone,
    if (email.isNotEmpty) 'email': email,
    if (address.isNotEmpty) 'address': address,
    if (help.isNotEmpty) 'help': help,
    if (heardFrom.isNotEmpty) 'heardFrom': heardFrom,
  };

  factory Lead.fromJson(Map<String, dynamic> json) => Lead(
    id: json['id'] as String,
    submitted: json['submitted'] as String? ?? '',
    submittedAt: json['submittedAt'] == null
        ? null
        : DateTime.parse(json['submittedAt'] as String),
    name: json['name'] as String? ?? '',
    phone: json['phone'] as String? ?? '',
    email: json['email'] as String? ?? '',
    address: json['address'] as String? ?? '',
    help: json['help'] as String? ?? '',
    heardFrom: json['heardFrom'] as String? ?? '',
  );

  /// What goes in the client's notes when the lead becomes a client.
  String notesForClient(String Function(DateTime d) formatDate) => [
    submittedAt == null
        ? 'From the website form.'
        : 'From the website form, ${formatDate(submittedAt!)}.',
    if (help.isNotEmpty) 'What can I help you with? $help',
    if (heardFrom.isNotEmpty) 'How they heard about us: $heardFrom',
  ].join('\n');
}

/// What's been done with a lead.
enum LeadStatus {
  open('New'),
  converted('Client'),
  dismissed('Dismissed');

  const LeadStatus(this.label);
  final String label;
}

/// A lead's status (and the client made from it), synced between devices.
class LeadState {
  const LeadState(this.status, {this.clientId});

  static const open = LeadState(LeadStatus.open);

  final LeadStatus status;
  final String? clientId;

  Map<String, dynamic> toJson() => {
    'status': status.name,
    if (clientId != null) 'clientId': clientId,
  };

  factory LeadState.fromJson(Map<String, dynamic> json) => LeadState(
    LeadStatus.values.where((s) => s.name == json['status']).firstOrNull ??
        LeadStatus.open,
    clientId: json['clientId'] as String?,
  );
}

/// The leads in a form responses tab: [rows] with the header row first.
/// Columns are found by their question, so reordering or adding questions
/// on the form doesn't break it. Newest first.
List<Lead> parseFormResponses(List<List<String>> rows) {
  if (rows.isEmpty) return const [];
  final header = [for (final h in rows.first) h.trim().toLowerCase()];
  int col(bool Function(String h) test) => header.indexWhere(test);
  final time = col((h) => h.startsWith('timestamp'));
  final name = col((h) => h == 'name' || h.contains('name'));
  final phone = col((h) => h.contains('phone'));
  final email = col((h) => h.contains('email'));
  final address = col((h) => h.contains('address'));
  final help = col((h) => h.contains('help'));
  final heard = col((h) => h.contains('hear'));

  String at(List<String> row, int i) =>
      i < 0 || i >= row.length ? '' : row[i].trim();

  final leads = <Lead>[];
  for (final row in rows.skip(1)) {
    final submitted = at(row, time);
    final n = at(row, name);
    if (submitted.isEmpty && n.isEmpty) continue;
    leads.add(
      Lead(
        id: '$submitted|$n',
        submitted: submitted,
        submittedAt: parseFormTimestamp(submitted),
        name: n,
        phone: at(row, phone),
        email: at(row, email),
        address: at(row, address),
        help: at(row, help),
        heardFrom: at(row, heard),
      ),
    );
  }
  leads.sort((a, b) {
    final ta = a.submittedAt;
    final tb = b.submittedAt;
    if (ta == null || tb == null) return 0;
    return tb.compareTo(ta);
  });
  return leads;
}

/// Google Forms' timestamp, e.g. "11/17/2026 14:03:22" (US sheets).
DateTime? parseFormTimestamp(String s) {
  final m = RegExp(
    r'^(\d{1,2})/(\d{1,2})/(\d{4})(?:\s+(\d{1,2}):(\d{2})(?::(\d{2}))?)?',
  ).firstMatch(s.trim());
  if (m == null) return DateTime.tryParse(s.trim());
  int g(int i) => int.tryParse(m.group(i) ?? '') ?? 0;
  return DateTime(g(3), g(1), g(2), g(4), g(5), g(6));
}
