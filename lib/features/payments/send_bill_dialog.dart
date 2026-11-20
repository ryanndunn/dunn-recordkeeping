import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/saved_address.dart';
import '../../services/client_jobs.dart';
import '../../services/stripe.dart';
import '../../state/providers.dart';
import '../../state/stripe_provider.dart';
import '../../widgets/payment_fields.dart' show parseAmount, amountText;
import '../clients/client_page.dart' show openClientLink;
import '../clients/client_status.dart';

/// Where the payment link goes in a bill's message until it's made.
const linkToken = '[payment link]';

/// Asks who to bill for [session] and how (text, email or copy), with a
/// Stripe payment link when Stripe is connected, then opens the message
/// ready to send and marks the session billed.
Future<void> showSendBillDialog(
  BuildContext context, {
  required String clientId,
  required ClientJobEntry session,
}) => showDialog<void>(
  context: context,
  builder: (_) => _SendBillDialog(clientId: clientId, session: session),
);

enum BillVia {
  text('Text'),
  email('Email'),
  copy('Copy');

  const BillVia(this.label);
  final String label;
}

/// Who a bill goes to by default: a contact labelled as paying (with a
/// phone or email), else the client, else anyone reachable.
ClientContact billRecipient(SavedAddress client) {
  final people = [client.primaryContact, ...client.contacts];
  bool reachable(ClientContact p) => p.phone.isNotEmpty || p.email.isNotEmpty;
  return people
          .where((p) => reachable(p) && p.label.toLowerCase().contains('pay'))
          .firstOrNull ??
      (reachable(client.primaryContact) ? client.primaryContact : null) ??
      people.where(reachable).firstOrNull ??
      client.primaryContact;
}

/// The bill's message: amount, session day, and (with Stripe) where to
/// pay ([link], or [linkToken] until the link is made).
String billMessage({
  required String name,
  required ClientJobEntry session,
  required double? amount,
  String? link,
}) {
  final first = name.trim().split(RegExp(r'\s+')).first;
  final d = session.scheduled?.start ?? session.start;
  final hi = first.isEmpty ? 'Hi' : 'Hi $first';
  final total = amount == null ? '' : ' (${formatDollars(amount)})';
  if (link == null) {
    return '$hi, here\'s the bill for your organizing session on '
        '${formatShortDate(d)}$total. Thank you!';
  }
  return '$hi, here\'s the bill for your organizing session on '
      '${formatShortDate(d)}$total. You can pay here: $link';
}

class _SendBillDialog extends ConsumerStatefulWidget {
  const _SendBillDialog({required this.clientId, required this.session});

  final String clientId;
  final ClientJobEntry session;

  @override
  ConsumerState<_SendBillDialog> createState() => _SendBillDialogState();
}

class _SendBillDialogState extends ConsumerState<_SendBillDialog> {
  final _amount = TextEditingController();
  final _message = TextEditingController();
  late ClientContact _to;
  BillVia _via = BillVia.text;

  /// The message was typed in, so it's no longer rewritten.
  bool _edited = false;
  bool _busy = false;
  String? _error;

  SavedAddress? get _client => ref
      .read(addressesProvider)
      .where((c) => c.id == widget.clientId)
      .firstOrNull;

  @override
  void initState() {
    super.initState();
    final client = _client!;
    final billing = billingFor(client, widget.session);
    _amount.text = amountText(
      billing.link?.amount ?? sessionAmount(client, widget.session),
    );
    _to = billRecipient(client);
    _via = _to.phone.isNotEmpty
        ? BillVia.text
        : _to.email.isNotEmpty
        ? BillVia.email
        : BillVia.copy;
    _rewrite();
  }

  @override
  void dispose() {
    _amount.dispose();
    _message.dispose();
    super.dispose();
  }

  bool get _stripe => ref.read(stripeKeyProvider) != null;

  /// The link the bill will carry, as it is now (null: not made yet, or
  /// no Stripe).
  String? _currentLink() {
    final link = billingFor(_client!, widget.session).link;
    if (link == null || _linkNeedsReplacing()) return null;
    return withPrefilledEmail(link.url, _to.email);
  }

  bool _linkNeedsReplacing() {
    final link = billingFor(_client!, widget.session).link;
    final amount = parseAmount(_amount.text);
    return link != null &&
        amount != null &&
        (amount - link.amount).abs() >= 0.005;
  }

  void _rewrite() {
    if (_edited) return;
    _message.text = billMessage(
      name: _to.name,
      session: widget.session,
      amount: parseAmount(_amount.text),
      link: _stripe ? (_currentLink() ?? linkToken) : null,
    );
  }

  Future<void> _send() async {
    final client = _client;
    if (client == null) return;
    final amount = parseAmount(_amount.text);
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Enter the amount.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final stripe = ref.read(stripeProvider.notifier);
    var text = _message.text;
    String? url;
    if (_stripe) {
      // Make the link (or a new one if the amount changed).
      if (_linkNeedsReplacing()) {
        final error = await stripe.turnOffLink(client.id, widget.session);
        if (error != null) return _fail(error);
      }
      if (billingFor(_client!, widget.session).link == null) {
        final error = await stripe.createLink(
          client.id,
          widget.session,
          amount: amount,
          name: paymentLinkName(widget.session),
        );
        if (error != null) return _fail(error);
      }
      url = withPrefilledEmail(
        billingFor(_client!, widget.session).link!.url,
        _to.email,
      );
      text = text.contains(linkToken)
          ? text.replaceAll(linkToken, url)
          : text.contains(url)
          ? text
          : '$text\n$url';
    } else {
      // No Stripe: just mark it billed.
      final now = _client!;
      final billing = billingFor(now, widget.session);
      if (billing.status == BillingStatus.needToBill) {
        await ref
            .read(addressesProvider.notifier)
            .replace(
              withBilling(
                now,
                widget.session,
                const SessionBilling(status: BillingStatus.billed),
              ),
            );
      }
    }
    if (!mounted) return;
    final date = formatShortDate(
      widget.session.scheduled?.start ?? widget.session.start,
    );
    switch (_via) {
      case BillVia.text:
        await openClientLink(
          context,
          Uri.parse('sms:${_to.phone}?body=${Uri.encodeComponent(text)}'),
        );
      case BillVia.email:
        await openClientLink(
          context,
          Uri.parse(
            'mailto:${_to.email}'
            '?subject=${Uri.encodeComponent('Bill for your organizing session on $date')}'
            '&body=${Uri.encodeComponent(text)}',
          ),
        );
      case BillVia.copy:
        await Clipboard.setData(ClipboardData(text: text));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Bill copied. Paste it to send.')),
          );
        }
    }
    if (mounted) Navigator.pop(context);
  }

  void _fail(String error) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  Future<void> _turnOff() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await ref
        .read(stripeProvider.notifier)
        .turnOffLink(widget.clientId, widget.session);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
      _rewrite();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final client = ref
        .watch(addressesProvider)
        .where((c) => c.id == widget.clientId)
        .firstOrNull;
    final stripe = ref.watch(stripeKeyProvider) != null;
    if (client == null) return const SizedBox.shrink();
    final billing = billingFor(client, widget.session);
    final link = billing.link;
    final date = formatShortDate(
      widget.session.scheduled?.start ?? widget.session.start,
    );
    if (billing.status == BillingStatus.paid) {
      return AlertDialog(
        title: Text('${client.name} · $date'),
        content: Text(
          'Already paid'
          '${billing.method == null ? '' : ' (${billing.method!.label})'}.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      );
    }
    final people = [client.primaryContact, ...client.contacts];
    final replacing = _linkNeedsReplacing();

    return AlertDialog(
      title: Text('Send bill · ${client.name} · $date'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _amount,
                enabled: !_busy,
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
                onChanged: (_) => setState(_rewrite),
              ),
              const SizedBox(height: 4),
              Text(
                !stripe
                    ? 'Connect Stripe in Settings to include a payment link '
                          'that marks the session paid by itself.'
                    : link == null
                    ? 'A Stripe payment link (card, Affirm or Klarna) is '
                          'made when you send. When it\'s paid, the session '
                          'is marked paid by itself.'
                    : replacing
                    ? 'A new link for this amount replaces the '
                          '${formatDollars(link.amount)} one sent '
                          '${formatShortDate(link.createdOn)}.'
                    : 'Uses the payment link made '
                          '${formatShortDate(link.createdOn)}. When it\'s '
                          'paid, the session is marked paid by itself.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              Text('To', style: theme.textTheme.titleSmall),
              RadioGroup<String>(
                groupValue: _to.id,
                onChanged: (id) => setState(() {
                  _to = people.firstWhere((p) => p.id == id);
                  if (_via == BillVia.text && _to.phone.isEmpty ||
                      _via == BillVia.email && _to.email.isEmpty) {
                    _via = _to.phone.isNotEmpty
                        ? BillVia.text
                        : _to.email.isNotEmpty
                        ? BillVia.email
                        : BillVia.copy;
                  }
                  _rewrite();
                }),
                child: Column(
                  children: [
                    for (final p in people)
                      RadioListTile<String>(
                        value: p.id,
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          [
                            p.name.isEmpty ? p.email : p.name,
                            if (p.label.isNotEmpty) '(${p.label})',
                          ].join(' '),
                        ),
                        subtitle: Text(
                          [p.phone, p.email]
                              .where((x) => x.isNotEmpty)
                              .join(' · ')
                              .ifEmpty('No phone or email'),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              SegmentedButton<BillVia>(
                segments: [
                  ButtonSegment(
                    value: BillVia.text,
                    label: const Text('Text'),
                    icon: const Icon(Icons.sms_outlined),
                    enabled: _to.phone.isNotEmpty,
                  ),
                  ButtonSegment(
                    value: BillVia.email,
                    label: const Text('Email'),
                    icon: const Icon(Icons.email_outlined),
                    enabled: _to.email.isNotEmpty,
                  ),
                  const ButtonSegment(
                    value: BillVia.copy,
                    label: Text('Copy'),
                    icon: Icon(Icons.copy),
                  ),
                ],
                selected: {_via},
                showSelectedIcon: false,
                onSelectionChanged: (v) => setState(() => _via = v.first),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _message,
                enabled: !_busy,
                minLines: 3,
                maxLines: 6,
                decoration: InputDecoration(
                  labelText: 'Message',
                  helperText: stripe && _message.text.contains(linkToken)
                      ? '$linkToken is replaced by the link when you send.'
                      : null,
                  helperMaxLines: 2,
                ),
                onChanged: (_) => _edited = true,
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (link != null)
          TextButton(
            onPressed: _busy ? null : _turnOff,
            child: const Text('Turn off link'),
          ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : _send,
          icon: _busy
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(switch (_via) {
                  BillVia.text => Icons.sms_outlined,
                  BillVia.email => Icons.email_outlined,
                  BillVia.copy => Icons.copy,
                }),
          label: Text(_via == BillVia.copy ? 'Copy bill' : 'Send'),
        ),
      ],
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
