import 'package:flutter_test/flutter_test.dart';
import 'package:mileage_log/models/club_member.dart';
import 'package:mileage_log/models/money.dart';
import 'package:mileage_log/models/saved_address.dart';
import 'package:mileage_log/models/webinar.dart';
import 'package:mileage_log/services/club.dart';
import 'package:mileage_log/services/ledger.dart';

void main() {
  final booked = ScheduledJob(
    id: 's1',
    start: DateTime(2026, 11, 10, 9),
    end: DateTime(2026, 11, 10, 12),
  );
  final jane = SavedAddress(
    id: 'j',
    name: 'Jane Smith',
    address: 'x',
    email: 'jane@example.com',
    scheduled: [booked],
    billing: {
      's1': SessionBilling(
        status: BillingStatus.paid,
        method: PaymentMethod.venmo,
        paidOn: DateTime(2026, 11, 8),
        amount: 200,
      ),
    },
  );

  group('Dunn Club', () {
    const mailingQ =
        'Would you like to be added to the e-mailing list? I send one email '
        'invite per month. You can unsubscribe at any time.';
    final rows = [
      [
        'Timestamp',
        'Email',
        mailingQ,
        'Name (Required if you want to be added to the e-mailing list).',
        'Which areas do you struggle to manage?',
        'What topics are you interested in?',
      ],
      ['10/2/2026 9:00:00', 'Sam@Example.com', 'Yes', 'Sam', 'Garage', ''],
      [
        '11/3/2026 9:00:00',
        'sam@example.com',
        'No',
        'Sam Lee',
        'Garage, Papers',
        'Strategies for ADHD',
      ],
      ['11/4/2026 10:00:00', 'jane@example.com', 'Yes', '', 'Kitchen', ''],
    ];

    test('the interest form is told apart from the contact form', () {
      expect(isContactFormHeader(rows.first), isFalse);
      expect(formKindOf(rows.first), FormKind.club);
      expect(
        isContactFormHeader(['Timestamp', 'Name', 'Phone number', 'Email']),
        isTrue,
      );
    });

    test('the form\'s answers are read', () {
      final regs = parseClubResponses(rows);
      expect(regs.map((r) => r.email), [
        'sam@example.com',
        'sam@example.com',
        'jane@example.com',
      ]);
      expect(regs[1].name, 'Sam Lee');
      expect(regs[1].mailingList, isFalse);
      expect(regs[1].areas, 'Garage, Papers');
      expect(regs[1].topics, 'Strategies for ADHD');
      expect(regs[2].mailingList, isTrue);
    });

    test('each person on the form is a member once, from their latest '
        'answers; clients are marked', () {
      final members = clubMembers(
        records: const {},
        responses: parseClubResponses(rows),
        clients: [jane],
      );
      expect(members.map((m) => m.email), [
        'jane@example.com',
        'sam@example.com',
      ], reason: 'by name (or email)');
      expect(members.first.client?.id, 'j');
      final sam = members.last;
      expect(sam.id, formMemberId('sam@example.com'));
      expect(sam.fromForm, isTrue);
      expect(sam.client, isNull);
      expect(sam.name, 'Sam Lee');
      expect(sam.mailingList, isFalse, reason: 'said no the second time');
      expect(sam.joined, DateTime(2026, 10, 2, 9));
    });

    test('members added by hand, edited, or removed', () {
      final regs = parseClubResponses(rows);
      final members = clubMembers(
        records: {
          'x1': const ClubMember(
            id: 'x1',
            email: 'pat@example.com',
            name: 'Pat',
          ).toJson(),
          // Jane, edited.
          formMemberId('jane@example.com'): const ClubMember(
            id: 'form:jane@example.com',
            email: 'jane@example.com',
            name: 'Jane S.',
            fromForm: true,
          ).toJson(),
          // Sam, removed.
          formMemberId('sam@example.com'): null,
        },
        responses: regs,
        clients: const [],
      );
      expect(members.map((m) => m.displayName), ['Jane S.', 'Pat']);

      // Someone already added by hand isn't added again from the form.
      final again = clubMembers(
        records: {
          'x2': const ClubMember(id: 'x2', email: 'sam@example.com').toJson(),
        },
        responses: regs,
        clients: const [],
      );
      expect(again.where((m) => m.email == 'sam@example.com'), hasLength(1));
    });

    test('a pasted list of members', () {
      final list = parseMemberList(
        'Jane Smith <Jane@Example.com>\n'
        '"Sam Lee", sam@example.com; pat@example.com\n'
        'no email here\n'
        'jane@example.com',
      );
      expect(list, [
        (name: 'Jane Smith', email: 'jane@example.com'),
        (name: 'Sam Lee', email: 'sam@example.com'),
        (name: '', email: 'pat@example.com'),
      ]);
    });

    test('who paid for each webinar, who came free, and the money', () {
      const sam = ClubMember(id: 's', email: 'sam@example.com');
      const pat = ClubMember(id: 'p', email: 'pat@example.com');
      final late = ClubMember(
        id: 'l',
        email: 'late@example.com',
        joined: DateTime(2026, 11, 10),
      );
      final oct = Webinar(id: 'oct', start: DateTime(2026, 10, 29, 20));
      final nov = Webinar(id: 'nov', start: DateTime(2026, 11, 26, 20));
      final dec = Webinar(id: 'dec', start: DateTime(2026, 12, 31, 20));
      final seats = {
        seatKey('oct', 's'): const ClubDecision(ClubStatus.free),
        seatKey('nov', 's'): const ClubDecision(ClubStatus.paid, amount: 25),
        seatKey('dec', 's'): ClubDecision(
          ClubStatus.paid,
          linkSentAt: DateTime(2026, 12, 1),
        ),
        seatKey('dec', 'p'): const ClubDecision(ClubStatus.paid),
      };
      final s = summarizeWebinars(
        webinars: [dec, oct, nov],
        members: [late, pat, sam],
        seats: seats,
        now: DateTime(2026, 11, 20),
      );
      expect(s.upcoming.map((w) => w.webinar.id), ['nov', 'dec']);
      expect(s.past.single.webinar.id, 'oct');

      final octS = s.past.single;
      expect(octS.free.single.id, 's');
      expect(octS.notPaid.map((m) => m.id), ['p'], reason: 'joined after it');
      expect(octS.money, 0);

      final novS = s.upcoming.first;
      expect(novS.paid.single.id, 's');
      expect(novS.money, 25);
      expect(novS.notPaid.map((m) => m.id), ['l', 'p']);
      expect(novS.firstTimers, {'l', 'p'}, reason: 'Sam came to October');

      final decS = s.upcoming.last;
      expect(decS.paid.map((m) => m.id), ['p', 's']);
      expect(decS.money, 40);
      expect(decS.needLink.single.id, 'p', reason: 'Sam has the link');

      final ledger = clubPayments(
        webinars: [oct, nov, dec],
        members: [sam, pat],
        seats: seats,
      );
      expect(ledger.map((p) => p.amount).toList()..sort(), [20, 20, 25]);
      final novPay = ledger.firstWhere((p) => p.id == 'club:nov|s');
      expect(novPay.date, DateTime(2026, 11, 26));
      expect(novPay.description, 'Dunn Club webinar 11/26/26');
      expect(novPay.source, IncomeSource.club);
    });

    test('the invite and the join link emails', () {
      final w = Webinar(
        id: 'dec',
        start: DateTime(2026, 12, 31, 20),
        topic: 'Holiday decorations',
        link: 'https://meet.google.com/abc',
      );
      final invite = inviteEmail(w);
      expect(
        invite.subject,
        "Let's Get This Dunn Club: Thursday, December 31 at 8:00 PM",
      );
      expect(invite.body, contains('This month: Holiday decorations.'));
      expect(
        invite.body,
        isNot(contains('meet.google.com')),
        reason: 'the link goes only to those who pay',
      );
      expect(
        joinLinkEmail(w).body,
        contains('Join here: https://meet.google.com/abc'),
      );
      final uri = membersMailto(
        ['a@x.com', 'b@y.com'],
        subject: invite.subject,
        body: invite.body,
      );
      expect(uri.scheme, 'mailto');
      expect(uri.path, isEmpty, reason: 'members are blind copied');
      expect(uri.queryParameters['bcc'], 'a@x.com,b@y.com');
      expect(uri.queryParameters['subject'], invite.subject);
    });
  });

  test('payments come from paid sessions, paid webinars and by hand', () {
    const sam = ClubMember(id: 's', email: 'sam@example.com');
    final payments = allPayments(
      clients: [jane],
      manual: [
        ManualPayment(
          id: 'm1',
          date: DateTime(2026, 11, 12),
          amount: 50,
          from: 'Library',
          description: 'Talk',
        ),
      ],
      club: clubPayments(
        webinars: [Webinar(id: 'w', start: DateTime(2026, 10, 29, 20))],
        members: [sam],
        seats: {
          seatKey('w', 's'): ClubDecision(
            ClubStatus.paid,
            method: PaymentMethod.zelle,
            paidOn: DateTime(2026, 10, 27),
          ),
        },
      ),
    );
    expect([for (final p in payments) p.amount], [50, 200, 20]);
    final session = payments[1];
    expect(session.from, 'Jane Smith');
    expect(session.date, DateTime(2026, 11, 8));
    expect(session.description, 'Session 11/10/26');
    expect(session.method, PaymentMethod.venmo);
    final club = payments.last;
    expect(club.source, IncomeSource.club);
    expect(club.date, DateTime(2026, 10, 27), reason: 'the day they paid');

    final rows = paymentRows(payments);
    expect(rows.first, [
      '2026-10-27',
      'sam@example.com',
      'Dunn Club webinar 10/29/26',
      "Let's Get This Dunn Club",
      'Zelle',
      20.0,
      '',
      'club:w|s',
    ]);
  });

  test('IRS mileage rates change on July 1, 2026', () {
    expect(irsRateOn(DateTime(2026, 6, 30)), 0.725);
    expect(irsRateOn(DateTime(2026, 7, 1)), 0.76);
    expect(irsRateOn(DateTime(2025, 3, 1)), 0.70);
    expect(irsRateOn(DateTime(2030, 1, 1)), isNull);
  });
}
