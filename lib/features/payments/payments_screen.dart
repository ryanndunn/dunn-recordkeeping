import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';

import '../../models/billing.dart';
import '../../models/money.dart';
import '../../services/client_jobs.dart';
import '../../services/jobs.dart' show formatHours;
import '../../services/ledger.dart';
import '../../state/money_provider.dart';
import '../../state/providers.dart';
import '../../state/stripe_provider.dart';
import '../../widgets/page_body.dart';
import '../../widgets/payment_fields.dart';
import '../clients/client_page.dart';
import '../clients/client_status.dart';
import '../../services/club.dart' show parseSeatKey;
import '../club/webinar_page.dart';
import 'send_bill_dialog.dart';
import 'stripe_page.dart';
import '../../widgets/refresh_all_button.dart';

const _uuid = Uuid();

DateTime _today(WidgetRef ref) {
  final n = ref.read(clockProvider)();
  return DateTime(n.year, n.month, n.day);
}

/// "$1,234.50".
String money(double v) {
  final cents = (v * 100).round();
  final neg = cents < 0;
  final whole = (cents.abs() ~/ 100).toString();
  final buf = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) buf.write(',');
    buf.write(whole[i]);
  }
  final c = (cents.abs() % 100).toString().padLeft(2, '0');
  return '${neg ? '-' : ''}\$$buf.$c';
}

/// Every payment received (sessions, Dunn Club, other) in one table, and
/// business expenses, by year, with the year's totals for taxes.
class PaymentsScreen extends ConsumerStatefulWidget {
  const PaymentsScreen({super.key});

  @override
  ConsumerState<PaymentsScreen> createState() => _PaymentsScreenState();
}

/// What the Billing tab lists.
enum _View { sessions, payments, expenses }

class _PaymentsScreenState extends ConsumerState<PaymentsScreen> {
  late int _year = ref.read(clockProvider)().year;
  _View _view = _View.sessions;

  bool get _expenses => _view == _View.expenses;

  Future<void> _add() async {
    if (_expenses) {
      await showDialog<void>(
        context: context,
        builder: (_) => const _ExpenseDialog(),
      );
    } else {
      await showDialog<void>(
        context: context,
        builder: (_) => const _PaymentDialog(),
      );
    }
  }

  Future<void> _openPayment(LedgerPayment p) async {
    switch (p.kind) {
      case PaymentKind.session:
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ClientPage(clientId: p.clientId!),
          ),
        );
      case PaymentKind.club:
        final seat = parseSeatKey(p.id.substring('club:'.length));
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => WebinarPage(id: seat.webinarId),
          ),
        );
      case PaymentKind.stripe:
        final id = p.id.substring('stripe:'.length);
        final payment = ref
            .read(stripeProvider)
            .payments
            .where((x) => x.id == id)
            .firstOrNull;
        if (payment != null) await showStripePayment(context, ref, payment);
      case PaymentKind.manual:
        final m = ref
            .read(manualPaymentsProvider)
            .where((x) => x.id == p.id)
            .firstOrNull;
        if (m == null) return;
        await showDialog<void>(
          context: context,
          builder: (_) => _PaymentDialog(existing: m),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ledger = ref.watch(ledgerProvider);
    final expenses = ref.watch(allExpensesProvider);
    final trips = ref.watch(tripsProvider);
    final now = ref.read(clockProvider)();

    final years = {
      now.year,
      for (final p in ledger) p.date.year,
      for (final e in expenses) e.date.year,
      for (final t in trips) t.date.year,
    }.toList()..sort((a, b) => b.compareTo(a));

    final payments = [
      for (final p in ledger)
        if (p.date.year == _year) p,
    ];
    final spent = [
      for (final e in expenses)
        if (e.date.year == _year) e,
    ];
    final sessions = ref.watch(allSessionsProvider);
    final toBill = [
      for (final r in sessions)
        if (r.status == BillingStatus.needToBill) r,
    ];
    final billed = [
      for (final r in sessions)
        if (r.status == BillingStatus.billed) r,
    ];
    final paid = [
      for (final r in sessions)
        if (r.status == BillingStatus.paid && r.paidDay.year == _year) r,
    ];
    final income = payments.fold<double>(0, (s, p) => s + p.amount);
    final outgo = spent.fold<double>(0, (s, e) => s + e.amount);
    var miles = 0.0;
    var deduction = 0.0;
    var rateKnown = true;
    for (final t in trips) {
      if (t.date.year != _year) continue;
      miles += t.miles;
      final rate = irsRateOn(t.date);
      if (rate == null) {
        rateKnown = false;
      } else {
        deduction += t.miles * rate;
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Billing'),
        actions: const [RefreshAllButton()],
      ),
      floatingActionButton: _view == _View.sessions
          ? null
          : FloatingActionButton.extended(
              onPressed: _add,
              icon: const Icon(Icons.add),
              label: Text(_expenses ? 'Add expense' : 'Add payment'),
            ),
      body: PageListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DropdownButton<int>(
                value: _year,
                items: [
                  for (final y in years)
                    DropdownMenuItem(value: y, child: Text('$y')),
                ],
                onChanged: (y) => setState(() => _year = y ?? _year),
              ),
              SegmentedButton<_View>(
                segments: [
                  ButtonSegment(
                    value: _View.sessions,
                    label: Text('Sessions (${toBill.length + billed.length})'),
                  ),
                  ButtonSegment(
                    value: _View.payments,
                    label: Text('Payments (${payments.length})'),
                  ),
                  ButtonSegment(
                    value: _View.expenses,
                    label: Text('Expenses (${spent.length})'),
                  ),
                ],
                selected: {_view},
                showSelectedIcon: false,
                onSelectionChanged: (v) => setState(() => _view = v.first),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Card.outlined(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 32,
                    runSpacing: 12,
                    children: [
                      _Total(money(income), 'received in $_year'),
                      _Total(money(outgo), 'expenses'),
                      _Total(money(income - outgo), 'income less expenses'),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '${miles.toStringAsFixed(1)} miles driven · '
                    '${rateKnown ? money(deduction) : 'no IRS rate for $_year yet'}'
                    '${rateKnown ? ' mileage deduction at the IRS standard rate' : ''}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const StripeBanner(),
          const SizedBox(height: 12),
          if (_view == _View.sessions)
            _SessionsView(
              toBill: toBill,
              billed: billed,
              paid: paid,
              year: _year,
              onTap: (r) => editSessionBilling(
                context,
                ref,
                clientId: r.client.id,
                session: r.session,
              ),
              onSendBill: (r) => showSendBillDialog(
                context,
                clientId: r.client.id,
                session: r.session,
              ),
              onOpenClient: (r) => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ClientPage(clientId: r.client.id),
                ),
              ),
            )
          else if (_expenses)
            _ExpenseTable(
              expenses: spent,
              onTap: (e) => e.id.startsWith('stripefees:')
                  ? ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Stripe\'s fees for the month, added up from your '
                          'Stripe payments. They update on their own.',
                        ),
                      ),
                    )
                  : showDialog<void>(
                      context: context,
                      builder: (_) => _ExpenseDialog(existing: e),
                    ),
            )
          else
            _PaymentTable(payments: payments, onTap: _openPayment),
        ],
      ),
    );
  }
}

class _Total extends StatelessWidget {
  const _Total(this.value, this.label);
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: theme.textTheme.titleLarge),
        Text(label, style: theme.textTheme.bodySmall),
      ],
    );
  }
}

/// A table on wide windows; a list of rows on a phone.
class _LedgerTable extends StatelessWidget {
  const _LedgerTable({
    required this.headers,
    required this.rows,
    required this.empty,
  });

  final List<String> headers;

  /// Cells (the last is the amount), what a tap does, a button for the
  /// row (e.g. Send bill), and what tapping the name (the second cell)
  /// does instead, e.g. open the client.
  final List<
    ({
      List<String> cells,
      VoidCallback onTap,
      Widget? action,
      VoidCallback? onName,
    })
  >
  rows;
  final String empty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text(empty),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 640;
        if (!wide) {
          return Card.outlined(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (final (i, r) in rows.indexed) ...[
                  if (i > 0) const Divider(height: 1),
                  ListTile(
                    onTap: r.onTap,
                    title: Align(
                      alignment: Alignment.centerLeft,
                      child: _NameCell(
                        r.cells[1].isEmpty ? '—' : r.cells[1],
                        onTap: r.onName,
                      ),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          [
                            r.cells[0],
                            ...r.cells.sublist(2, r.cells.length - 1),
                          ].where((c) => c.isNotEmpty).join(' · '),
                        ),
                        ?r.action,
                      ],
                    ),
                    trailing: Text(
                      r.cells.last,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                ],
              ],
            ),
          );
        }
        TableRow row(List<String> cells, {bool header = false}) => TableRow(
          decoration: header
              ? BoxDecoration(color: scheme.surfaceContainerHigh)
              : null,
          children: [
            for (final (i, c) in cells.indexed)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Text(
                  c,
                  // The amount column, even with a button column after it.
                  textAlign: i == headers.length - 1
                      ? TextAlign.right
                      : TextAlign.left,
                  style: header ? theme.textTheme.labelLarge : null,
                ),
              ),
          ],
        );
        final actions = rows.any((r) => r.action != null);
        return Card.outlined(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: Table(
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            columnWidths: {
              0: const FixedColumnWidth(100),
              headers.length - 1: const FixedColumnWidth(120),
              if (actions) headers.length: const IntrinsicColumnWidth(),
            },
            border: TableBorder(
              horizontalInside: BorderSide(color: scheme.outlineVariant),
            ),
            children: [
              row([...headers, if (actions) ''], header: true),
              for (final r in rows)
                TableRow(
                  children: [
                    for (final (i, c) in r.cells.indexed)
                      TableRowInkWell(
                        onTap: r.onTap,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          child: i == 1 && r.onName != null
                              ? Align(
                                  alignment: Alignment.centerLeft,
                                  child: _NameCell(c, onTap: r.onName),
                                )
                              : Text(
                                  c,
                                  textAlign: i == r.cells.length - 1
                                      ? TextAlign.right
                                      : TextAlign.left,
                                ),
                        ),
                      ),
                    if (actions)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: r.action ?? const SizedBox.shrink(),
                      ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Sessions to bill and billed but not paid (any date), then those paid
/// in [year], each a table with its count and total. Tap one to change
/// its billing.
class _SessionsView extends StatelessWidget {
  const _SessionsView({
    required this.toBill,
    required this.billed,
    required this.paid,
    required this.year,
    required this.onTap,
    required this.onSendBill,
    required this.onOpenClient,
  });

  final List<SessionRow> toBill;
  final List<SessionRow> billed;
  final List<SessionRow> paid;
  final int year;
  final void Function(SessionRow r) onTap;
  final void Function(SessionRow r) onSendBill;
  final void Function(SessionRow r) onOpenClient;

  /// "3 · $750" (and how many have no amount yet).
  static String _sum(List<SessionRow> rows) {
    final total = rows.fold<double>(0, (s, r) => s + (r.amount ?? 0));
    final unknown = rows.where((r) => r.amount == null).length;
    return [
      '${rows.length} · ${money(total)}',
      if (unknown > 0) '$unknown without an amount',
    ].join(' · ');
  }

  static String _when(SessionRow r) => switch (r.session.state) {
    ClientJobState.upcoming => 'Upcoming',
    ClientJobState.inProgress => 'In progress',
    ClientJobState.completed => 'Done',
  };

  static String _details(SessionRow r) {
    final t = r.session.time;
    final b = r.billing;
    return [
      if (b.status == BillingStatus.paid) ...[
        if (b.method != null) b.method!.label,
        if (b.paidOn != null) 'paid ${formatShortDate(b.paidOn!)}',
      ] else ...[
        _when(r),
        if (t != null) formatHours(t),
        if (b.link != null)
          'Stripe link sent ${formatShortDate(b.link!.createdOn)}',
      ],
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget section(
      String title,
      List<SessionRow> rows,
      String empty, {
      required BillingStatus status,
    }) {
      final c = billingColors(status, theme.colorScheme);
      return Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: c.bg,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(color: c.fg),
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    _sum(rows),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _LedgerTable(
              headers: const ['Date', 'Client', 'Session', 'Amount'],
              empty: empty,
              rows: [
                for (final r in rows)
                  (
                    cells: [
                      formatShortDate(r.session.start),
                      r.client.name,
                      _details(r),
                      r.amount == null ? '—' : money(r.amount!),
                    ],
                    onTap: () => onTap(r),
                    onName: () => onOpenClient(r),
                    action: r.status == BillingStatus.paid
                        ? null
                        : TextButton.icon(
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                            icon: const Icon(Icons.send_outlined, size: 18),
                            label: Text(
                              r.status == BillingStatus.billed
                                  ? 'Resend'
                                  : 'Send bill',
                            ),
                            onPressed: () => onSendBill(r),
                          ),
                  ),
              ],
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        section(
          'Need to bill',
          toBill,
          'Nothing to bill. Every session is billed or paid.',
          status: BillingStatus.needToBill,
        ),
        section(
          'Billed, not paid',
          billed,
          'Nothing waiting on payment.',
          status: BillingStatus.billed,
        ),
        section(
          'Paid in $year',
          paid,
          'No sessions paid in $year yet.',
          status: BillingStatus.paid,
        ),
      ],
    );
  }
}

/// A name that opens something (e.g. the client's page) when tapped.
class _NameCell extends StatelessWidget {
  const _NameCell(this.name, {this.onTap});

  final String name;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    if (onTap == null) return Text(name);
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Text(
        name,
        style: TextStyle(
          color: scheme.primary,
          decoration: TextDecoration.underline,
          decorationColor: scheme.primary.withValues(alpha: 0.5),
        ),
      ),
    );
  }
}

class _PaymentTable extends StatelessWidget {
  const _PaymentTable({required this.payments, required this.onTap});

  final List<LedgerPayment> payments;
  final void Function(LedgerPayment p) onTap;

  @override
  Widget build(BuildContext context) => _LedgerTable(
    headers: const ['Date', 'From', 'For', 'Source', 'Method', 'Amount'],
    empty:
        'No payments this year. Sessions marked paid on a client\'s page, '
        'paid Dunn Club sign-ups, and payments you add show up here.',
    rows: [
      for (final p in payments)
        (
          cells: [
            formatShortDate(p.date),
            p.from,
            p.description,
            p.source.label,
            p.method?.label ?? '',
            money(p.amount),
          ],
          onTap: () => onTap(p),
          action: null,
          onName: null,
        ),
    ],
  );
}

class _ExpenseTable extends StatelessWidget {
  const _ExpenseTable({required this.expenses, required this.onTap});

  final List<Expense> expenses;
  final void Function(Expense e) onTap;

  @override
  Widget build(BuildContext context) => _LedgerTable(
    headers: const ['Date', 'Paid to', 'Category', 'Paid with', 'Amount'],
    empty: 'No expenses this year. Add business expenses as they happen.',
    rows: [
      for (final e in expenses)
        (
          cells: [
            formatShortDate(e.date),
            e.vendor,
            e.category.label,
            e.method,
            money(e.amount),
          ],
          onTap: () => onTap(e),
          action: null,
          onName: null,
        ),
    ],
  );
}

Future<bool> _confirmDelete(BuildContext context, String what) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete this $what?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    ) ??
    false;

/// Add or edit a payment that isn't from a session or the Dunn Club.
class _PaymentDialog extends ConsumerStatefulWidget {
  const _PaymentDialog({this.existing});

  final ManualPayment? existing;

  @override
  ConsumerState<_PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends ConsumerState<_PaymentDialog> {
  late final _from = TextEditingController(text: widget.existing?.from ?? '');
  late final _for = TextEditingController(
    text: widget.existing?.description ?? '',
  );
  late final _notes = TextEditingController(text: widget.existing?.notes ?? '');
  late PaymentDetails _paid = (
    method: widget.existing?.method,
    date: widget.existing?.date ?? _today(ref),
    amount: widget.existing?.amount,
  );

  @override
  void dispose() {
    _from.dispose();
    _for.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final d = _paid.date;
    await ref
        .read(manualPaymentRecordsProvider.notifier)
        .save(
          ManualPayment(
            id: widget.existing?.id ?? _uuid.v4(),
            date: DateTime(d.year, d.month, d.day),
            amount: _paid.amount!,
            from: _from.text.trim(),
            description: _for.text.trim(),
            method: _paid.method,
            notes: _notes.text.trim(),
          ),
        );
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    if (!await _confirmDelete(context, 'payment')) return;
    await ref
        .read(manualPaymentRecordsProvider.notifier)
        .remove(widget.existing!.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Text(widget.existing == null ? 'Add a payment' : 'Payment'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _from,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Received from'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _for,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'For',
                  hintText: 'e.g. Speaking fee, gift card',
                ),
              ),
              const SizedBox(height: 16),
              PaymentFields(
                initial: _paid,
                onChanged: (p) => setState(() => _paid = p),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _notes,
                decoration: const InputDecoration(
                  labelText: 'Notes (optional)',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (widget.existing != null)
          TextButton(onPressed: _delete, child: const Text('Delete')),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _paid.amount == null ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Add or edit a business expense.
class _ExpenseDialog extends ConsumerStatefulWidget {
  const _ExpenseDialog({this.existing});

  final Expense? existing;

  @override
  ConsumerState<_ExpenseDialog> createState() => _ExpenseDialogState();
}

class _ExpenseDialogState extends ConsumerState<_ExpenseDialog> {
  late final _vendor = TextEditingController(
    text: widget.existing?.vendor ?? '',
  );
  late final _amount = TextEditingController(
    text: amountText(widget.existing?.amount),
  );
  late final _method = TextEditingController(
    text: widget.existing?.method ?? '',
  );
  late final _notes = TextEditingController(text: widget.existing?.notes ?? '');
  late ExpenseCategory _category =
      widget.existing?.category ?? ExpenseCategory.supplies;
  late DateTime _date = widget.existing?.date ?? _today(ref);

  @override
  void dispose() {
    _vendor.dispose();
    _amount.dispose();
    _method.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(_date.year + 5),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _save() async {
    await ref
        .read(expenseRecordsProvider.notifier)
        .save(
          Expense(
            id: widget.existing?.id ?? _uuid.v4(),
            date: DateTime(_date.year, _date.month, _date.day),
            amount: parseAmount(_amount.text)!,
            category: _category,
            vendor: _vendor.text.trim(),
            method: _method.text.trim(),
            notes: _notes.text.trim(),
          ),
        );
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    if (!await _confirmDelete(context, 'expense')) return;
    await ref.read(expenseRecordsProvider.notifier).remove(widget.existing!.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final ready = parseAmount(_amount.text) != null;
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Text(widget.existing == null ? 'Add an expense' : 'Expense'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _vendor,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Paid to',
                  hintText: 'e.g. The Container Store, Canva',
                ),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<ExpenseCategory>(
                initialValue: _category,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Category'),
                items: [
                  for (final c in ExpenseCategory.values)
                    DropdownMenuItem(value: c, child: Text(c.label)),
                ],
                onChanged: (c) => setState(() => _category = c ?? _category),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: _pickDate,
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Date',
                          prefixIcon: Icon(Icons.calendar_today_outlined),
                        ),
                        child: Text(formatShortDate(_date)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _amount,
                      autofocus: widget.existing == null,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.,$]')),
                      ],
                      decoration: const InputDecoration(
                        labelText: 'Amount',
                        prefixText: '\$ ',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _method,
                decoration: const InputDecoration(
                  labelText: 'Paid with (optional)',
                  hintText: 'e.g. Business card, cash',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _notes,
                decoration: const InputDecoration(
                  labelText: 'Notes (optional)',
                  hintText: 'What it was for',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (widget.existing != null)
          TextButton(onPressed: _delete, child: const Text('Delete')),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: ready ? _save : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
