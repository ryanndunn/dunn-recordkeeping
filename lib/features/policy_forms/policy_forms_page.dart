import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/saved_address.dart';
import '../../services/mileage_sheet.dart' show recordsSpreadsheetTitle;
import '../../services/policy_forms.dart';
import '../../state/policy_forms_provider.dart';
import '../../state/providers.dart';
import '../../widgets/page_body.dart';
import '../clients/client_status.dart';

void openPolicyForms(BuildContext context) =>
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const PolicyFormsPage()));

/// "$75/hour", "$82.50/hour".
String hourlyRateText(double v) =>
    '\$${v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2)}/hour';

/// What kind of policies form [sig] came from, e.g. "$90/hour form".
String formLabel(PolicySignature sig) => sig.includesPayment
    ? sig.rate == null
          ? 'Form with payment'
          : '${hourlyRateText(sig.rate!)} form'
    : 'Form without payment';

/// Every answer [sig] gave, in a dialog.
Future<void> showSignatureAnswers(BuildContext context, PolicySignature sig) =>
    showDialog<void>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        return AlertDialog(
          title: Text(sig.who),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    [
                      formLabel(sig),
                      'Submitted ${formatShortDate(sig.at.toLocal())}',
                      if (sig.email.isNotEmpty) sig.email,
                    ].join(' · '),
                    style: theme.textTheme.bodySmall,
                  ),
                  if (sig.signedName.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text('Signature', style: theme.textTheme.labelMedium),
                    Text(sig.signedName),
                  ],
                  for (final a in sig.answers) ...[
                    const SizedBox(height: 12),
                    Text(a.question, style: theme.textTheme.labelMedium),
                    Text(a.answer, style: theme.textTheme.bodyLarge),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );

/// Asks whose signature [sig] is, then records it.
Future<void> pickSignatureOwner(
  BuildContext context,
  WidgetRef ref,
  PolicySignature sig,
) async {
  final clients = [...ref.read(addressesProvider)]
    ..sort((a, b) {
      // Clients still waiting on their policies first.
      final wa = a.policiesSignedOn == null ? 0 : 1;
      final wb = b.policiesSignedOn == null ? 0 : 1;
      if (wa != wb) return wa.compareTo(wb);
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  final clientId = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text('Whose policies did ${sig.who} sign?'),
      children: [
        for (final c in clients)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, c.id),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(c.name),
              subtitle: Text(
                c.policiesSignedOn == null
                    ? c.status.label
                    : 'Signed ${formatShortDate(c.policiesSignedOn!)}',
              ),
            ),
          ),
        const Divider(),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, ''),
          child: const Text('Not a client\'s policies'),
        ),
      ],
    ),
  );
  if (clientId == null || !context.mounted) return;
  final forms = ref.read(policySignaturesProvider.notifier);
  if (clientId.isEmpty) {
    await forms.ignore(sig);
    return;
  }
  final client = clients.firstWhere((c) => c.id == clientId);
  // Who signed: the client, one of their contacts, or someone new (often
  // the person paying).
  final who = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text('Who is ${sig.who}?'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, 'client'),
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.person_outline),
            title: Text(client.name),
            subtitle: const Text('The client'),
          ),
        ),
        for (final p in client.contacts)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, p.id),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.contacts_outlined),
              title: Text(p.name.isEmpty ? p.email : p.name),
              subtitle: Text(p.label.isEmpty ? 'Contact' : p.label),
            ),
          ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, 'new'),
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.person_add_alt),
            title: const Text('Someone else'),
            subtitle: Text(
              'Add ${sig.who} to ${client.name}\'s contacts'
              '${sig.includesPayment ? ' as the person who pays' : ''}',
            ),
          ),
        ),
      ],
    ),
  );
  if (who == null) return;
  await forms.assign(
    sig,
    clientId,
    contactId: who == 'client' || who == 'new' ? null : who,
    newContact: who == 'new',
  );
}

/// Who signed, for display: the client's name or the contact's (with
/// their label).
String signerName(SavedAddress client, String? contactId) {
  if (contactId == null) return client.name;
  final p = client.contacts.where((p) => p.id == contactId).firstOrNull;
  if (p == null) return 'A removed contact';
  final name = p.name.isEmpty ? p.email : p.name;
  return p.label.isEmpty ? name : '$name (${p.label})';
}

/// Policies form responses read from the spreadsheet: the ones that need
/// a client picked, and the ones already matched (which can be changed).
class PolicyFormsPage extends ConsumerWidget {
  const PolicyFormsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sigs = ref.watch(policySignaturesProvider).reversed.toList();
    final decisions = ref.watch(signatureDecisionsProvider);
    final clients = {for (final c in ref.watch(addressesProvider)) c.id: c};
    final theme = Theme.of(context);
    final unmatched = [
      for (final s in sigs)
        if (!decisions.containsKey(s.id)) s,
    ];
    final handled = [
      for (final s in sigs)
        if (decisions.containsKey(s.id)) s,
    ];

    Widget tile(PolicySignature s) {
      final decision = decisions[s.id]?.decision;
      final String status;
      if (decision == null) {
        status = 'Needs a client';
      } else if (decision.clientId == null) {
        status = 'Not a client\'s policies';
      } else {
        final client = clients[decision.clientId];
        final who = client == null
            ? 'a deleted client'
            : decision.contactId == null
            ? client.name
            : '${signerName(client, decision.contactId)} for ${client.name}';
        status = decision.automatic ? '$who (matched)' : who;
      }
      return ListTile(
        leading: Icon(
          s.includesPayment ? Icons.request_quote_outlined : Icons.how_to_reg,
        ),
        title: Text(s.who),
        subtitle: Text(
          '${formLabel(s)} · ${formatShortDate(s.at.toLocal())} · $status',
        ),
        onTap: () => showSignatureAnswers(context, s),
        trailing: decision == null
            ? FilledButton(
                onPressed: () => pickSignatureOwner(context, ref, s),
                child: const Text('Match'),
              )
            : TextButton(
                onPressed: () => pickSignatureOwner(context, ref, s),
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
        title: const Text('Signed policies'),
        actions: [
          IconButton(
            tooltip: 'How to link a policies form',
            icon: const Icon(Icons.help_outline),
            onPressed: () => showLinkPolicyFormHelp(context),
          ),
        ],
      ),
      body: PageListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          if (sigs.isEmpty)
            ListTile(
              title: const Text('No policies forms signed yet'),
              subtitle: const Text(
                'Link each policies form to the business records '
                'spreadsheet, and responses show up here.',
              ),
              trailing: TextButton(
                onPressed: () => showLinkPolicyFormHelp(context),
                child: const Text('How'),
              ),
            ),
          if (unmatched.isNotEmpty) ...[
            heading('Needs a client'),
            for (final s in unmatched) tile(s),
          ],
          if (handled.isNotEmpty) ...[
            heading('Matched'),
            for (final s in handled) tile(s),
          ],
        ],
      ),
    );
  }
}

/// How to send a policies form's responses to the app.
Future<void> showLinkPolicyFormHelp(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text('Link a policies form'),
    content: const SingleChildScrollView(
      child: Text(
        'Do this once for each policies form (every rate, and the forms '
        'for the person who pays and the person you work with), signed in '
        'to the same Google account as the app:\n\n'
        '1. Open the form in Google Forms and go to Responses.\n'
        '2. Choose Link to Sheets (or ⋮ → Select response destination).\n'
        '3. Pick "Select existing spreadsheet" and choose '
        '"$recordsSpreadsheetTitle".\n\n'
        'Google adds a "Form Responses" tab for it. Leave that tab\'s '
        'name as it is. Earlier responses come along too.\n\n'
        'The app recognizes a policies form by its signature question, '
        'reads the rate from its "hourly rate of \$…/hour" question, and '
        'treats a form without that question as the one for the person '
        'you work with when someone else pays.\n\n'
        'A client is signed once everyone marked "Needs to sign '
        'policies" in their contacts has signed (the client themself, '
        'unless you uncheck it) and someone has agreed to pay.',
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

/// On the client list: policy signatures the app couldn't match.
class PolicyFormsBanner extends ConsumerWidget {
  const PolicyFormsBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.watch(unmatchedSignaturesProvider).length;
    if (n == 0) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.tertiaryContainer,
      child: ListTile(
        leading: Icon(Icons.edit_document, color: scheme.onTertiaryContainer),
        title: Text(
          n == 1
              ? '1 signed policies form needs a client'
              : '$n signed policies forms need a client',
          style: TextStyle(color: scheme.onTertiaryContainer),
        ),
        trailing: TextButton(
          onPressed: () => openPolicyForms(context),
          child: const Text('Match'),
        ),
        onTap: () => openPolicyForms(context),
      ),
    );
  }
}

/// Settings: the policies forms the app reads.
class PolicyFormsSettings extends ConsumerWidget {
  const PolicyFormsSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sigs = ref.watch(policySignaturesProvider);
    final unmatched = ref.watch(unmatchedSignaturesProvider).length;
    final forms = <String, PolicySignature>{for (final s in sigs) s.form: s}
        .values
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: const Icon(Icons.edit_document),
          title: const Text('Signed policies'),
          subtitle: Text(
            sigs.isEmpty
                ? 'No policies form responses yet. Link each policies form '
                      'to the business records spreadsheet.'
                : [
                    forms.length == 1
                        ? '1 form linked'
                        : '${forms.length} forms linked',
                    sigs.length == 1
                        ? '1 response'
                        : '${sigs.length} responses',
                    if (unmatched > 0) '$unmatched need a client',
                  ].join(' · '),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => openPolicyForms(context),
        ),
        for (final f in forms)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 72, right: 16),
            title: Text(formLabel(f)),
            subtitle: Text(
              f.includesPayment
                  ? 'Agrees to pay · tab "${f.form}"'
                  : 'No payment (for the person you work with when '
                        'someone else pays) · tab "${f.form}"',
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 64),
            child: TextButton.icon(
              icon: const Icon(Icons.link),
              label: const Text('How to link a policies form'),
              onPressed: () => showLinkPolicyFormHelp(context),
            ),
          ),
        ),
      ],
    );
  }
}
