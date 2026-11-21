import '../models/lead.dart' show parseFormTimestamp;
import '../models/money.dart';
import '../models/saved_address.dart';
import 'policy_forms.dart' show isPolicyFormHeader;
import 'stripe.dart';

String _two(int n) => n.toString().padLeft(2, '0');
String _dollars(double v) => '\$${v.toStringAsFixed(2)}';
String _short(DateTime d) =>
    '${_two(d.month)}/${_two(d.day)}/${_two(d.year % 100)}';

// ----------------------------------------------------------------- forms

/// Which form a responses tab (by its header) belongs to.
enum FormKind { contact, policy, club }

/// Policies forms ask for a typed signature; the website contact form asks
/// for a phone number and what they need; any other form is the Dunn Club
/// sign-up.
FormKind formKindOf(List<String> header) => isPolicyFormHeader(header)
    ? FormKind.policy
    : isContactFormHeader(header)
    ? FormKind.contact
    : FormKind.club;

/// True for the website contact form's responses (it asks for a phone
/// number and what they need).
bool isContactFormHeader(List<String> header) {
  final h = [for (final x in header) x.toLowerCase()];
  return h.any((x) => x.contains('phone') || x.contains('help'));
}

/// Responses to the Dunn Club interest form (header first), oldest first.
/// Rows without an email are skipped.
List<ClubRegistration> parseClubResponses(List<List<String>> rows) {
  if (rows.isEmpty) return const [];
  final header = [for (final h in rows.first) h.trim().toLowerCase()];
  int col(bool Function(String h) test) => header.indexWhere(test);
  final time = col((h) => h.startsWith('timestamp'));
  final email = col((h) => h.startsWith('email') || h == 'e-mail');
  final name = col((h) => h.startsWith('name') || h.contains('your name'));
  final mailing = col((h) => h.contains('mailing list'));
  final areas = col((h) => h.contains('areas'));
  final topics = col((h) => h.contains('topics'));
  String at(List<String> row, int i) =>
      i < 0 || i >= row.length ? '' : row[i].trim();
  final out = <ClubRegistration>[];
  for (final row in rows.skip(1)) {
    final e = at(row, email).toLowerCase();
    if (e.isEmpty) continue;
    final stamp = at(row, time);
    final list = at(row, mailing).toLowerCase();
    out.add(
      ClubRegistration(
        id: '$stamp|$e',
        at: parseFormTimestamp(stamp) ?? DateTime(1970),
        email: e,
        name: at(row, name),
        mailingList: list.isEmpty ? null : list.startsWith('y'),
        areas: at(row, areas),
        topics: at(row, topics),
      ),
    );
  }
  out.sort((a, b) => a.at.compareTo(b.at));
  return out;
}

// -------------------------------------------------------------- payments

/// Every payment received: sessions marked paid on client pages, Dunn
/// Club webinars paid for ([club]), payments entered by hand, and Stripe
/// payments. Newest first. A session paid through Stripe is counted once,
/// as the Stripe payment.
List<LedgerPayment> allPayments({
  required List<SavedAddress> clients,
  required List<ManualPayment> manual,
  List<LedgerPayment> club = const [],
  List<StripePayment> stripe = const [],
  Map<String, StripeDecision> stripeDecisions = const {},
}) {
  final out = <LedgerPayment>[];
  final byId = {for (final c in clients) c.id: c};
  final stripeIds = {for (final p in stripe) p.id};
  // Sessions a Stripe payment here already counts.
  final viaStripe = {
    for (final e in stripeDecisions.entries)
      if (stripeIds.contains(e.key) && e.value.forSession)
        '${e.value.clientId}:${e.value.sessionKey}',
  };
  for (final c in clients) {
    for (final e in c.billing.entries) {
      final b = e.value;
      if (b.status != BillingStatus.paid) continue;
      if (viaStripe.contains('${c.id}:${e.key}') ||
          stripeIds.contains(b.stripeId)) {
        continue;
      }
      final booked = c.scheduled.where((s) => s.id == e.key).firstOrNull;
      final day = _dayKey(e.key);
      final sessionDay = booked?.start ?? day;
      out.add(
        LedgerPayment(
          id: 'session:${c.id}:${e.key}',
          kind: PaymentKind.session,
          date: b.paidOn ?? sessionDay ?? DateTime(1970),
          amount: b.amount ?? booked?.billFor(c.hourlyRate) ?? 0,
          source: IncomeSource.session,
          from: c.name,
          description: sessionDay == null
              ? 'Session'
              : 'Session ${_short(sessionDay)}',
          method: b.method,
          clientId: c.id,
        ),
      );
    }
  }
  out.addAll(club);
  for (final p in stripe) {
    if (p.fullyRefunded) continue;
    final d = stripeDecisions[p.id];
    final client = byId[d?.clientId];
    final forSession = d?.forSession ?? false;
    final booked = forSession
        ? client?.scheduled.where((s) => s.id == d!.sessionKey).firstOrNull
        : null;
    final sessionDay = forSession
        ? booked?.start ?? _dayKey(d!.sessionKey!)
        : null;
    final local = p.at.toLocal();
    out.add(
      LedgerPayment(
        id: 'stripe:${p.id}',
        kind: PaymentKind.stripe,
        date: DateTime(local.year, local.month, local.day),
        amount: p.net,
        source: forSession ? IncomeSource.session : IncomeSource.other,
        from: client?.name ?? p.who,
        description: forSession
            ? sessionDay == null
                  ? 'Session (Stripe)'
                  : 'Session ${_short(sessionDay)} (Stripe)'
            : d == null
            ? 'Stripe payment, not matched yet'
            : 'Stripe payment',
        method: p.method,
        notes: [
          if (p.fee > 0) 'Stripe fee ${_dollars(p.fee)}',
          if (p.refunded > 0)
            'Refunded ${_dollars(p.refunded)} of ${_dollars(p.amount)}',
        ].join('; '),
        clientId: client?.id,
      ),
    );
  }
  for (final m in manual) {
    out.add(
      LedgerPayment(
        id: m.id,
        kind: PaymentKind.manual,
        date: m.date,
        amount: m.amount,
        source: IncomeSource.other,
        from: m.from,
        description: m.description,
        method: m.method,
        notes: m.notes,
      ),
    );
  }
  // Same day: a fixed order, so both devices (and the sheet) agree.
  out.sort((a, b) {
    final byDate = b.date.compareTo(a.date);
    return byDate != 0 ? byDate : b.id.compareTo(a.id);
  });
  return out;
}

/// The day in a "day:2026-11-14" billing key (sessions from before
/// sessions were tracked).
DateTime? _dayKey(String key) {
  if (!key.startsWith('day:')) return null;
  final p = key.substring(4).split('-');
  if (p.length != 3) return null;
  final y = int.tryParse(p[0]);
  final m = int.tryParse(p[1]);
  final d = int.tryParse(p[2]);
  return y == null || m == null || d == null ? null : DateTime(y, m, d);
}

// ------------------------------------------------------------- mileage

/// IRS business standard mileage rates, $ per mile: (January–June,
/// July–December). 2026 changed on July 1 (Announcement 2026-11). Add a
/// line each year.
const irsMileageRates = <int, (double, double)>{
  2025: (0.70, 0.70),
  2026: (0.725, 0.76),
};

/// The IRS rate for a trip on [date], if known.
double? irsRateOn(DateTime date) {
  final r = irsMileageRates[date.year];
  if (r == null) return null;
  return date.month <= 6 ? r.$1 : r.$2;
}

// ----------------------------------------------------------- spreadsheet

/// Oldest first; the same day in a fixed order (by ID).
int _oldestFirst(DateTime a, String aId, DateTime b, String bId) {
  final byDate = a.compareTo(b);
  return byDate != 0 ? byDate : aId.compareTo(bId);
}

String _iso(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

/// Payments tab rows (see `paymentHeaders`), oldest first.
List<List<Object>> paymentRows(List<LedgerPayment> payments) => [
  for (final p in [
    ...payments,
  ]..sort((a, b) => _oldestFirst(a.date, a.id, b.date, b.id)))
    [
      _iso(p.date),
      p.from,
      p.description,
      p.source.label,
      p.method?.label ?? '',
      p.amount,
      p.notes,
      p.id,
    ],
];

/// Expenses tab rows (see `expenseHeaders`), oldest first.
List<List<Object>> expenseRows(List<Expense> expenses) => [
  for (final e in [
    ...expenses,
  ]..sort((a, b) => _oldestFirst(a.date, a.id, b.date, b.id)))
    [
      _iso(e.date),
      e.vendor,
      e.category.label,
      e.method,
      e.amount,
      e.notes,
      e.id,
    ],
];
