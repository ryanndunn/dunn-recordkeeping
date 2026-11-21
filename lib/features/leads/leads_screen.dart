import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../models/lead.dart';
import '../../models/place.dart';
import '../../services/jobs.dart' show formatClock;
import '../../state/leads_provider.dart';
import '../../state/money_provider.dart';
import '../../state/providers.dart';
import '../../widgets/client_dialog.dart';
import '../../widgets/page_body.dart';
import '../clients/client_page.dart';
import '../clients/client_status.dart';
import '../../widgets/refresh_all_button.dart';

const _uuid = Uuid();

/// People who filled out the website's contact form. Each can be made a
/// client (details filled in from the form) or dismissed.
class LeadsScreen extends ConsumerStatefulWidget {
  const LeadsScreen({super.key});

  @override
  ConsumerState<LeadsScreen> createState() => _LeadsScreenState();
}

class _LeadsScreenState extends ConsumerState<LeadsScreen> {
  LeadStatus _show = LeadStatus.open;

  Future<void> _refresh() => ref.read(syncProvider.notifier).syncNow();

  /// Google's best match for the address typed on the form, or null.
  Future<Place?> _findAddress(String text) async {
    final places = ref.read(placesServiceProvider);
    if (places == null || text.trim().isEmpty) return null;
    try {
      final session = _uuid.v4();
      final found = await places.autocomplete(text, sessionToken: session);
      if (found.isEmpty) return null;
      return await places.details(found.first.placeId, sessionToken: session);
    } catch (_) {
      return null;
    }
  }

  Future<void> _makeClient(Lead lead) async {
    final place = await _findAddress(lead.address);
    if (!mounted) return;
    final input = await showClientDialog(
      context,
      title: 'Make ${lead.name.isEmpty ? 'this lead' : lead.name} a client',
      saveLabel: 'Add client',
      initialPlace: place,
      prefill: (
        name: lead.name,
        phone: lead.phone,
        email: lead.email,
        address: lead.address,
      ),
    );
    if (input == null) return;
    final clients = ref.read(addressesProvider.notifier);
    final added = await clients.add(
      name: input.name,
      place: input.place,
      email: input.email,
      phone: input.phone,
    );
    await clients.replace(
      added.copyWith(notes: lead.notesForClient(formatShortDate)),
    );
    await ref
        .read(leadStatesProvider.notifier)
        .set(lead.id, LeadState(LeadStatus.converted, clientId: added.id));
    if (!mounted) return;
    _openClient(added.id);
  }

  void _openClient(String id) => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => ClientPage(clientId: id)));

  Future<void> _setStatus(Lead lead, LeadStatus status) =>
      ref.read(leadStatesProvider.notifier).set(lead.id, LeadState(status));

  @override
  Widget build(BuildContext context) {
    final info = ref.watch(leadsProvider);
    final leads = ref.watch(allLeadsProvider);
    final states = ref.watch(leadStatesProvider);
    final signedIn = ref.watch(syncProvider.select((s) => s.signedIn));
    final clientIds = {for (final c in ref.watch(addressesProvider)) c.id};
    LeadState stateOf(Lead l) => states[l.id]?.state ?? LeadState.open;
    int count(LeadStatus s) =>
        leads.where((l) => stateOf(l).status == s).length;
    final shown = [
      for (final l in leads)
        if (stateOf(l).status == _show) l,
    ];

    final Widget body;
    if (!info.read) {
      body = _Message(
        signedIn
            ? 'Checking for leads…'
            : 'Sign in to Google in Settings to see leads from the website '
                  'form.',
      );
    } else if (info.linked == false && leads.isEmpty) {
      body = _Setup(
        spreadsheetId: ref.watch(settingsProvider).spreadsheetId,
        onCheck: _refresh,
      );
    } else {
      body = PageListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<LeadStatus>(
              segments: [
                for (final s in LeadStatus.values)
                  ButtonSegment(
                    value: s,
                    label: Text('${s.label} (${count(s)})'),
                  ),
              ],
              selected: {_show},
              showSelectedIcon: false,
              onSelectionChanged: (v) => setState(() => _show = v.first),
            ),
          ),
          const SizedBox(height: 12),
          if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(switch (_show) {
                LeadStatus.open =>
                  'No new leads. New form entries show up here.',
                LeadStatus.converted => 'No leads made into clients yet.',
                LeadStatus.dismissed => 'No dismissed leads.',
              }),
            ),
          for (final l in shown) ...[
            _LeadCard(
              lead: l,
              state: stateOf(l),
              clientExists: clientIds.contains(stateOf(l).clientId),
              onMakeClient: () => _makeClient(l),
              onDismiss: () => _setStatus(l, LeadStatus.dismissed),
              onRestore: () => _setStatus(l, LeadStatus.open),
              onOpenClient: () => _openClient(stateOf(l).clientId!),
            ),
            const SizedBox(height: 12),
          ],
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Leads'),
        actions: [const RefreshAllButton()],
      ),
      body: body,
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);
  final String text;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.all(24), child: Text(text));
}

/// How to connect the website form: link its responses to the app's
/// spreadsheet (no new permissions needed).
class _Setup extends StatelessWidget {
  const _Setup({required this.spreadsheetId, required this.onCheck});

  final String? spreadsheetId;
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const steps = [
      'Open the contact form in Google Forms (the editor, not the public '
          'page).',
      'Go to the Responses tab and choose "Link to Sheets".',
      'Pick "Select existing spreadsheet" and choose the app\'s spreadsheet, '
          '"Dunn Record Keeping - Business Records" (it was called "Mileage '
          'Log" before).',
      'Google adds a "Form Responses" tab to it, with every response so '
          'far. Come back here and check for leads.',
    ];
    return PageListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Leads come from the website\'s contact form. Link the form to the '
          'app\'s spreadsheet once, and every new inquiry shows up here, on '
          'the phone and the Mac. (Dunn Club sign-ups go to the Club tab.)',
        ),
        const SizedBox(height: 16),
        Card.outlined(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Linking the form', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                for (final (i, step) in steps.indexed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('${i + 1}. $step'),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: onCheck,
              icon: const Icon(Icons.refresh),
              label: const Text('Check for leads'),
            ),
            if (spreadsheetId != null)
              OutlinedButton.icon(
                onPressed: () => launchUrl(
                  Uri.https(
                    'docs.google.com',
                    '/spreadsheets/d/$spreadsheetId',
                  ),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Icons.table_chart_outlined),
                label: const Text('Open the spreadsheet'),
              ),
          ],
        ),
      ],
    );
  }
}

class _LeadCard extends StatelessWidget {
  const _LeadCard({
    required this.lead,
    required this.state,
    required this.clientExists,
    required this.onMakeClient,
    required this.onDismiss,
    required this.onRestore,
    required this.onOpenClient,
  });

  final Lead lead;
  final LeadState state;
  final bool clientExists;
  final VoidCallback onMakeClient;
  final VoidCallback onDismiss;
  final VoidCallback onRestore;
  final VoidCallback onOpenClient;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final when = lead.submittedAt == null
        ? lead.submitted
        : '${formatShortDate(lead.submittedAt!)} · '
              '${formatClock(lead.submittedAt!)}';

    Widget detail(IconData icon, String text, {Uri? link}) => InkWell(
      onTap: link == null ? null : () => openClientLink(context, link),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: link == null
                    ? null
                    : TextStyle(color: theme.colorScheme.primary),
              ),
            ),
          ],
        ),
      ),
    );

    Widget answer(String question, String text) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(question, style: muted),
          Text(text),
        ],
      ),
    );

    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    lead.name.isNotEmpty
                        ? lead.name
                        : lead.email.isNotEmpty
                        ? lead.email
                        : '(No name)',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                Text(when, style: muted),
              ],
            ),
            const SizedBox(height: 4),
            if (lead.phone.isNotEmpty)
              detail(
                Icons.phone_outlined,
                lead.phone,
                link: Uri(scheme: 'tel', path: lead.phone),
              ),
            if (lead.email.isNotEmpty)
              detail(
                Icons.email_outlined,
                lead.email,
                link: Uri(scheme: 'mailto', path: lead.email),
              ),
            if (lead.address.isNotEmpty)
              detail(Icons.place_outlined, lead.address),
            if (lead.help.isNotEmpty)
              answer('What can I help you with?', lead.help),
            if (lead.heardFrom.isNotEmpty)
              answer('How did you hear about me?', lead.heardFrom),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: switch (state.status) {
                LeadStatus.open => [
                  FilledButton.icon(
                    onPressed: onMakeClient,
                    icon: const Icon(Icons.person_add_alt_1),
                    label: const Text('Make client'),
                  ),
                  TextButton(
                    onPressed: onDismiss,
                    child: const Text('Dismiss'),
                  ),
                ],
                LeadStatus.converted => [
                  if (clientExists)
                    OutlinedButton.icon(
                      onPressed: onOpenClient,
                      icon: const Icon(Icons.person_outline),
                      label: const Text('Open client'),
                    )
                  else
                    Text('The client was deleted.', style: muted),
                  TextButton(
                    onPressed: onRestore,
                    child: const Text('Back to new'),
                  ),
                ],
                LeadStatus.dismissed => [
                  TextButton(
                    onPressed: onRestore,
                    child: const Text('Back to new'),
                  ),
                ],
              },
            ),
          ],
        ),
      ),
    );
  }
}
