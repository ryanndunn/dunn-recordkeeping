import 'billing.dart';

/// Where income came from.
enum IncomeSource {
  session('Client session'),
  club('Let\'s Get This Dunn Club'),
  other('Other');

  const IncomeSource(this.label);
  final String label;
}

/// Business expense categories, close to the lines of Schedule C so the
/// totals are easy to hand to an accountant.
enum ExpenseCategory {
  advertising('Advertising & marketing'),
  supplies('Supplies'),
  software('Software & subscriptions'),
  office('Office expenses'),
  education('Education & training'),
  meals('Business meals'),
  insurance('Insurance'),
  fees('Bank & payment fees'),
  professional('Legal & professional'),
  travel('Travel (not mileage)'),
  phone('Phone & internet'),
  other('Other');

  const ExpenseCategory(this.label);
  final String label;
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

DateTime _parseDay(String s) => _day(DateTime.parse(s));

/// Income entered by hand (not from a session or the Dunn Club).
class ManualPayment {
  const ManualPayment({
    required this.id,
    required this.date,
    required this.amount,
    this.from = '',
    this.description = '',
    this.method,
    this.notes = '',
  });

  final String id;
  final DateTime date;
  final double amount;

  /// Who paid.
  final String from;

  /// What it was for.
  final String description;
  final PaymentMethod? method;
  final String notes;

  Map<String, dynamic> toJson() => {
    'date': dateOnly(date),
    'amount': amount,
    if (from.isNotEmpty) 'from': from,
    if (description.isNotEmpty) 'description': description,
    if (method != null) 'method': method!.name,
    if (notes.isNotEmpty) 'notes': notes,
  };

  factory ManualPayment.fromJson(String id, Map<String, dynamic> json) =>
      ManualPayment(
        id: id,
        date: _parseDay(json['date'] as String),
        amount: (json['amount'] as num).toDouble(),
        from: json['from'] as String? ?? '',
        description: json['description'] as String? ?? '',
        method: PaymentMethod.values
            .where((m) => m.name == json['method'])
            .firstOrNull,
        notes: json['notes'] as String? ?? '',
      );
}

/// A business expense.
class Expense {
  const Expense({
    required this.id,
    required this.date,
    required this.amount,
    required this.category,
    this.vendor = '',
    this.method = '',
    this.notes = '',
  });

  final String id;
  final DateTime date;
  final double amount;
  final ExpenseCategory category;

  /// Who was paid (store, service).
  final String vendor;

  /// How it was paid (card, cash, …), free text.
  final String method;
  final String notes;

  Map<String, dynamic> toJson() => {
    'date': dateOnly(date),
    'amount': amount,
    'category': category.name,
    if (vendor.isNotEmpty) 'vendor': vendor,
    if (method.isNotEmpty) 'method': method,
    if (notes.isNotEmpty) 'notes': notes,
  };

  factory Expense.fromJson(String id, Map<String, dynamic> json) => Expense(
    id: id,
    date: _parseDay(json['date'] as String),
    amount: (json['amount'] as num).toDouble(),
    category:
        ExpenseCategory.values
            .where((c) => c.name == json['category'])
            .firstOrNull ??
        ExpenseCategory.other,
    vendor: json['vendor'] as String? ?? '',
    method: json['method'] as String? ?? '',
    notes: json['notes'] as String? ?? '',
  );
}

/// The monthly webinar's price after someone's first (free) meeting.
const clubPrice = 20.0;

/// Someone signing up for Let's Get This Dunn Club (one form response).
class ClubRegistration {
  const ClubRegistration({
    required this.id,
    required this.at,
    required this.email,
    this.name = '',
  });

  final String id;
  final DateTime at;
  final String email;
  final String name;

  Map<String, dynamic> toJson() => {
    'id': id,
    'at': at.toIso8601String(),
    'email': email,
    if (name.isNotEmpty) 'name': name,
  };

  factory ClubRegistration.fromJson(Map<String, dynamic> json) =>
      ClubRegistration(
        id: json['id'] as String,
        at: DateTime.parse(json['at'] as String),
        email: json['email'] as String? ?? '',
        name: json['name'] as String? ?? '',
      );
}

enum ClubStatus {
  /// Their first meeting, which is free.
  free('Free (first meeting)'),

  /// Paid the $20.
  paid('Paid'),

  /// Not paid (didn't come, or waived).
  unpaid('Not paid'),

  /// Not decided yet.
  toConfirm('To confirm');

  const ClubStatus(this.label);
  final String label;
}

/// What was recorded for a registration. Synced between devices.
class ClubDecision {
  const ClubDecision(this.status, {this.method, this.paidOn, this.amount});

  final ClubStatus status;
  final PaymentMethod? method;
  final DateTime? paidOn;
  final double? amount;

  Map<String, dynamic> toJson() => {
    'status': status.name,
    if (status == ClubStatus.paid) ...{
      if (method != null) 'method': method!.name,
      if (paidOn != null) 'paidOn': dateOnly(paidOn!),
      if (amount != null) 'amount': amount,
    },
  };

  factory ClubDecision.fromJson(Map<String, dynamic> json) => ClubDecision(
    ClubStatus.values.where((s) => s.name == json['status']).firstOrNull ??
        ClubStatus.toConfirm,
    method: PaymentMethod.values
        .where((m) => m.name == json['method'])
        .firstOrNull,
    paidOn: json['paidOn'] == null ? null : _parseDay(json['paidOn'] as String),
    amount: (json['amount'] as num?)?.toDouble(),
  );
}

/// What kind of record a ledger payment comes from (to open or edit it).
enum PaymentKind { session, club, manual }

/// One row of the payments table, whatever it came from.
class LedgerPayment {
  const LedgerPayment({
    required this.id,
    required this.kind,
    required this.date,
    required this.amount,
    required this.source,
    required this.from,
    required this.description,
    this.method,
    this.notes = '',
    this.clientId,
  });

  /// Stable: `session:<client>:<key>`, `club:<registration>` or the
  /// manual payment's ID.
  final String id;
  final PaymentKind kind;
  final DateTime date;
  final double amount;
  final IncomeSource source;
  final String from;
  final String description;
  final PaymentMethod? method;
  final String notes;

  /// The client, for session payments.
  final String? clientId;
}
