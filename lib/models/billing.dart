/// Where a session is in getting paid. Clients pre-pay, so this applies
/// to upcoming sessions too.
enum BillingStatus {
  needToBill('Need to bill'),
  billed('Billed'),
  paid('Paid');

  const BillingStatus(this.label);
  final String label;
}

/// How a client paid. Stripe payments are by card, Affirm or Klarna.
enum PaymentMethod {
  check('Check'),
  cash('Cash'),
  venmo('Venmo'),
  zelle('Zelle'),
  stripeCard('Stripe · Card'),
  stripeAffirm('Stripe · Affirm'),
  stripeKlarna('Stripe · Klarna');

  const PaymentMethod(this.label);
  final String label;

  bool get isStripe => name.startsWith('stripe');
}

/// The billing status of one session (and how it was paid, once paid).
class SessionBilling {
  const SessionBilling({
    this.status = BillingStatus.needToBill,
    this.method,
    this.paidOn,
    this.amount,
  });

  /// A session nothing has been recorded for.
  static const unbilled = SessionBilling();

  final BillingStatus status;

  /// Only kept while [status] is paid.
  final PaymentMethod? method;

  /// When the payment came in, and how much (kept as recorded, for tax
  /// records, even if the rate changes later). Only while paid.
  final DateTime? paidOn;
  final double? amount;

  Map<String, dynamic> toJson() => {
    'status': status.name,
    if (status == BillingStatus.paid) ...{
      if (method != null) 'method': method!.name,
      if (paidOn != null) 'paidOn': dateOnly(paidOn!),
      if (amount != null) 'amount': amount,
    },
  };

  factory SessionBilling.fromJson(Map<String, dynamic> json) => SessionBilling(
    status:
        BillingStatus.values
            .where((s) => s.name == json['status'])
            .firstOrNull ??
        BillingStatus.needToBill,
    method: PaymentMethod.values
        .where((m) => m.name == json['method'])
        .firstOrNull,
    paidOn: json['paidOn'] == null
        ? null
        : DateTime.parse(json['paidOn'] as String),
    amount: (json['amount'] as num?)?.toDouble(),
  );

  @override
  bool operator ==(Object other) =>
      other is SessionBilling &&
      other.status == status &&
      other.method == method &&
      other.paidOn == paidOn &&
      other.amount == amount;

  @override
  int get hashCode => Object.hash(status, method, paidOn, amount);
}

String _two(int n) => n.toString().padLeft(2, '0');

/// "2026-11-17": a calendar date that reads the same in any time zone.
String dateOnly(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';
