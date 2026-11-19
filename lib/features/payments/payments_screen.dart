import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';

import '../../models/money.dart';
import '../../services/ledger.dart';
import '../../state/money_provider.dart';
import '../../state/providers.dart';
import '../../widgets/page_body.dart';
import '../../widgets/payment_fields.dart';
import '../clients/client_page.dart';
import '../clients/client_status.dart';

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

class _PaymentsScreenState extends ConsumerState<PaymentsScreen> {
  late int _year = ref.read(clockProvider)().year;
  bool _expenses = false;

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
        final regId = p.id.substring('club:'.length);
        final reg = ref
            .read(clubRegistrationsProvider)
            .where((r) => r.id == regId)
            .firstOrNull;
        if (reg != null) await showClubDialog(context, reg);
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
    final expenses = ref.watch(expensesProvider);
    final trips = ref.watch(tripsProvider);
    final toConfirm = ref.watch(clubToConfirmProvider);
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
      appBar: AppBar(title: const Text('Payments')),
      floatingActionButton: FloatingActionButton.extended(
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
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(
                    value: false,
                    label: Text('Payments (${payments.length})'),
                  ),
                  ButtonSegment(
                    value: true,
                    label: Text('Expenses (${spent.length})'),
                  ),
                ],
                selected: {_expenses},
                showSelectedIcon: false,
                onSelectionChanged: (v) => setState(() => _expenses = v.first),
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
          if (toConfirm.isNotEmpty) ...[
            const SizedBox(height: 12),
            Card.filled(
              margin: EdgeInsets.zero,
              color: theme.colorScheme.tertiaryContainer,
              child: ListTile(
                leading: Icon(
                  Icons.groups_outlined,
                  color: theme.colorScheme.onTertiaryContainer,
                ),
                title: Text(
                  toConfirm.length == 1
                      ? '1 Dunn Club sign-up to confirm'
                      : '${toConfirm.length} Dunn Club sign-ups to confirm',
                  style: TextStyle(
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                ),
                subtitle: Text(
                  'After their free first meeting, it\'s '
                  '${money(clubPrice)} a meeting. Mark each paid or not.',
                  style: TextStyle(
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openClub(context),
              ),
            ),
          ] else
            Align(
              alignment: Alignment.centerLeft,
              child: ref.watch(clubRegistrationsProvider).isNotEmpty
                  ? TextButton.icon(
                      onPressed: () => _openClub(context),
                      icon: const Icon(Icons.groups_outlined),
                      label: const Text('Dunn Club sign-ups'),
                    )
                  : TextButton.icon(
                      onPressed: () => _howToLinkClub(context),
                      icon: const Icon(Icons.help_outline),
                      label: const Text('Add Dunn Club sign-ups'),
                    ),
            ),
          const SizedBox(height: 12),
          if (_expenses)
            _ExpenseTable(
              expenses: spent,
              onTap: (e) => showDialog<void>(
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

  Future<void> _howToLinkClub(BuildContext context) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Dunn Club sign-ups'),
      content: const SizedBox(
        width: 440,
        child: Text(
          'Link the Let\'s Get This Dunn Club form to the app\'s spreadsheet '
          'once:\n\n'
          '1. Open the form in Google Forms and go to the Responses tab.\n'
          '2. Choose "Link to Sheets", then "Select existing spreadsheet".\n'
          '3. Pick "Dunn Record Keeping - Business Records".\n\n'
          'After the next sync, each sign-up shows here (first meeting '
          'free, then \$20 to confirm) and in Leads.',
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('OK'),
        ),
      ],
    ),
  );

  void _openClub(BuildContext context) => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => const ClubSignupsPage()));
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

  /// Cells (the last is the amount) and what a tap does.
  final List<({List<String> cells, VoidCallback onTap})> rows;
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
                    title: Text(r.cells[1].isEmpty ? '—' : r.cells[1]),
                    subtitle: Text(
                      [
                        r.cells[0],
                        ...r.cells.sublist(2, r.cells.length - 1),
                      ].where((c) => c.isNotEmpty).join(' · '),
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
                  textAlign: i == cells.length - 1
                      ? TextAlign.right
                      : TextAlign.left,
                  style: header ? theme.textTheme.labelLarge : null,
                ),
              ),
          ],
        );
        return Card.outlined(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: Table(
            columnWidths: {
              0: const FixedColumnWidth(100),
              headers.length - 1: const FixedColumnWidth(120),
            },
            border: TableBorder(
              horizontalInside: BorderSide(color: scheme.outlineVariant),
            ),
            children: [
              row(headers, header: true),
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
                          child: Text(
                            c,
                            textAlign: i == r.cells.length - 1
                                ? TextAlign.right
                                : TextAlign.left,
                          ),
                        ),
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

// --------------------------------------------------------- Dunn Club

/// Everyone who signed up for Let's Get This Dunn Club: those to confirm
/// first, then the rest, newest first. Tap one to change it.
class ClubSignupsPage extends ConsumerWidget {
  const ClubSignupsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final regs = ref.watch(clubRegistrationsProvider);
    final decisions = ref.watch(clubDecisionsProvider);
    final theme = Theme.of(context);
    final sorted = [...regs]
      ..sort((a, b) {
        final ca = clubStatusOf(a, regs, decisions) == ClubStatus.toConfirm;
        final cb = clubStatusOf(b, regs, decisions) == ClubStatus.toConfirm;
        if (ca != cb) return ca ? -1 : 1;
        return b.at.compareTo(a.at);
      });
    return Scaffold(
      appBar: AppBar(title: const Text('Dunn Club sign-ups')),
      body: PageListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Each response to the Dunn Club form. Someone\'s first '
              'meeting is free; after that it\'s ${money(clubPrice)}. Paid '
              'ones go in Payments (and the spreadsheet) for taxes.',
            ),
          ),
          for (final r in sorted)
            Builder(
              builder: (context) {
                final status = clubStatusOf(r, regs, decisions);
                final d = decisions[r.id];
                final colors = switch (status) {
                  ClubStatus.toConfirm => (
                    theme.colorScheme.errorContainer,
                    theme.colorScheme.onErrorContainer,
                  ),
                  ClubStatus.paid => (
                    theme.colorScheme.primaryContainer,
                    theme.colorScheme.onPrimaryContainer,
                  ),
                  _ => (
                    theme.colorScheme.surfaceContainerHighest,
                    theme.colorScheme.onSurfaceVariant,
                  ),
                };
                return ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(r.name.isEmpty ? r.email : r.name),
                  subtitle: Text(
                    [
                      if (r.name.isNotEmpty) r.email,
                      'Signed up ${formatShortDate(r.at)}',
                      if (status == ClubStatus.paid && d != null)
                        '${money(d.amount ?? clubPrice)}'
                            '${d.method == null ? '' : ' · ${d.method!.label}'}',
                    ].join(' · '),
                  ),
                  trailing: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: colors.$1,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      status.label,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: colors.$2,
                      ),
                    ),
                  ),
                  onTap: () => showClubDialog(context, r),
                );
              },
            ),
        ],
      ),
    );
  }
}

/// Mark a Dunn Club sign-up paid (how, when, how much), not paid, or free.
Future<void> showClubDialog(BuildContext context, ClubRegistration reg) =>
    showDialog<void>(
      context: context,
      builder: (_) => _ClubDialog(reg: reg),
    );

class _ClubDialog extends ConsumerStatefulWidget {
  const _ClubDialog({required this.reg});
  final ClubRegistration reg;

  @override
  ConsumerState<_ClubDialog> createState() => _ClubDialogState();
}

class _ClubDialogState extends ConsumerState<_ClubDialog> {
  late final ClubDecision? _existing = ref.read(
    clubDecisionsProvider,
  )[widget.reg.id];
  late ClubStatus _status = () {
    final s = clubStatusOf(
      widget.reg,
      ref.read(clubRegistrationsProvider),
      ref.read(clubDecisionsProvider),
    );
    return s == ClubStatus.toConfirm ? ClubStatus.paid : s;
  }();
  late PaymentDetails _paid = (
    method: _existing?.method,
    date:
        _existing?.paidOn ??
        DateTime(widget.reg.at.year, widget.reg.at.month, widget.reg.at.day),
    amount: _existing?.amount ?? clubPrice,
  );

  bool get _ready =>
      _status != ClubStatus.paid ||
      (_paid.method != null && _paid.amount != null);

  Future<void> _save() async {
    final d = _paid.date;
    await ref
        .read(clubDecisionRecordsProvider.notifier)
        .decide(
          widget.reg.id,
          _status == ClubStatus.paid
              ? ClubDecision(
                  ClubStatus.paid,
                  method: _paid.method,
                  paidOn: DateTime(d.year, d.month, d.day),
                  amount: _paid.amount,
                )
              : ClubDecision(_status),
        );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.reg;
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Text(r.name.isEmpty ? r.email : r.name),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Signed up ${formatShortDate(r.at)} · ${r.email}'),
              const SizedBox(height: 12),
              SegmentedButton<ClubStatus>(
                segments: const [
                  ButtonSegment(value: ClubStatus.paid, label: Text('Paid')),
                  ButtonSegment(
                    value: ClubStatus.unpaid,
                    label: Text('Not paid'),
                  ),
                  ButtonSegment(value: ClubStatus.free, label: Text('Free')),
                ],
                selected: {_status},
                showSelectedIcon: false,
                onSelectionChanged: (v) => setState(() => _status = v.first),
              ),
              if (_status == ClubStatus.paid) ...[
                const SizedBox(height: 16),
                PaymentFields(
                  initial: _paid,
                  onChanged: (p) => setState(() => _paid = p),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _ready ? _save : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
