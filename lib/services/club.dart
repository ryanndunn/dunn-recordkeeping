import '../models/club_member.dart';
import '../models/money.dart';
import '../models/saved_address.dart';
import '../models/webinar.dart';
import 'people_match.dart';

/// The ID of the member made from someone's form responses.
String formMemberId(String email) => 'form:${email.trim().toLowerCase()}';

/// Stored member records by ID; null is a removed member (kept so the
/// removal reaches the other device, and so a removed form member stays
/// removed).
typedef MemberRecords = Map<String, Map<String, dynamic>?>;

/// Every member, by name: those added or edited by hand, plus one for
/// each email on the interest form that isn't already a member. Each is
/// matched to a client when their email (or, failing that, name) is a
/// client's or one of a client's contacts'.
List<ClubMember> clubMembers({
  required MemberRecords records,
  required List<ClubRegistration> responses,
  required List<SavedAddress> clients,
}) {
  final members = <ClubMember>[
    for (final e in records.entries)
      if (e.value case final Map<String, dynamic> v)
        ClubMember.fromJson(e.key, v),
  ];
  final emails = {for (final m in members) m.email.toLowerCase()};

  final byEmail = <String, List<ClubRegistration>>{};
  for (final r in responses) {
    final e = r.email.trim().toLowerCase();
    if (e.isNotEmpty) (byEmail[e] ??= []).add(r);
  }
  for (final e in byEmail.entries) {
    final id = formMemberId(e.key);
    if (emails.contains(e.key) || records.containsKey(id)) continue;
    final list = [...e.value]..sort((a, b) => a.at.compareTo(b.at));
    final latest = list.last;
    members.add(
      ClubMember(
        id: id,
        email: e.key,
        name:
            list
                .map((r) => r.name.trim())
                .where((n) => n.isNotEmpty)
                .lastOrNull ??
            '',
        joined: list.first.at,
        mailingList: latest.mailingList ?? true,
        areas: latest.areas,
        topics: latest.topics,
        fromForm: true,
      ),
    );
  }

  return [
    for (final m in members)
      m.copyWith(
        client: matchPerson(
          email: m.email,
          name: m.name,
          clients: clients,
        )?.client,
      ),
  ]..sort(
    (a, b) =>
        a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
  );
}

/// Where a member's payment for a webinar is kept.
String seatKey(String webinarId, String memberId) => '$webinarId|$memberId';

/// The webinar and member a [seatKey] is for.
({String webinarId, String memberId}) parseSeatKey(String key) {
  final i = key.indexOf('|');
  return (webinarId: key.substring(0, i), memberId: key.substring(i + 1));
}

/// A webinar with who paid, who came free, and who hasn't paid.
class WebinarSummary {
  const WebinarSummary({
    required this.webinar,
    required this.paid,
    required this.free,
    required this.notPaid,
    required this.seats,
    required this.firstTimers,
  });

  final Webinar webinar;
  final List<ClubMember> paid;
  final List<ClubMember> free;

  /// Everyone else (for a past webinar, members who had joined by then).
  final List<ClubMember> notPaid;

  /// Each member's record for it, by member ID.
  final Map<String, ClubDecision> seats;

  /// Members who haven't been to an earlier webinar: their first is free.
  final Set<String> firstTimers;

  /// Paid or free: the people to send the link to.
  List<ClubMember> get attending => [...paid, ...free];

  /// Attending, but not sent the link yet.
  List<ClubMember> get needLink => [
    for (final m in attending)
      if (seats[m.id]?.linkSentAt == null) m,
  ];

  double get money =>
      paid.fold(0.0, (sum, m) => sum + (seats[m.id]?.amount ?? clubPrice));
}

/// Each webinar's summary: upcoming (soonest first) and past (newest
/// first).
({List<WebinarSummary> upcoming, List<WebinarSummary> past}) summarizeWebinars({
  required List<Webinar> webinars,
  required List<ClubMember> members,
  required Map<String, ClubDecision> seats,
  required DateTime now,
}) {
  final byStart = [...webinars]..sort((a, b) => a.start.compareTo(b.start));
  final been = <String>{};
  final summaries = <String, WebinarSummary>{};
  for (final w in byStart) {
    final mine = <String, ClubDecision>{
      for (final m in members) m.id: ?seats[seatKey(w.id, m.id)],
    };
    final upcoming = w.isUpcoming(now);
    final paid = <ClubMember>[];
    final free = <ClubMember>[];
    final notPaid = <ClubMember>[];
    for (final m in members) {
      switch (mine[m.id]?.status) {
        case ClubStatus.paid:
          paid.add(m);
        case ClubStatus.free:
          free.add(m);
        case ClubStatus.unpaid || null:
          final joined = m.joined;
          if (upcoming || joined == null || !joined.isAfter(w.start)) {
            notPaid.add(m);
          }
      }
    }
    summaries[w.id] = WebinarSummary(
      webinar: w,
      paid: paid,
      free: free,
      notPaid: notPaid,
      seats: mine,
      firstTimers: {
        for (final m in members)
          if (!been.contains(m.id)) m.id,
      },
    );
    for (final e in mine.entries) {
      if (e.value.attending) been.add(e.key);
    }
  }
  return (
    upcoming: [
      for (final w in byStart)
        if (w.isUpcoming(now)) summaries[w.id]!,
    ],
    past: [
      for (final w in byStart.reversed)
        if (!w.isUpcoming(now)) summaries[w.id]!,
    ],
  );
}

/// The club's income for Billing and the spreadsheet: each paid seat.
List<LedgerPayment> clubPayments({
  required List<Webinar> webinars,
  required List<ClubMember> members,
  required Map<String, ClubDecision> seats,
}) {
  final byWebinar = {for (final w in webinars) w.id: w};
  final byMember = {for (final m in members) m.id: m};
  return [
    for (final e in seats.entries)
      if (e.value.status == ClubStatus.paid)
        () {
          final k = parseSeatKey(e.key);
          final w = byWebinar[k.webinarId];
          final m = byMember[k.memberId];
          final day = w?.start;
          return LedgerPayment(
            id: 'club:${e.key}',
            kind: PaymentKind.club,
            date:
                e.value.paidOn ??
                (day == null
                    ? DateTime(1970)
                    : DateTime(day.year, day.month, day.day)),
            amount: e.value.amount ?? clubPrice,
            source: IncomeSource.club,
            from: m == null
                ? 'Removed member'
                : m.name.isEmpty
                ? m.email
                : '${m.name} (${m.email})',
            description: day == null
                ? 'Dunn Club webinar'
                : 'Dunn Club webinar ${_short(day)}',
            method: e.value.method,
          );
        }(),
  ];
}

String _two(int n) => n.toString().padLeft(2, '0');
String _short(DateTime d) =>
    '${_two(d.month)}/${_two(d.day)}/${_two(d.year % 100)}';

const _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// "Thursday, December 4".
String longDay(DateTime d) =>
    '${_weekdays[d.weekday - 1]}, ${_months[d.month - 1]} ${d.day}';

/// "7:00 PM".
String clockTime(DateTime t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$h:${t.minute.toString().padLeft(2, '0')} '
      '${t.hour < 12 ? 'AM' : 'PM'}';
}

String _when(Webinar w) => '${longDay(w.start)} at ${clockTime(w.start)}';

/// The monthly invite to the mailing list, to edit before sending. It
/// doesn't include the join link: that goes to those who pay (or come
/// free).
({String subject, String body}) inviteEmail(Webinar w) => (
  subject: 'Let\'s Get This Dunn Club: ${_when(w)}',
  body: [
    'Hi everyone,',
    '',
    'This month\'s Let\'s Get This Dunn Club meeting is ${_when(w)}, for '
        'an hour on Google Meet.',
    if (w.topic.isNotEmpty) 'This month: ${w.topic}.',
    '',
    'Your first meeting is free; after that it\'s \$20. Let me know '
        'you\'re coming and I\'ll send you the link to join.',
    '',
    'Hope to see you there!',
  ].join('\n'),
);

/// The email with the link to join, for those who paid or come free.
({String subject, String body}) joinLinkEmail(Webinar w) => (
  subject: 'Your link for Let\'s Get This Dunn Club, ${_when(w)}',
  body: [
    'Hi!',
    '',
    'Thanks for joining Let\'s Get This Dunn Club, ${_when(w)}.',
    if (w.topic.isNotEmpty) 'This month: ${w.topic}.',
    '',
    w.link.isEmpty ? 'Join here: [link]' : 'Join here: ${w.link}',
    '',
    'See you there!',
  ].join('\n'),
);

/// An email to everyone in [emails] (blind copied, so members don't see
/// each other's addresses).
Uri membersMailto(
  List<String> emails, {
  required String subject,
  required String body,
}) => Uri.parse(
  'mailto:?bcc=${emails.map(Uri.encodeComponent).join(',')}'
  '&subject=${Uri.encodeComponent(subject)}'
  '&body=${Uri.encodeComponent(body)}',
);

final _emailPattern = RegExp(r'[\w.+\-]+@[\w\-]+(\.[\w\-]+)+');

/// Members in a pasted list: one per line (or separated by semicolons),
/// each with an email and, optionally, a name, e.g.
/// `Jane Smith <jane@example.com>`, `Jane Smith, jane@example.com` or just
/// the email.
/// Lines without an email are skipped; each email appears once.
List<({String name, String email})> parseMemberList(String text) {
  final out = <({String name, String email})>[];
  final seen = <String>{};
  for (final line in text.split(RegExp(r'[\n;]'))) {
    final match = _emailPattern.firstMatch(line);
    if (match == null) continue;
    final email = match.group(0)!.toLowerCase();
    if (!seen.add(email)) continue;
    final name = line
        .replaceRange(match.start, match.end, ' ')
        .replaceAll(RegExp(r'[<>"(),\t]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    out.add((name: name, email: email));
  }
  return out;
}
