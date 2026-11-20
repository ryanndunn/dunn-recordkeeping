import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/money.dart';
import '../models/saved_address.dart';
import 'client_jobs.dart';

/// A payment received through Stripe: a completed checkout (what a
/// payment link makes), with the fee Stripe kept and anything refunded.
class StripePayment {
  const StripePayment({
    required this.id,
    required this.at,
    required this.amount,
    this.fee = 0,
    this.refunded = 0,
    this.email = '',
    this.name = '',
    this.method = PaymentMethod.stripeCard,
    this.paymentLink,
  });

  /// The Checkout Session's ID ("cs_…").
  final String id;
  final DateTime at;

  /// Dollars charged.
  final double amount;

  /// Stripe's fee, in dollars.
  final double fee;

  /// Dollars refunded since.
  final double refunded;

  /// Who paid, as they typed it at checkout.
  final String email;
  final String name;

  /// Card, Affirm or Klarna.
  final PaymentMethod method;

  /// The payment link they paid through ("plink_…"), if any.
  final String? paymentLink;

  /// What was kept: the amount less refunds.
  double get net => ((amount - refunded) * 100).round() / 100;

  bool get fullyRefunded => net <= 0;

  /// Their name, or email if no name was given.
  String get who => name.isNotEmpty ? name : email;

  Map<String, dynamic> toJson() => {
    'id': id,
    'at': at.toUtc().toIso8601String(),
    'amount': amount,
    if (fee != 0) 'fee': fee,
    if (refunded != 0) 'refunded': refunded,
    if (email.isNotEmpty) 'email': email,
    if (name.isNotEmpty) 'name': name,
    'method': method.name,
    if (paymentLink != null) 'paymentLink': paymentLink,
  };

  factory StripePayment.fromJson(Map<String, dynamic> json) => StripePayment(
    id: json['id'] as String,
    at: DateTime.parse(json['at'] as String),
    amount: (json['amount'] as num).toDouble(),
    fee: (json['fee'] as num?)?.toDouble() ?? 0,
    refunded: (json['refunded'] as num?)?.toDouble() ?? 0,
    email: json['email'] as String? ?? '',
    name: json['name'] as String? ?? '',
    method:
        PaymentMethod.values
            .where((m) => m.name == json['method'])
            .firstOrNull ??
        PaymentMethod.stripeCard,
    paymentLink: json['paymentLink'] as String?,
  );
}

/// Card, Affirm or Klarna, from Stripe's payment method type. Anything
/// else (Link, wallets) is a card payment as far as the books go.
PaymentMethod stripeMethod(String? type) => switch (type) {
  'affirm' => PaymentMethod.stripeAffirm,
  'klarna' => PaymentMethod.stripeKlarna,
  _ => PaymentMethod.stripeCard,
};

double _dollars(Object? cents) => ((cents as num?) ?? 0) / 100;

/// A completed, paid Checkout Session (from the API, with
/// `payment_intent.latest_charge.balance_transaction` expanded) as a
/// payment. Null if it isn't paid (yet) or charged nothing.
StripePayment? paymentFromCheckout(Map<String, dynamic> s) {
  if (s['status'] != 'complete' || s['payment_status'] != 'paid') return null;
  final amount = _dollars(s['amount_total']);
  if (amount <= 0) return null;
  final customer = s['customer_details'] as Map<String, dynamic>? ?? const {};
  final intent = s['payment_intent'];
  final charge = intent is Map<String, dynamic>
      ? intent['latest_charge']
      : null;
  Map<String, dynamic>? chargeMap = charge is Map<String, dynamic>
      ? charge
      : null;
  final balance = chargeMap?['balance_transaction'];
  final details = chargeMap?['payment_method_details'] as Map<String, dynamic>?;
  final link = s['payment_link'];
  return StripePayment(
    id: s['id'] as String,
    at: DateTime.fromMillisecondsSinceEpoch(
      ((s['created'] as num) * 1000).toInt(),
      isUtc: true,
    ),
    amount: amount,
    fee: balance is Map<String, dynamic> ? _dollars(balance['fee']) : 0,
    refunded: _dollars(chargeMap?['amount_refunded']),
    email: ((customer['email'] as String?) ?? '').trim().toLowerCase(),
    name: ((customer['name'] as String?) ?? '').trim(),
    method: stripeMethod(details?['type'] as String?),
    paymentLink: link is String ? link : (link as Map?)?['id'] as String?,
  );
}

class StripeException implements Exception {
  const StripeException(this.message, {this.badKey = false});
  final String message;

  /// The key is wrong, revoked, or lacks a permission.
  final bool badKey;

  @override
  String toString() => message;
}

/// Reads payments from Stripe.
abstract class StripeSource {
  /// Paid checkouts created on or after [since], newest first.
  Future<List<StripePayment>> paymentsSince(DateTime since);
}

/// Stripe's API, with a restricted (read-only) key.
class StripeApi implements StripeSource {
  StripeApi(this._key, {http.Client? client})
    : _client = client ?? http.Client();

  final String _key;
  final http.Client _client;

  @override
  Future<List<StripePayment>> paymentsSince(DateTime since) async {
    final out = <StripePayment>[];
    String? after;
    for (var page = 0; page < 50; page++) {
      final uri = Uri.https('api.stripe.com', '/v1/checkout/sessions', {
        'limit': '100',
        'status': 'complete',
        'created[gte]': '${since.toUtc().millisecondsSinceEpoch ~/ 1000}',
        'expand[]': 'data.payment_intent.latest_charge.balance_transaction',
        'starting_after': ?after,
      });
      final http.Response res;
      try {
        res = await _client.get(
          uri,
          headers: {'Authorization': 'Bearer $_key'},
        );
      } catch (e) {
        throw StripeException('Couldn\'t reach Stripe: $e');
      }
      final body = _json(res.body);
      if (res.statusCode != 200) {
        final error = body?['error'];
        final message = error is Map ? error['message'] as String? : null;
        throw StripeException(
          message ?? 'Stripe answered ${res.statusCode}.',
          badKey: res.statusCode == 401 || res.statusCode == 403,
        );
      }
      final data = (body?['data'] as List?) ?? const [];
      for (final s in data) {
        final p = paymentFromCheckout(s as Map<String, dynamic>);
        if (p != null) out.add(p);
      }
      if (body?['has_more'] != true || data.isEmpty) break;
      after = (data.last as Map<String, dynamic>)['id'] as String;
    }
    return out;
  }

  static Map<String, dynamic>? _json(String body) {
    try {
      final v = jsonDecode(body);
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }
}

// --------------------------------------------------------------- matching

/// What was decided about a Stripe payment: the client's session it paid
/// for, or that it isn't for a session (other income, maybe from a
/// client). Synced between devices.
class StripeDecision {
  const StripeDecision({
    this.clientId,
    this.sessionKey,
    this.automatic = false,
  });

  final String? clientId;

  /// The session's billing key (see `ClientJobEntry.billingKeys`); null:
  /// not for a session.
  final String? sessionKey;

  /// Matched by the app (not picked by hand).
  final bool automatic;

  bool get forSession => clientId != null && sessionKey != null;

  Map<String, dynamic> toJson() => {
    if (clientId != null) 'clientId': clientId,
    if (sessionKey != null) 'sessionKey': sessionKey,
    if (automatic) 'automatic': true,
  };

  factory StripeDecision.fromJson(Map<String, dynamic> json) => StripeDecision(
    clientId: json['clientId'] as String?,
    sessionKey: json['sessionKey'] as String?,
    automatic: json['automatic'] as bool? ?? false,
  );
}

bool _sameMoney(double? a, double b) => a != null && (a - b).abs() < 0.005;

/// The session [payment] most likely paid for, among [client]'s
/// [sessions], or null if it isn't clear. Sessions linked to another
/// Stripe payment are skipped. A session already marked paid by Stripe
/// for the same amount (by hand, before Stripe was connected) is picked
/// first; otherwise the one unpaid session billing that amount, if
/// exactly one does.
ClientJobEntry? pickSession(
  StripePayment payment,
  SavedAddress client,
  List<ClientJobEntry> sessions,
) {
  final open = [
    for (final e in sessions)
      if (billingFor(client, e).stripeId == null) e,
  ];
  final markedByHand = [
    for (final e in open)
      if (billingFor(client, e) case final b
          when b.status == BillingStatus.paid &&
              (b.method?.isStripe ?? false) &&
              _sameMoney(b.amount, payment.net))
        e,
  ];
  if (markedByHand.length == 1) return markedByHand.single;
  if (markedByHand.length > 1) return null;
  final sameAmount = [
    for (final e in open)
      if (billingFor(client, e).status != BillingStatus.paid &&
          _sameMoney(sessionAmount(client, e), payment.net))
        e,
  ];
  return sameAmount.length == 1 ? sameAmount.single : null;
}

/// [client] with [session] paid by [payment].
SavedAddress paidByStripe(
  SavedAddress client,
  ClientJobEntry session,
  StripePayment payment,
) {
  final d = payment.at.toLocal();
  return withBilling(
    client,
    session,
    SessionBilling(
      status: BillingStatus.paid,
      method: payment.method,
      paidOn: DateTime(d.year, d.month, d.day),
      amount: payment.net,
      stripeId: payment.id,
    ),
  );
}

/// [client] without [paymentId] on any session: a session it had paid
/// goes back to "Need to bill".
SavedAddress withoutStripe(SavedAddress client, String paymentId) =>
    client.copyWith(
      billing: {
        for (final e in client.billing.entries)
          if (e.value.stripeId != paymentId) e.key: e.value,
      },
    );

// ------------------------------------------------------------------ fees

/// Stripe's fees as business expenses, one per month (Stripe takes them
/// out of each payout, so they never show up as a charge).
List<Expense> stripeFeeExpenses(List<StripePayment> payments) {
  final byMonth = <DateTime, List<StripePayment>>{};
  for (final p in payments) {
    if (p.fee <= 0) continue;
    final d = p.at.toLocal();
    (byMonth[DateTime(d.year, d.month)] ??= []).add(p);
  }
  return [
    for (final e in byMonth.entries)
      Expense(
        id: 'stripefees:${e.key.year}-${e.key.month.toString().padLeft(2, '0')}',
        // The month's last fee, so the month reads right in the table.
        date: e.value
            .map((p) => p.at.toLocal())
            .reduce((a, b) => a.isAfter(b) ? a : b),
        amount:
            (e.value.fold<double>(0, (s, p) => s + p.fee) * 100).round() / 100,
        category: ExpenseCategory.fees,
        vendor: 'Stripe',
        method: 'Taken from payouts',
        notes: e.value.length == 1
            ? 'Fee on 1 Stripe payment'
            : 'Fees on ${e.value.length} Stripe payments',
      ),
  ];
}
