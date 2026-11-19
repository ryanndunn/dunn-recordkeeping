import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../models/billing.dart';

/// How, when and how much someone paid.
typedef PaymentDetails = ({
  PaymentMethod? method,
  DateTime date,
  double? amount,
});

String _two(int n) => n.toString().padLeft(2, '0');
String _short(DateTime d) =>
    '${_two(d.month)}/${_two(d.day)}/${_two(d.year % 100)}';

/// The amount as typed ("225", "$82.50"); null if it isn't an amount.
double? parseAmount(String text) {
  final v = double.tryParse(text.replaceAll(RegExp(r'[\s$,]'), ''));
  return v == null || v < 0 ? null : v;
}

String amountText(double? a) => a == null
    ? ''
    : a == a.roundToDouble()
    ? a.toStringAsFixed(0)
    : a.toStringAsFixed(2);

/// Payment method (check, cash, Venmo, Zelle, or Stripe card/Affirm/
/// Klarna), the day it was paid, and the amount. Reports every change.
class PaymentFields extends StatefulWidget {
  const PaymentFields({
    super.key,
    required this.initial,
    required this.onChanged,
    this.lastDate,
  });

  final PaymentDetails initial;
  final ValueChanged<PaymentDetails> onChanged;

  /// Latest day that can be picked (default: no limit).
  final DateTime? lastDate;

  @override
  State<PaymentFields> createState() => _PaymentFieldsState();
}

class _PaymentFieldsState extends State<PaymentFields> {
  late PaymentMethod? _method = widget.initial.method;
  late DateTime _date = widget.initial.date;
  late final _amount = TextEditingController(
    text: amountText(widget.initial.amount),
  );

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  void _report() => widget.onChanged((
    method: _method,
    date: _date,
    amount: parseAmount(_amount.text),
  ));

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: widget.lastDate ?? DateTime(_date.year + 5),
    );
    if (picked == null) return;
    setState(() => _date = picked);
    _report();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget method(PaymentMethod m, String label) => ChoiceChip(
      label: Text(label),
      selected: _method == m,
      onSelected: (_) {
        setState(() => _method = m);
        _report();
      },
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Paid with', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final m in PaymentMethod.values)
              if (!m.isStripe) method(m, m.label),
          ],
        ),
        const SizedBox(height: 12),
        Text('Stripe', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            method(PaymentMethod.stripeCard, 'Card'),
            method(PaymentMethod.stripeAffirm, 'Affirm'),
            method(PaymentMethod.stripeKlarna, 'Klarna'),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: _pickDate,
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Paid on',
                    prefixIcon: Icon(Icons.calendar_today_outlined),
                  ),
                  child: Text(_short(_date)),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _amount,
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
                onChanged: (_) => _report(),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
