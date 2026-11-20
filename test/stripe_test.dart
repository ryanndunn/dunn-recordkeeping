import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mileage_log/models/money.dart';
import 'package:mileage_log/models/saved_address.dart';
import 'package:mileage_log/services/client_jobs.dart';
import 'package:mileage_log/services/ledger.dart';
import 'package:mileage_log/services/stripe.dart';

/// A Checkout Session as Stripe's API returns it (expanded down to the
/// balance transaction).
Map<String, dynamic> checkout({
  String id = 'cs_1',
  int cents = 30000,
  String type = 'card',
  int fee = 900,
  int refunded = 0,
  String status = 'complete',
  String paid = 'paid',
  String email = 'Jane@Example.com',
  String? name = 'Jane Smith',
  DateTime? created,
}) => {
  'id': id,
  'object': 'checkout.session',
  'status': status,
  'payment_status': paid,
  'amount_total': cents,
  'created':
      (created ?? DateTime.utc(2026, 11, 17, 12)).millisecondsSinceEpoch ~/
      1000,
  'payment_link': 'plink_123',
  'customer_details': {'email': email, 'name': name},
  'payment_intent': {
    'id': 'pi_1',
    'latest_charge': {
      'id': 'ch_1',
      'amount_refunded': refunded,
      'payment_method_details': {type: <String, dynamic>{}, 'type': type},
      'balance_transaction': {'id': 'txn_1', 'fee': fee},
    },
  },
};

void main() {
  group('reading Stripe', () {
    test('a paid card checkout', () {
      final p = paymentFromCheckout(checkout())!;
      expect(p.id, 'cs_1');
      expect(p.amount, 300);
      expect(p.fee, 9);
      expect(p.net, 300);
      expect(p.email, 'jane@example.com');
      expect(p.name, 'Jane Smith');
      expect(p.method, PaymentMethod.stripeCard);
      expect(p.paymentLink, 'plink_123');
      expect(p.at, DateTime.utc(2026, 11, 17, 12));
      expect(StripePayment.fromJson(p.toJson()).toJson(), p.toJson());
    });

    test('Affirm and Klarna; refunds', () {
      expect(
        paymentFromCheckout(checkout(type: 'affirm'))!.method,
        PaymentMethod.stripeAffirm,
      );
      final k = paymentFromCheckout(checkout(type: 'klarna', refunded: 10000))!;
      expect(k.method, PaymentMethod.stripeKlarna);
      expect(k.refunded, 100);
      expect(k.net, 200);
      expect(
        paymentFromCheckout(checkout(refunded: 30000))!.fullyRefunded,
        isTrue,
      );
    });

    test('unpaid, unfinished and free checkouts are left out', () {
      expect(paymentFromCheckout(checkout(paid: 'unpaid')), isNull);
      expect(paymentFromCheckout(checkout(status: 'open')), isNull);
      expect(paymentFromCheckout(checkout(cents: 0)), isNull);
    });

    test('the API is read page by page with the key', () async {
      final requests = <http.Request>[];
      final api = StripeApi(
        'rk_test_abc',
        client: MockClient((req) async {
          requests.add(req);
          final after = req.url.queryParameters['starting_after'];
          return http.Response(
            jsonEncode(
              after == null
                  ? {
                      'data': [checkout(id: 'cs_a'), checkout(id: 'cs_b')],
                      'has_more': true,
                    }
                  : {
                      'data': [checkout(id: 'cs_c', paid: 'unpaid')],
                      'has_more': false,
                    },
            ),
            200,
          );
        }),
      );
      final got = await api.paymentsSince(DateTime.utc(2025));
      expect(got.map((p) => p.id), ['cs_a', 'cs_b']);
      expect(requests, hasLength(2));
      final first = requests.first;
      expect(first.headers['Authorization'], 'Bearer rk_test_abc');
      expect(first.url.path, '/v1/checkout/sessions');
      expect(first.url.queryParameters['created[gte]'], '1735689600');
      expect(
        first.url.queryParameters['expand[]'],
        'data.payment_intent.latest_charge.balance_transaction',
      );
      expect(requests.last.url.queryParameters['starting_after'], 'cs_b');
    });

    test('Stripe\'s error message comes through', () async {
      final api = StripeApi(
        'rk_live_bad',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'error': {
                'message':
                    'The provided key does not have the required '
                    'permissions for this endpoint.',
              },
            }),
            403,
          ),
        ),
      );
      await expectLater(
        api.paymentsSince(DateTime(2025)),
        throwsA(
          isA<StripeException>()
              .having((e) => e.badKey, 'badKey', isTrue)
              .having((e) => e.message, 'message', contains('permissions')),
        ),
      );
    });
  });

  group('which session', () {
    StripePayment pay(double amount) =>
        StripePayment(id: 'cs_x', at: DateTime(2026, 11, 17), amount: amount);
    ClientJobEntry booked(String id, int day, {int hours = 3}) =>
        ClientJobEntry(
          state: ClientJobState.upcoming,
          start: DateTime(2026, 11, day, 9),
          scheduled: ScheduledJob(
            id: id,
            start: DateTime(2026, 11, day, 9),
            end: DateTime(2026, 11, day, 9 + hours),
          ),
        );
    SavedAddress client([Map<String, SessionBilling> billing = const {}]) =>
        SavedAddress(
          id: 'c',
          name: 'Jane',
          address: 'a',
          hourlyRate: 100,
          billing: billing,
        );

    test('the one unpaid session billing that amount', () {
      final sessions = [booked('a', 18), booked('b', 25, hours: 2)];
      expect(pickSession(pay(300), client(), sessions)?.scheduled?.id, 'a');
      expect(pickSession(pay(200), client(), sessions)?.scheduled?.id, 'b');
      expect(pickSession(pay(250), client(), sessions), isNull);
    });

    test('two sessions for the same amount: ask', () {
      final sessions = [booked('a', 18), booked('b', 25)];
      expect(pickSession(pay(300), client(), sessions), isNull);
    });

    test('paid sessions are skipped, unless marked paid by Stripe by hand', () {
      final sessions = [booked('a', 18), booked('b', 25)];
      final paidByCash = client({
        'a': const SessionBilling(
          status: BillingStatus.paid,
          method: PaymentMethod.cash,
          amount: 300,
        ),
      });
      expect(pickSession(pay(300), paidByCash, sessions)?.scheduled?.id, 'b');
      final markedStripe = client({
        'b': const SessionBilling(
          status: BillingStatus.paid,
          method: PaymentMethod.stripeKlarna,
          amount: 300,
        ),
      });
      expect(
        pickSession(pay(300), markedStripe, sessions)?.scheduled?.id,
        'b',
        reason: 'it was this payment, recorded by hand',
      );
      final linked = client({
        'a': const SessionBilling(
          status: BillingStatus.paid,
          method: PaymentMethod.stripeCard,
          amount: 300,
          stripeId: 'cs_other',
        ),
      });
      expect(pickSession(pay(300), linked, sessions)?.scheduled?.id, 'b');
    });

    test('linking marks it paid; unlinking puts it back', () {
      final s = booked('a', 18);
      final p = StripePayment(
        id: 'cs_x',
        at: DateTime(2026, 11, 17, 15),
        amount: 300,
        method: PaymentMethod.stripeAffirm,
      );
      final paid = paidByStripe(client(), s, p);
      final b = paid.billing['a']!;
      expect(b.status, BillingStatus.paid);
      expect(b.method, PaymentMethod.stripeAffirm);
      expect(b.amount, 300);
      expect(b.paidOn, DateTime(2026, 11, 17));
      expect(b.stripeId, 'cs_x');
      expect(SessionBilling.fromJson(b.toJson()), b);
      expect(withoutStripe(paid, 'cs_x').billing, isEmpty);
    });
  });

  group('in the books', () {
    final jane = SavedAddress(
      id: 'j',
      name: 'Jane Smith',
      address: 'a',
      scheduled: [
        ScheduledJob(
          id: 'b1',
          start: DateTime(2026, 11, 18, 9),
          end: DateTime(2026, 11, 18, 12),
        ),
      ],
      billing: const {
        'b1': SessionBilling(
          status: BillingStatus.paid,
          method: PaymentMethod.stripeCard,
          amount: 300,
          stripeId: 'cs_1',
        ),
      },
    );
    final stripe = [
      StripePayment(
        id: 'cs_1',
        at: DateTime(2026, 11, 17, 15),
        amount: 300,
        fee: 9,
      ),
      StripePayment(
        id: 'cs_2',
        at: DateTime(2026, 11, 19, 15),
        amount: 150,
        fee: 4.65,
        refunded: 50,
        name: 'Sam Payer',
      ),
      StripePayment(
        id: 'cs_3',
        at: DateTime(2026, 12, 1, 15),
        amount: 75,
        fee: 2.48,
        refunded: 75,
      ),
    ];

    test(
      'each Stripe payment once; the session it paid isn\'t counted again',
      () {
        final ledger = allPayments(
          clients: [jane],
          manual: const [],
          registrations: const [],
          clubDecisions: const {},
          stripe: stripe,
          stripeDecisions: const {
            'cs_1': StripeDecision(clientId: 'j', sessionKey: 'b1'),
          },
        );
        expect(ledger.map((p) => p.id), ['stripe:cs_2', 'stripe:cs_1']);
        final s = ledger.last;
        expect(s.kind, PaymentKind.stripe);
        expect(s.amount, 300);
        expect(s.from, 'Jane Smith');
        expect(s.source, IncomeSource.session);
        expect(s.description, 'Session 11/18/26 (Stripe)');
        expect(s.notes, 'Stripe fee \$9.00');
        final other = ledger.first;
        expect(other.amount, 100, reason: 'refunded 50 of 150');
        expect(other.from, 'Sam Payer');
        expect(other.description, 'Stripe payment, not matched yet');
        expect(other.notes, contains('Refunded \$50.00 of \$150.00'));
      },
    );

    test('without the Stripe payment (not read here), the session counts', () {
      final ledger = allPayments(
        clients: [jane],
        manual: const [],
        registrations: const [],
        clubDecisions: const {},
      );
      expect(ledger.single.id, 'session:j:b1');
    });

    test('fees are an expense per month', () {
      final fees = stripeFeeExpenses(stripe);
      expect(fees.map((e) => e.id), [
        'stripefees:2026-11',
        'stripefees:2026-12',
      ]);
      expect(fees.first.amount, 13.65);
      expect(fees.first.category, ExpenseCategory.fees);
      expect(fees.first.vendor, 'Stripe');
      expect(fees.first.notes, 'Fees on 2 Stripe payments');
      expect(fees.last.amount, 2.48, reason: 'Stripe keeps fees on refunds');
    });
  });

  group('payment links', () {
    test('made with the amount, one payment, and the session tag', () async {
      late http.Request sent;
      final api = StripeApi(
        'rk_test_w',
        client: MockClient((req) async {
          sent = req;
          return http.Response(
            jsonEncode({
              'id': 'plink_9',
              'url': 'https://buy.stripe.com/test_9',
              'active': true,
            }),
            200,
          );
        }),
      );
      final link = await api.createPaymentLink(
        amount: 262.5,
        name: 'Organizing session · 11/20/26 · 2.5 hours',
        clientId: 'client-1',
        sessionKey: 'booking-7',
      );
      expect(link.id, 'plink_9');
      expect(link.url, 'https://buy.stripe.com/test_9');
      expect(sent.method, 'POST');
      expect(sent.url.path, '/v1/payment_links');
      expect(sent.headers['Authorization'], 'Bearer rk_test_w');
      final form = Uri.splitQueryString(sent.body);
      expect(form['line_items[0][price_data][currency]'], 'usd');
      expect(form['line_items[0][price_data][unit_amount]'], '26250');
      expect(
        form['line_items[0][price_data][product_data][name]'],
        'Organizing session · 11/20/26 · 2.5 hours',
      );
      expect(form['line_items[0][quantity]'], '1');
      expect(form['restrictions[completed_sessions][limit]'], '1');
      expect(form['metadata[dunn_client_id]'], 'client-1');
      expect(form['metadata[dunn_session_key]'], 'booking-7');
    });

    test('turned off with active=false', () async {
      late http.Request sent;
      final api = StripeApi(
        'rk_test_w',
        client: MockClient((req) async {
          sent = req;
          return http.Response(jsonEncode({'id': 'plink_9'}), 200);
        }),
      );
      await api.deactivatePaymentLink('plink_9');
      expect(sent.url.path, '/v1/payment_links/plink_9');
      expect(Uri.splitQueryString(sent.body), {'active': 'false'});
    });

    test('payments through them carry the client and session', () {
      final p = paymentFromCheckout({
        ...checkout(),
        'metadata': {
          'dunn_client_id': 'client-1',
          'dunn_session_key': 'booking-7',
        },
      })!;
      expect(p.clientId, 'client-1');
      expect(p.sessionKey, 'booking-7');
      expect(StripePayment.fromJson(p.toJson()).sessionKey, 'booking-7');
      expect(paymentFromCheckout(checkout())!.clientId, isNull);
    });

    test('the session for a payment: by tag, else by the saved link', () {
      final s1 = ClientJobEntry(
        state: ClientJobState.upcoming,
        start: DateTime(2026, 11, 20, 9),
        scheduled: ScheduledJob(id: 's1', start: DateTime(2026, 11, 20, 9)),
      );
      final s2 = ClientJobEntry(
        state: ClientJobState.upcoming,
        start: DateTime(2026, 11, 27, 9),
        scheduled: ScheduledJob(id: 's2', start: DateTime(2026, 11, 27, 9)),
      );
      final c = SavedAddress(
        id: 'c',
        name: 'Jane',
        address: 'a',
        billing: {
          's2': SessionBilling(
            status: BillingStatus.billed,
            link: SessionPaymentLink(
              id: 'plink_2',
              url: 'u',
              amount: 300,
              createdOn: DateTime(2026, 11, 19),
            ),
          ),
        },
      );
      List<ClientJobEntry> sessions(SavedAddress _) => [s1, s2];
      StripePayment pay({String? client, String? key, String? link}) =>
          StripePayment(
            id: 'cs',
            at: DateTime(2026, 11, 19),
            amount: 300,
            clientId: client,
            sessionKey: key,
            paymentLink: link,
          );
      expect(
        linkedSession(pay(client: 'c', key: 's1'), [c], sessions)?.session,
        s1,
      );
      expect(linkedSession(pay(link: 'plink_2'), [c], sessions)?.session, s2);
      expect(linkedSession(pay(link: 'plink_x'), [c], sessions), isNull);
      expect(
        linkedSession(pay(client: 'c', key: 'gone'), [c], sessions),
        isNull,
      );
    });

    test('saved on the session until paid', () {
      final link = SessionPaymentLink(
        id: 'plink_1',
        url: 'https://buy.stripe.com/x',
        amount: 300,
        createdOn: DateTime(2026, 11, 19),
      );
      final billed = SessionBilling(status: BillingStatus.billed, link: link);
      expect(SessionBilling.fromJson(billed.toJson()), billed);
      expect(
        SessionBilling(status: BillingStatus.paid, link: link).toJson(),
        isNot(contains('link')),
      );
      expect(billed.withoutLink().link, isNull);
    });

    test('name and pre-filled email', () {
      final s = ClientJobEntry(
        state: ClientJobState.upcoming,
        start: DateTime(2026, 11, 20, 9),
        scheduled: ScheduledJob(
          id: 's',
          start: DateTime(2026, 11, 20, 9),
          end: DateTime(2026, 11, 20, 10),
        ),
      );
      expect(paymentLinkName(s), 'Organizing session · 11/20/26 · 1 hour');
      expect(
        withPrefilledEmail('https://buy.stripe.com/x', 'a+b@example.com'),
        'https://buy.stripe.com/x?prefilled_email=a%2Bb%40example.com',
      );
      expect(
        withPrefilledEmail('https://buy.stripe.com/x', ''),
        'https://buy.stripe.com/x',
      );
    });
  });
}
