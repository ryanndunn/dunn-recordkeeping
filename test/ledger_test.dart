import 'package:flutter_test/flutter_test.dart';
import 'package:mileage_log/models/lead.dart';
import 'package:mileage_log/models/money.dart';
import 'package:mileage_log/models/saved_address.dart';
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
    final rows = [
      ['Timestamp', 'Email Address'],
      ['10/2/2026 9:00:00', 'Sam@Example.com'],
      ['11/3/2026 9:00:00', 'sam@example.com'],
      ['11/4/2026 10:00:00', 'jane@example.com'],
    ];

    test('the sign-up form is told apart from the contact form', () {
      expect(isContactFormHeader(rows.first), isFalse);
      expect(
        isContactFormHeader(['Timestamp', 'Name', 'Phone number', 'Email']),
        isTrue,
      );
    });

    test('someone\'s first meeting is free; later ones need confirming', () {
      final regs = parseClubResponses(rows);
      expect(regs.map((r) => r.email), [
        'sam@example.com',
        'sam@example.com',
        'jane@example.com',
      ]);
      expect(clubStatusOf(regs[0], regs, {}), ClubStatus.free);
      expect(clubStatusOf(regs[1], regs, {}), ClubStatus.toConfirm);
      expect(clubStatusOf(regs[2], regs, {}), ClubStatus.free);
      expect(
        clubStatusOf(regs[1], regs, {
          regs[1].id: const ClubDecision(ClubStatus.unpaid),
        }),
        ClubStatus.unpaid,
      );
    });

    test('sign-ups become one lead per person, except existing clients', () {
      final leads = clubLeads(parseClubResponses(rows), [jane]);
      expect(leads.single.email, 'sam@example.com');
      expect(leads.single.source, LeadSource.club);
      expect(leads.single.help, contains('2 times'));
    });
  });

  test('payments come from paid sessions, paid sign-ups and by hand', () {
    final regs = parseClubResponses([
      ['Timestamp', 'Email'],
      ['10/2/2026 9:00:00', 'sam@example.com'],
      ['11/3/2026 9:00:00', 'sam@example.com'],
    ]);
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
      registrations: regs,
      clubDecisions: {
        regs[1].id: ClubDecision(ClubStatus.paid, method: PaymentMethod.zelle),
      },
    );
    expect([for (final p in payments) p.amount], [50, 200, 20]);
    final session = payments[1];
    expect(session.from, 'Jane Smith');
    expect(session.date, DateTime(2026, 11, 8));
    expect(session.description, 'Session 11/10/26');
    expect(session.method, PaymentMethod.venmo);
    final club = payments.last;
    expect(club.source, IncomeSource.club);
    expect(club.date, DateTime(2026, 11, 3), reason: 'the sign-up day');

    final rows = paymentRows(payments);
    expect(rows.first, [
      '2026-11-03',
      'sam@example.com',
      'Dunn Club, signed up 11/03/26',
      "Let's Get This Dunn Club",
      'Zelle',
      20.0,
      '',
      'club:${regs[1].id}',
    ]);
  });

  test('IRS mileage rates change on July 1, 2026', () {
    expect(irsRateOn(DateTime(2026, 6, 30)), 0.725);
    expect(irsRateOn(DateTime(2026, 7, 1)), 0.76);
    expect(irsRateOn(DateTime(2025, 3, 1)), 0.70);
    expect(irsRateOn(DateTime(2030, 1, 1)), isNull);
  });
}
