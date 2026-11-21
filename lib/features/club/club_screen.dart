import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/club_member.dart';
import '../../services/club.dart';
import '../../state/club_provider.dart';
import '../../state/money_provider.dart';
import '../../state/providers.dart';
import '../../widgets/client_dialog.dart';
import '../../widgets/page_body.dart';
import '../../widgets/refresh_all_button.dart';
import '../clients/client_page.dart';
import '../clients/client_status.dart';
import '../payments/payments_screen.dart' show money;
import 'club_dialogs.dart';
import 'webinar_page.dart';

enum _View { members, webinars }

enum _Who {
  all('All'),
  mailingList('Mailing list'),
  clients('Clients'),
  notClients('Not clients');

  const _Who(this.label);
  final String label;

  bool includes(ClubMember m) => switch (this) {
    _Who.all => true,
    _Who.mailingList => m.mailingList,
    _Who.clients => m.client != null,
    _Who.notClients => m.client == null,
  };
}

/// Members who joined this recently are marked new.
const _newFor = Duration(days: 14);

/// Let's Get This Dunn Club: its members (from the interest form, or added
/// by hand) and its webinars, with who paid for each.
class ClubScreen extends ConsumerStatefulWidget {
  const ClubScreen({super.key});

  @override
  ConsumerState<ClubScreen> createState() => _ClubScreenState();
}

class _ClubScreenState extends ConsumerState<ClubScreen> {
  _View _view = _View.members;
  _Who _who = _Who.all;
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _openClient(String id) => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => ClientPage(clientId: id)));

  Future<void> _addAsClient(ClubMember m) async {
    final input = await showClientDialog(
      context,
      title: 'Add ${m.displayName} as a client',
      saveLabel: 'Add client',
      prefill: (name: m.name, phone: m.phone, email: m.email, address: ''),
    );
    if (input == null) return;
    final clients = ref.read(addressesProvider.notifier);
    final added = await clients.add(
      name: input.name,
      place: input.place,
      email: input.email,
      phone: input.phone,
    );
    final joined = m.joined;
    await clients.replace(
      added.copyWith(
        notes: [
          joined == null
              ? 'Let\'s Get This Dunn Club member.'
              : 'Let\'s Get This Dunn Club member since '
                    '${formatShortDate(joined)}.',
          if (m.areas.isNotEmpty) 'Struggles with: ${m.areas}',
          if (m.topics.isNotEmpty) 'Interested in: ${m.topics}',
        ].join('\n'),
      ),
    );
    if (mounted) _openClient(added.id);
  }

  @override
  Widget build(BuildContext context) {
    final members = ref.watch(clubMembersProvider);
    final webinars = ref.watch(webinarSummariesProvider);
    final hasForm = ref.watch(clubRegistrationsProvider).isNotEmpty;
    final webinarCount = webinars.upcoming.length + webinars.past.length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Club'),
        actions: [
          if (_view == _View.members)
            IconButton(
              tooltip: 'Add members from a list',
              icon: const Icon(Icons.playlist_add),
              onPressed: () => showImportMembersDialog(context),
            ),
          const RefreshAllButton(),
        ],
      ),
      floatingActionButton: _view == _View.members
          ? FloatingActionButton.extended(
              onPressed: () => showMemberDialog(context),
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('Add member'),
            )
          : FloatingActionButton.extended(
              onPressed: () => addWebinar(context, ref),
              icon: const Icon(Icons.add),
              label: const Text('Add webinar'),
            ),
      body: PageListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<_View>(
              segments: [
                ButtonSegment(
                  value: _View.members,
                  label: Text('Members (${members.length})'),
                ),
                ButtonSegment(
                  value: _View.webinars,
                  label: Text('Webinars ($webinarCount)'),
                ),
              ],
              selected: {_view},
              showSelectedIcon: false,
              onSelectionChanged: (v) => setState(() => _view = v.first),
            ),
          ),
          const SizedBox(height: 12),
          if (_view == _View.members)
            ..._members(members, hasForm: hasForm)
          else
            ..._webinars(webinars),
        ],
      ),
    );
  }

  List<Widget> _members(List<ClubMember> all, {required bool hasForm}) {
    final now = ref.read(clockProvider)();
    final q = _search.text.trim().toLowerCase();
    final shown = [
      for (final m in all)
        if (_who.includes(m) &&
            (q.isEmpty ||
                m.name.toLowerCase().contains(q) ||
                m.email.contains(q)))
          m,
    ];
    return [
      TextField(
        controller: _search,
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search),
          hintText: 'Search members',
          border: const OutlineInputBorder(),
          isDense: true,
          suffixIcon: q.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear search',
                  icon: const Icon(Icons.clear),
                  onPressed: () => setState(_search.clear),
                ),
        ),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final w in _Who.values)
            ChoiceChip(
              label: Text('${w.label} (${all.where(w.includes).length})'),
              selected: _who == w,
              onSelected: (_) => setState(() => _who = w),
            ),
        ],
      ),
      const SizedBox(height: 8),
      if (all.isEmpty)
        _NoMembers(hasForm: hasForm)
      else if (shown.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Text('No members match.'),
        ),
      for (final m in shown)
        _MemberTile(
          member: m,
          isNew: m.joined != null && now.difference(m.joined!) < _newFor,
          onTap: () => showMemberDialog(context, member: m),
          onOpenClient: m.client == null
              ? null
              : () => _openClient(m.client!.id),
          onAddAsClient: m.client == null ? () => _addAsClient(m) : null,
        ),
    ];
  }

  List<Widget> _webinars(
    ({List<WebinarSummary> upcoming, List<WebinarSummary> past}) w,
  ) {
    final theme = Theme.of(context);
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
      child: Text(text, style: theme.textTheme.titleMedium),
    );
    final total = w.past.fold(0.0, (sum, s) => sum + s.money);
    return [
      heading('Upcoming'),
      if (w.upcoming.isEmpty)
        const Text(
          'None yet. Add the next webinar to invite members and keep track '
          'of who paid.',
        ),
      for (final s in w.upcoming) WebinarCard(summary: s),
      const SizedBox(height: 8),
      heading('Previous'),
      if (w.past.isEmpty)
        const Text(
          'Add past webinars too, to record who came and what each brought '
          'in.',
        )
      else
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            '${money(total)} from ${w.past.length} '
            '${w.past.length == 1 ? 'webinar' : 'webinars'}',
          ),
        ),
      for (final s in w.past) WebinarCard(summary: s),
    ];
  }
}

class _NoMembers extends StatelessWidget {
  const _NoMembers({required this.hasForm});
  final bool hasForm;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Text(
      'No members yet. Add existing members with "Add member", or paste a '
      'list with the list button at the top.'
      '${hasForm ? '' : '\n\nNew members come from the club\'s interest '
                'form. Link it to the app\'s spreadsheet once: open the form '
                'in Google Forms, go to Responses, choose "Link to Sheets", '
                '"Select existing spreadsheet", and pick "Dunn Record Keeping '
                '- Business Records". Everyone who fills it out then shows '
                'here.'}',
    ),
  );
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({
    required this.member,
    required this.isNew,
    required this.onTap,
    required this.onOpenClient,
    required this.onAddAsClient,
  });

  final ClubMember member;
  final bool isNew;
  final VoidCallback onTap;
  final VoidCallback? onOpenClient;
  final VoidCallback? onAddAsClient;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = member;
    final action = onOpenClient != null
        ? ActionChip(
            avatar: Icon(
              Icons.check_circle,
              size: 18,
              color: theme.colorScheme.primary,
            ),
            label: const Text('Client'),
            tooltip: 'Open ${m.client!.name}',
            onPressed: onOpenClient,
          )
        : OutlinedButton.icon(
            onPressed: onAddAsClient,
            icon: const Icon(Icons.person_add_alt_1, size: 18),
            label: const Text('Add as client'),
          );
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final joined = m.joined;
    return InkWell(
      onTap: onTap,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // On a phone the button goes under the details, so they get the
          // whole width.
          final narrow = constraints.maxWidth < 520;
          final details = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      m.displayName,
                      style: theme.textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (isNew) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.tertiaryContainer,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        'New',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onTertiaryContainer,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              if (m.name.isNotEmpty)
                Text(m.email, style: muted, overflow: TextOverflow.ellipsis),
              Text(
                [
                  if (joined != null) 'Joined ${formatShortDate(joined)}',
                  m.mailingList ? 'Mailing list' : 'Not on mailing list',
                ].join(' · '),
                style: muted,
              ),
              if (narrow) ...[const SizedBox(height: 4), action],
            ],
          );
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  child: Text(m.displayName.characters.first.toUpperCase()),
                ),
                const SizedBox(width: 16),
                Expanded(child: details),
                if (!narrow) ...[const SizedBox(width: 8), action],
              ],
            ),
          );
        },
      ),
    );
  }
}

/// A webinar in the list: when, what, who paid and how much.
class WebinarCard extends ConsumerWidget {
  const WebinarCard({super.key, required this.summary});

  final WebinarSummary summary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final s = summary;
    final w = s.webinar;
    final upcoming = w.isUpcoming(ref.read(clockProvider)());
    final facts = upcoming
        ? [
            '${s.paid.length} paid',
            if (s.free.isNotEmpty) '${s.free.length} free',
            '${s.notPaid.length} not paid',
            w.emailedAt == null
                ? 'Invite not sent'
                : 'Invited ${formatShortDate(w.emailedAt!)}',
          ]
        : ['${s.attending.length} came', money(s.money)];
    return Card.outlined(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => WebinarPage(id: w.id))),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${longDay(w.start)}, ${w.start.year} · '
                      '${clockTime(w.start)}',
                      style: theme.textTheme.titleSmall,
                    ),
                    if (w.topic.isNotEmpty) Text(w.topic),
                    const SizedBox(height: 2),
                    Text(
                      facts.join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}
