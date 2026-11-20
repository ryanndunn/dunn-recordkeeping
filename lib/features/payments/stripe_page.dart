import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/saved_address.dart';
import '../../services/client_jobs.dart';
import '../../services/people_match.dart';
import '../../services/stripe.dart';
import '../../state/money_provider.dart';
import '../../state/providers.dart';
import '../../state/stripe_provider.dart';
import '../../widgets/page_body.dart';
import '../clients/client_status.dart';

String _cents(double v) => '\$${v.toStringAsFixed(2)}';

void openStripePayments(BuildContext context) => Navigator.of(context)
    .push(MaterialPageRoute<void>(builder: (_) => const StripePaymentsPage()));

/// "Jane Smith · Session 11/18/26", or what the payment was decided to be.
String stripeStatus(
  StripeDecision? d,
  Map<String, SavedAddress> clients,
  StripePayment p,
) {
  if (p.fullyRefunded) return 'Refunded';
  if (d == null) return 'Needs a session';
  final client = clients[d.clientId];
  final who = client?.name ?? (d.clientId == null ? null : 'a deleted client');
  if (!d.forSession) {
    return who == null ? 'Not for a session' : 'Not for a session · $who';
  }
  final booked = client?.scheduled
      .where((s) => s.id == d.sessionKey)
      .firstOrNull;
  final session = booked == null
      ? 'a session'
      : 'Session ${formatShortDate(booked.start)}';
  return '$who · $session${d.automatic ? ' (matched)' : ''}';
}

/// Asks which session [payment] paid for (or that it isn't for one), then
/// records it.
Future<void> matchStripePayment(
  BuildContext context,
  WidgetRef ref,
  StripePayment payment,
) async {
  final clients = [...ref.read(addressesProvider)]
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  final guess = matchPerson(
    email: payment.email,
    name: payment.name,
    clients: clients,
  )?.client;
  final ordered = [
    ?guess,
    for (final c in clients)
      if (c.id != guess?.id) c,
  ];
  final clientId = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(
        '${payment.who} paid ${_cents(payment.net)} on '
        '${formatShortDate(payment.at.toLocal())}. Which client?',
      ),
      children: [
        for (final c in ordered)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, c.id),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(c.name),
              subtitle: c.id == guess?.id
                  ? const Text('Their email or name matches')
                  : null,
            ),
          ),
        const Divider(),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, ''),
          child: const Text('Not a client\'s session (other income)'),
        ),
      ],
    ),
  );
  if (clientId == null || !context.mounted) return;
  final stripe = ref.read(stripeProvider.notifier);
  if (clientId.isEmpty) {
    await stripe.notForSession(payment);
    return;
  }
  final client = clients.firstWhere((c) => c.id == clientId);
  final sessions = stripe.sessionsOf(clientId);
  final picked = await showDialog<Object>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text('Which of ${client.name}\'s sessions?'),
      children: [
        if (sessions.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              'No sessions yet. Schedule it on their page first, then '
              'match this payment.',
            ),
          ),
        for (final s in sessions) _sessionOption(context, client, s, payment),
        const Divider(),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, 'other'),
          child: Text('Not for a session (other income from ${client.name})'),
        ),
      ],
    ),
  );
  if (picked == null) return;
  if (picked is ClientJobEntry) {
    await stripe.link(payment, clientId, picked);
  } else {
    await stripe.notForSession(payment, clientId: clientId);
  }
}

Widget _sessionOption(
  BuildContext context,
  SavedAddress client,
  ClientJobEntry s,
  StripePayment payment,
) {
  final billing = billingFor(client, s);
  final amount = sessionAmount(client, s);
  final takenByOther =
      billing.stripeId != null && billing.stripeId != payment.id;
  return SimpleDialogOption(
    onPressed: takenByOther ? null : () => Navigator.pop(context, s),
    child: ListTile(
      enabled: !takenByOther,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        s.state == ClientJobState.upcoming
            ? Icons.event_outlined
            : Icons.event_available_outlined,
      ),
      title: Text(
        [
          formatShortDate(s.start),
          if (amount != null) formatDollars(amount),
        ].join(' · '),
      ),
      subtitle: Text(
        takenByOther
            ? 'Paid by another Stripe payment'
            : billing.stripeId == payment.id
            ? 'Paid by this payment'
            : billing.status.label,
      ),
    ),
  );
}

/// Everything about one Stripe payment, with a button to match it.
Future<void> showStripePayment(
  BuildContext context,
  WidgetRef ref,
  StripePayment p,
) => showDialog<void>(
  context: context,
  builder: (context) => Consumer(
    builder: (context, ref, _) {
      final d = ref.watch(stripeDecisionsProvider)[p.id];
      final clients = {for (final c in ref.watch(addressesProvider)) c.id: c};
      final theme = Theme.of(context);
      Widget row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 110,
              child: Text(label, style: theme.textTheme.bodySmall),
            ),
            Expanded(child: Text(value)),
          ],
        ),
      );
      return AlertDialog(
        title: Text('${p.who} · ${_cents(p.net)}'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              row('Paid', formatShortDate(p.at.toLocal())),
              row('With', p.method.label),
              if (p.email.isNotEmpty) row('Email', p.email),
              row('Charged', _cents(p.amount)),
              if (p.refunded > 0) row('Refunded', _cents(p.refunded)),
              row('Stripe fee', _cents(p.fee)),
              row('You keep', _cents(p.net - p.fee)),
              row('For', stripeStatus(d, clients, p)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          if (!p.fullyRefunded)
            FilledButton(
              onPressed: () => matchStripePayment(context, ref, p),
              child: Text(d == null ? 'Match' : 'Change'),
            ),
        ],
      );
    },
  ),
);

/// Stripe payments: the ones that need a session picked, then the rest.
class StripePaymentsPage extends ConsumerWidget {
  const StripePaymentsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(stripeProvider);
    final decisions = ref.watch(stripeDecisionsProvider);
    final clients = {for (final c in ref.watch(addressesProvider)) c.id: c};
    final unmatched = ref.watch(unmatchedStripeProvider);
    final rest = [
      for (final p in state.payments)
        if (!unmatched.contains(p)) p,
    ];
    final theme = Theme.of(context);

    Widget tile(StripePayment p) {
      final d = decisions[p.id];
      return ListTile(
        leading: const Icon(Icons.credit_card),
        title: Text('${p.who} · ${_cents(p.net)}'),
        subtitle: Text(
          '${formatShortDate(p.at.toLocal())} · ${p.method.label} · '
          '${stripeStatus(d, clients, p)}',
        ),
        onTap: () => showStripePayment(context, ref, p),
        trailing: p.fullyRefunded
            ? null
            : d == null
            ? FilledButton(
                onPressed: () => matchStripePayment(context, ref, p),
                child: const Text('Match'),
              )
            : TextButton(
                onPressed: () => matchStripePayment(context, ref, p),
                child: const Text('Change'),
              ),
      );
    }

    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Stripe payments'),
        actions: [
          IconButton(
            tooltip: 'Check Stripe now',
            icon: const Icon(Icons.refresh),
            onPressed: state.checking
                ? null
                : () => ref.read(stripeProvider.notifier).refresh(force: true),
          ),
        ],
      ),
      body: PageListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          if (state.error != null)
            ListTile(
              leading: Icon(
                Icons.error_outline,
                color: theme.colorScheme.error,
              ),
              title: Text(state.error!),
            ),
          if (state.payments.isEmpty)
            const ListTile(title: Text('No Stripe payments yet.')),
          if (unmatched.isNotEmpty) ...[
            heading('Needs a session'),
            for (final p in unmatched) tile(p),
          ],
          if (rest.isNotEmpty) ...[
            heading('Matched'),
            for (final p in rest) tile(p),
          ],
        ],
      ),
    );
  }
}

/// On the Billing tab: Stripe payments waiting to be matched.
class StripeBanner extends ConsumerWidget {
  const StripeBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.watch(unmatchedStripeProvider).length;
    if (n == 0) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card.filled(
        margin: EdgeInsets.zero,
        color: scheme.tertiaryContainer,
        child: ListTile(
          leading: Icon(Icons.credit_card, color: scheme.onTertiaryContainer),
          title: Text(
            n == 1
                ? '1 Stripe payment needs a session'
                : '$n Stripe payments need a session',
            style: TextStyle(color: scheme.onTertiaryContainer),
          ),
          subtitle: Text(
            'Couldn\'t tell which client or session it paid for.',
            style: TextStyle(color: scheme.onTertiaryContainer),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => openStripePayments(context),
        ),
      ),
    );
  }
}

/// Settings: connect Stripe with a restricted key, and its status.
class StripeSettings extends ConsumerWidget {
  const StripeSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = ref.watch(stripeKeyProvider);
    final state = ref.watch(stripeProvider);
    final unmatched = ref.watch(unmatchedStripeProvider).length;
    final scheme = Theme.of(context).colorScheme;
    if (key == null) {
      return ListTile(
        leading: const Icon(Icons.credit_card),
        title: const Text('Connect Stripe'),
        subtitle: const Text(
          'Reads payments from your payment links, marks the session each '
          'one paid for, and records Stripe\'s fees as expenses. Read only.',
        ),
        isThreeLine: true,
        trailing: FilledButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => const _ConnectStripeDialog(),
          ),
          child: const Text('Connect'),
        ),
      );
    }
    final checked = state.checkedAt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: Icon(
            state.error == null ? Icons.credit_score : Icons.error_outline,
            color: state.error == null ? scheme.primary : scheme.error,
          ),
          title: Text(
            key.startsWith('rk_test_')
                ? 'Stripe connected (test mode)'
                : 'Stripe connected',
          ),
          subtitle: Text(
            state.error ??
                [
                  '${state.payments.length} payments since January '
                      '${ref.read(clockProvider)().year - 1}',
                  if (checked != null)
                    'checked ${TimeOfDay.fromDateTime(checked).format(context)}',
                ].join(' · '),
          ),
          trailing: state.checking
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : IconButton(
                  tooltip: 'Check Stripe now',
                  icon: const Icon(Icons.refresh),
                  onPressed: () =>
                      ref.read(stripeProvider.notifier).refresh(force: true),
                ),
          onTap: () => openStripePayments(context),
        ),
        if (unmatched > 0)
          ListTile(
            contentPadding: const EdgeInsets.only(left: 72, right: 16),
            title: Text(
              unmatched == 1
                  ? '1 payment needs a session'
                  : '$unmatched payments need a session',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => openStripePayments(context),
          ),
        Padding(
          padding: const EdgeInsets.only(left: 64),
          child: Wrap(
            children: [
              TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const _ConnectStripeDialog(),
                ),
                child: const Text('Change key'),
              ),
              TextButton(
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Disconnect Stripe?'),
                      content: const Text(
                        'The app stops reading Stripe on this device and '
                        'your other one. Sessions already marked paid stay '
                        'paid. You can delete the key in Stripe too.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Disconnect'),
                        ),
                      ],
                    ),
                  );
                  if (ok == true) {
                    await ref.read(stripeProvider.notifier).disconnect();
                  }
                },
                child: const Text('Disconnect'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ConnectStripeDialog extends ConsumerStatefulWidget {
  const _ConnectStripeDialog();

  @override
  ConsumerState<_ConnectStripeDialog> createState() =>
      _ConnectStripeDialogState();
}

class _ConnectStripeDialogState extends ConsumerState<_ConnectStripeDialog> {
  final _key = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await ref.read(stripeProvider.notifier).connect(_key.text);
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context);
    } else {
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Connect Stripe'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Make a read-only key for the app in Stripe:\n\n'
                '1. In the Stripe dashboard, go to Developers → API keys '
                '(or search "API keys").\n'
                '2. Choose "Create restricted key", and name it "Dunn '
                'Record Keeping".\n'
                '3. Set these to Read: Checkout Sessions, PaymentIntents, '
                'Charges, and Balance. To make payment links from the app, '
                'set Payment Links, Products and Prices to Write. Leave '
                'everything else at None.\n'
                '4. Create it, copy the key (it starts with rk_live_), and '
                'paste it below.\n\n'
                'A restricted key like this can look at payments and make '
                'payment links, but it can\'t charge, refund or move money. '
                'It\'s kept in this device\'s keychain and shared with your '
                'other device through your Google account.',
              ),
              const SizedBox(height: 12),
              Text(
                'Testing? A test-mode key (rk_test_…) reads Stripe\'s test '
                'payments instead.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _key,
                autocorrect: false,
                obscureText: true,
                enabled: !_busy,
                decoration: InputDecoration(
                  labelText: 'Restricted key',
                  hintText: 'rk_live_…',
                  errorText: _error,
                  errorMaxLines: 5,
                ),
                onSubmitted: (_) => _connect(),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _connect,
          child: _busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Connect'),
        ),
      ],
    );
  }
}
