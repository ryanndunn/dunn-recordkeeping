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

/// Makes (or shows) [session]'s Stripe payment link, to copy, text or
/// email to the client or one of their contacts.
Future<void> showPaymentLinkDialog(
  BuildContext context, {
  required String clientId,
  required ClientJobEntry session,
}) => showDialog<void>(
  context: context,
  builder: (_) => _PaymentLinkDialog(clientId: clientId, session: session),
);

/// "Hi Jane, here's the payment link for your organizing session on
/// 11/20/26 ($300): …".
String paymentLinkMessage({
  required String name,
  required ClientJobEntry session,
  required double amount,
  required String url,
}) {
  final first = name.trim().split(RegExp(r'\s+')).first;
  final d = session.scheduled?.start ?? session.start;
  return '${first.isEmpty ? 'Hi' : 'Hi $first'}, here\'s the payment link '
      'for your organizing session on ${formatShortDate(d)} '
      '(${formatDollars(amount)}): $url';
}

class _PaymentLinkDialog extends ConsumerStatefulWidget {
  const _PaymentLinkDialog({required this.clientId, required this.session});

  final String clientId;
  final ClientJobEntry session;

  @override
  ConsumerState<_PaymentLinkDialog> createState() => _PaymentLinkDialogState();
}

class _PaymentLinkDialogState extends ConsumerState<_PaymentLinkDialog> {
  late final _amount = TextEditingController();
  late final _name = TextEditingController(
    text: paymentLinkName(widget.session),
  );
  bool _busy = false;
  bool _copied = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final client = _client();
    if (client != null) {
      _amount.text = amountText(sessionAmount(client, widget.session));
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _name.dispose();
    super.dispose();
  }

  SavedAddress? _client() => ref
      .read(addressesProvider)
      .where((c) => c.id == widget.clientId)
      .firstOrNull;

  Future<void> _create() async {
    final amount = parseAmount(_amount.text);
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Enter the amount.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await ref
        .read(stripeProvider.notifier)
        .createLink(
          widget.clientId,
          widget.session,
          amount: amount,
          name: _name.text.trim().isEmpty
              ? paymentLinkName(widget.session)
              : _name.text.trim(),
        );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  Future<void> _turnOff() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Turn off this link?'),
        content: const Text(
          'Nobody will be able to pay with it. You can make a new one '
          'afterwards, for example if the session changed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Turn off'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
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
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final client = ref
        .watch(addressesProvider)
        .where((c) => c.id == widget.clientId)
        .firstOrNull;
    final connected = ref.watch(stripeKeyProvider) != null;
    if (client == null) return const SizedBox.shrink();
    final billing = billingFor(client, widget.session);
    final link = billing.link;
    final date = formatShortDate(
      widget.session.scheduled?.start ?? widget.session.start,
    );

    Widget body;
    List<Widget> actions;
    // A link already made can still be copied or sent without Stripe here.
    if (!connected && (link == null || billing.status == BillingStatus.paid)) {
      body = const Text(
        'Connect Stripe in Settings to make payment links from the app.',
      );
      actions = [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('OK'),
        ),
      ];
    } else if (billing.status == BillingStatus.paid) {
      body = Text(
        'This session is already paid'
        '${billing.method == null ? '' : ' (${billing.method!.label})'}.',
      );
      actions = [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('OK'),
        ),
      ];
    } else if (link == null) {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'A link ${client.name} (or whoever pays) can pay once, by card, '
            'Affirm or Klarna. When it\'s paid, this session is marked paid '
            'on its own.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _amount,
            enabled: !_busy,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.,$]')),
            ],
            decoration: const InputDecoration(
              labelText: 'Amount',
              prefixText: '\$ ',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _name,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: 'What they\'ll see at checkout',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
        ],
      );
      actions = [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _create,
          child: _busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Make link'),
        ),
      ];
    } else {
      final now = sessionAmount(client, widget.session);
      final changed = now != null && (now - link.amount).abs() >= 0.005;
      final people = [client.primaryContact, ...client.contacts];
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${formatDollars(link.amount)} · made '
            '${formatShortDate(link.createdOn)} · paid once, then it turns '
            'itself off',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          SelectableText(link.url),
          if (changed) ...[
            const SizedBox(height: 8),
            Text(
              'The session now bills ${formatDollars(now)}. Turn this link '
              'off and make a new one.',
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: Icon(_copied ? Icons.check : Icons.copy),
              label: Text(_copied ? 'Copied' : 'Copy link'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: link.url));
                if (mounted) setState(() => _copied = true);
              },
            ),
          ),
          const Divider(),
          Text('Send it to', style: theme.textTheme.titleSmall),
          for (final p in people)
            if (p.phone.isNotEmpty || p.email.isNotEmpty)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(p.name.isEmpty ? p.email : p.name),
                subtitle: p.label.isEmpty ? null : Text(p.label),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (p.phone.isNotEmpty)
                      IconButton(
                        tooltip: 'Text ${p.name}',
                        icon: const Icon(Icons.sms_outlined),
                        onPressed: () => openClientLink(
                          context,
                          Uri.parse(
                            'sms:${p.phone}?body=${Uri.encodeComponent(paymentLinkMessage(name: p.name, session: widget.session, amount: link.amount, url: withPrefilledEmail(link.url, p.email)))}',
                          ),
                        ),
                      ),
                    if (p.email.isNotEmpty)
                      IconButton(
                        tooltip: 'Email ${p.name}',
                        icon: const Icon(Icons.email_outlined),
                        onPressed: () => openClientLink(
                          context,
                          Uri.parse(
                            'mailto:${p.email}'
                            '?subject=${Uri.encodeComponent('Payment link for your session on $date')}'
                            '&body=${Uri.encodeComponent(paymentLinkMessage(name: p.name, session: widget.session, amount: link.amount, url: withPrefilledEmail(link.url, p.email)))}',
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          if (people.every((p) => p.phone.isEmpty && p.email.isEmpty))
            const Text(
              'Add a phone number or email to their contacts to send it from '
              'here, or copy the link.',
            ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
        ],
      );
      actions = [
        TextButton(
          onPressed: _busy ? null : _turnOff,
          child: const Text('Turn off link'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ];
    }

    return AlertDialog(
      title: Text('Payment link · session $date'),
      content: SizedBox(width: 460, child: SingleChildScrollView(child: body)),
      actions: actions,
    );
  }
}
