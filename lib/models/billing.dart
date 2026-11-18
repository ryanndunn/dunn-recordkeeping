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
  const SessionBilling({this.status = BillingStatus.needToBill, this.method});

  /// A session nothing has been recorded for.
  static const unbilled = SessionBilling();

  final BillingStatus status;

  /// Only kept while [status] is paid.
  final PaymentMethod? method;

  Map<String, dynamic> toJson() => {
    'status': status.name,
    if (method != null && status == BillingStatus.paid) 'method': method!.name,
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
  );

  @override
  bool operator ==(Object other) =>
      other is SessionBilling &&
      other.status == status &&
      other.method == method;

  @override
  int get hashCode => Object.hash(status, method);
}
