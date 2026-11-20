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
    this.stripeId,
    this.link,
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

  /// The Stripe payment that paid it (a Checkout Session ID), if it was
  /// matched from Stripe. Only while paid.
  final String? stripeId;

  /// The Stripe payment link sent for it, until it's paid.
  final SessionPaymentLink? link;

  /// The same, without the payment link (e.g. once it's turned off).
  SessionBilling withoutLink() => SessionBilling(
    status: status,
    method: method,
    paidOn: paidOn,
    amount: amount,
    stripeId: stripeId,
  );

  Map<String, dynamic> toJson() => {
    'status': status.name,
    if (status == BillingStatus.paid) ...{
      if (method != null) 'method': method!.name,
      if (paidOn != null) 'paidOn': dateOnly(paidOn!),
      if (amount != null) 'amount': amount,
      if (stripeId != null) 'stripeId': stripeId,
    },
    if (status != BillingStatus.paid && link != null) 'link': link!.toJson(),
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
    stripeId: json['stripeId'] as String?,
    link: json['link'] is Map<String, dynamic>
        ? SessionPaymentLink.fromJson(json['link'] as Map<String, dynamic>)
        : null,
  );

  @override
  bool operator ==(Object other) =>
      other is SessionBilling &&
      other.status == status &&
      other.method == method &&
      other.paidOn == paidOn &&
      other.amount == amount &&
      other.stripeId == stripeId &&
      other.link == link;

  @override
  int get hashCode =>
      Object.hash(status, method, paidOn, amount, stripeId, link);
}

/// A one-time Stripe payment link made for a session.
class SessionPaymentLink {
  const SessionPaymentLink({
    required this.id,
    required this.url,
    required this.amount,
    required this.createdOn,
  });

  /// "plink_…".
  final String id;
  final String url;

  /// What it charges, in dollars.
  final double amount;
  final DateTime createdOn;

  Map<String, dynamic> toJson() => {
    'id': id,
    'url': url,
    'amount': amount,
    'createdOn': dateOnly(createdOn),
  };

  factory SessionPaymentLink.fromJson(Map<String, dynamic> json) =>
      SessionPaymentLink(
        id: json['id'] as String,
        url: json['url'] as String,
        amount: (json['amount'] as num).toDouble(),
        createdOn: DateTime.parse(json['createdOn'] as String),
      );

  @override
  bool operator ==(Object other) =>
      other is SessionPaymentLink &&
      other.id == id &&
      other.url == url &&
      other.amount == amount &&
      other.createdOn == createdOn;

  @override
  int get hashCode => Object.hash(id, url, amount, createdOn);
}

String _two(int n) => n.toString().padLeft(2, '0');

/// "2026-11-17": a calendar date that reads the same in any time zone.
String dateOnly(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';
