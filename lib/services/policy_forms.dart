import '../models/lead.dart' show parseFormTimestamp;
import '../models/saved_address.dart';
import 'people_match.dart';

export 'people_match.dart' show matchPerson;

/// One response to a policies Google Form: someone agreeing to the
/// policies by typing their name. Read from the form's responses tab in
/// the business records spreadsheet.
class PolicySignature {
  const PolicySignature({
    required this.id,
    required this.at,
    required this.form,
    this.email = '',
    this.signedName = '',
    this.rate,
    this.includesPayment = false,
    this.answers = const [],
  });

  /// Stable: the form's timestamp and email.
  final String id;

  /// When the form was submitted.
  final DateTime at;

  /// The spreadsheet tab its form writes to ("Form Responses 3").
  final String form;
  final String email;

  /// The name typed as their signature.
  final String signedName;

  /// The hourly rate the form agrees to, if it states one.
  final double? rate;

  /// The form has them agree to pay (the person paying signs this one; a
  /// form without it is for the person worked with when someone else pays).
  final bool includesPayment;

  /// Every other question and its answer, in form order.
  final List<({String question, String answer})> answers;

  /// Their name, or their email if they didn't type one.
  String get who => signedName.isNotEmpty ? signedName : email;

  Map<String, dynamic> toJson() => {
    'id': id,
    'at': at.toUtc().toIso8601String(),
    'form': form,
    if (email.isNotEmpty) 'email': email,
    if (signedName.isNotEmpty) 'signedName': signedName,
    if (rate != null) 'rate': rate,
    if (includesPayment) 'includesPayment': true,
    if (answers.isNotEmpty)
      'answers': [
        for (final a in answers) [a.question, a.answer],
      ],
  };

  factory PolicySignature.fromJson(Map<String, dynamic> json) =>
      PolicySignature(
        id: json['id'] as String,
        at: DateTime.parse(json['at'] as String),
        form: json['form'] as String? ?? '',
        email: json['email'] as String? ?? '',
        signedName: json['signedName'] as String? ?? '',
        rate: (json['rate'] as num?)?.toDouble(),
        includesPayment: json['includesPayment'] as bool? ?? false,
        answers: [
          for (final a in (json['answers'] as List?) ?? const [])
            (question: '${(a as List)[0]}', answer: '${a[1]}'),
        ],
      );
}

/// Who a signature belongs to: a client, and which of their contacts
/// signed (null: the client themself). No client: not a policy signature
/// for any client. Synced between devices.
class SignatureDecision {
  const SignatureDecision({
    this.clientId,
    this.contactId,
    this.automatic = false,
  });

  /// Not any client's.
  static const ignored = SignatureDecision();

  final String? clientId;

  /// The contact who signed (e.g. the person paying), or null for the
  /// client themself.
  final String? contactId;

  /// Matched by email or name (not picked by hand).
  final bool automatic;

  Map<String, dynamic> toJson() => {
    if (clientId != null) 'clientId': clientId,
    if (contactId != null) 'contactId': contactId,
    if (automatic) 'automatic': true,
  };

  factory SignatureDecision.fromJson(Map<String, dynamic> json) =>
      SignatureDecision(
        clientId: json['clientId'] as String?,
        contactId: json['contactId'] as String?,
        automatic: json['automatic'] as bool? ?? false,
      );
}

// ---------------------------------------------------------------- reading

/// True for a policies form's responses (header first): it asks for a
/// typed signature.
bool isPolicyFormHeader(List<String> header) =>
    header.any((h) => h.toLowerCase().contains('signature'));

final _rate = RegExp(
  r'\$\s*(\d+(?:\.\d+)?)\s*(?:/|per)\s*h(?:ou)?r',
  caseSensitive: false,
);

/// The hourly rate a policies form agrees to: the "$75/hour" in its
/// "I agree to pay the hourly rate…" question.
double? policyFormRate(List<String> header) {
  for (final h in header) {
    if (!h.toLowerCase().contains('hourly rate')) continue;
    final m = _rate.firstMatch(h);
    if (m != null) return double.parse(m.group(1)!);
  }
  return null;
}

/// Whether the form has the signer agree to pay the hourly rate.
bool policyFormIncludesPayment(List<String> header) => header.any((h) {
  final x = h.toLowerCase();
  return x.contains('agree to pay') && x.contains('hourly rate');
});

/// The responses in a policies form's tab named [form] (header first),
/// oldest first. Blank rows are skipped.
List<PolicySignature> parsePolicyResponses(
  String form,
  List<List<String>> rows,
) {
  if (rows.isEmpty) return const [];
  final header = [for (final h in rows.first) h.trim()];
  final lower = [for (final h in header) h.toLowerCase()];
  final time = lower.indexWhere((h) => h.startsWith('timestamp'));
  final email = lower.indexWhere((h) => h.contains('email'));
  final sign = lower.indexWhere((h) => h.contains('signature'));
  final rate = policyFormRate(header);
  final pays = policyFormIncludesPayment(header);
  String at(List<String> row, int i) =>
      i < 0 || i >= row.length ? '' : row[i].trim();

  final out = <PolicySignature>[];
  for (final row in rows.skip(1)) {
    final e = at(row, email).toLowerCase();
    final name = at(row, sign);
    final stamp = at(row, time);
    if (e.isEmpty && name.isEmpty) continue;
    out.add(
      PolicySignature(
        id: '$stamp|$e|$name',
        at: parseFormTimestamp(stamp) ?? DateTime(1970),
        form: form,
        email: e,
        signedName: name,
        rate: rate,
        includesPayment: pays,
        answers: [
          for (var i = 0; i < header.length; i++)
            if (i != time && i != email && i != sign && at(row, i).isNotEmpty)
              (question: header[i], answer: at(row, i)),
        ],
      ),
    );
  }
  out.sort((a, b) => a.at.compareTo(b.at));
  return out;
}

// --------------------------------------------------------------- matching

/// Whose signature [sig] is: by email (the client's or one of their
/// contacts'), otherwise by the typed name. Null if nobody, or more than
/// one client, matches.
({SavedAddress client, String? contactId})? matchSignature(
  PolicySignature sig,
  List<SavedAddress> clients,
) => matchPerson(email: sig.email, name: sig.signedName, clients: clients);

// --------------------------------------------------------------- progress

/// Where a client's policy forms stand.
class PolicyProgress {
  const PolicyProgress(this.signatures, {this.required = const {null}});

  /// Their signatures, oldest first, with who signed (null: the client).
  final List<({PolicySignature sig, String? contactId})> signatures;

  /// Who needs to sign: contact IDs, and null for the client themself.
  final Set<String?> required;

  /// Whether [who] (a contact ID, or null for the client) has signed.
  bool hasSigned(String? who) => signatures.any((s) => s.contactId == who);

  /// Who still needs to sign.
  List<String?> get missing => [
    for (final r in required)
      if (!hasSigned(r)) r,
  ];

  /// Someone (the client or whoever pays) signed a form agreeing to pay.
  bool get paymentSigned => signatures.any((s) => s.sig.includesPayment);

  /// Everyone who needs to sign has, and someone agreed to pay.
  bool get complete => missing.isEmpty && paymentSigned;

  /// When it became complete: the last of the forms it needed.
  DateTime? get completedAt {
    if (!complete) return null;
    final needed = [
      for (final r in required)
        signatures.firstWhere((s) => s.contactId == r).sig.at,
      signatures.firstWhere((s) => s.sig.includesPayment).sig.at,
    ];
    return needed.reduce((a, b) => a.isAfter(b) ? a : b);
  }

  /// The rate agreed to (the latest form agreeing to pay that states one).
  double? get rate => signatures
      .where((s) => s.sig.includesPayment && s.sig.rate != null)
      .map((s) => s.sig.rate)
      .lastOrNull;
}

/// [client]'s signatures, from every signature and the decisions made.
PolicyProgress policyProgressOf(
  SavedAddress client,
  List<PolicySignature> all,
  Map<String, SignatureDecision> decisions,
) => PolicyProgress([
  for (final s in all)
    if (decisions[s.id]?.clientId == client.id)
      (sig: s, contactId: decisions[s.id]!.contactId),
], required: client.policySigners);

/// [client] with their policies signed on [at]'s day, at the agreed
/// [rate] if given: active, unless archived (signing doesn't bring them
/// back).
SavedAddress signedWith(SavedAddress client, DateTime at, {double? rate}) {
  final d = at.toLocal();
  return client.copyWith(
    policiesSignedOn: DateTime(d.year, d.month, d.day),
    hourlyRate: rate,
    status: client.status == ClientStatus.archived ? null : ClientStatus.active,
  );
}
