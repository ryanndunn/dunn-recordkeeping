import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../models/place.dart';
import '../../models/saved_address.dart';
import '../../state/providers.dart';
import '../../widgets/address_search_field.dart';
import '../../widgets/client_dialog.dart' show looksLikeEmail;
import '../../widgets/page_body.dart';
import '../../widgets/payment_fields.dart';
import '../../services/client_jobs.dart';
import '../../services/policy_forms.dart' show PolicyProgress;
import '../../state/policy_forms_provider.dart';
import '../policy_forms/policy_forms_page.dart';
import '../../services/jobs.dart' show formatClock, formatHours;
import 'client_status.dart';

/// Opens [uri] in whatever app handles it, or says nothing can.
Future<void> openClientLink(BuildContext context, Uri uri) async {
  final messenger = ScaffoldMessenger.of(context);
  var opened = false;
  try {
    opened = await launchUrl(uri);
  } catch (_) {}
  if (!opened) {
    messenger.showSnackBar(
      const SnackBar(content: Text('No app on this device can open that.')),
    );
  }
}

const _uuid = Uuid();

/// Directions to [address]. On Android this offers every navigation app
/// (Google Maps, Waze, …); elsewhere it opens Google Maps in the browser.
Uri directionsUri(String address, String? placeId) {
  if (!kIsWeb && Platform.isAndroid) {
    return Uri.parse('geo:0,0?q=${Uri.encodeComponent(address)}');
  }
  return Uri.https('www.google.com', '/maps/dir/', {
    'api': '1',
    'destination': address,
    'destination_place_id': ?placeId,
  });
}

/// Suggested names for a client's other addresses.
const locationLabelSuggestions = [
  'Home',
  'Second home',
  'Vacation home',
  'Storage unit',
  'Office',
];

String clientInitials(String name) {
  final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  return words.take(2).map((w) => w[0].toUpperCase()).join();
}

/// Wide windows (the Mac) show the client list beside the page.
const _sidebarBreakpoint = 900.0;

/// One client's page: how to reach them, their details (tap any to edit),
/// notes and sessions. The other clients are a tap away: in a sidebar on
/// wide windows, or behind the people button on a phone.
class ClientPage extends ConsumerStatefulWidget {
  const ClientPage({super.key, required this.clientId});

  final String clientId;

  @override
  ConsumerState<ClientPage> createState() => _ClientPageState();
}

class _ClientPageState extends ConsumerState<ClientPage> {
  late String _id = widget.clientId;
  final _scaffold = GlobalKey<ScaffoldState>();

  /// Kept so a save still lands after the page closes (e.g. notes typed
  /// just before going back).
  late final ProviderContainer _container = ProviderScope.containerOf(
    context,
    listen: false,
  );

  /// Saves a change to client [id], applied to its latest version (so a
  /// change synced from the other device meanwhile isn't undone).
  Future<void> _change(
    String id,
    SavedAddress Function(SavedAddress c) edit,
  ) async {
    final latest = _container
        .read(addressesProvider)
        .where((c) => c.id == id)
        .firstOrNull;
    if (latest == null) return;
    await _container.read(addressesProvider.notifier).replace(edit(latest));
  }

  void _pick(String id) {
    _scaffold.currentState?.closeEndDrawer();
    if (id != _id) setState(() => _id = id);
  }

  Future<void> _delete(SavedAddress c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${c.name}"?'),
        content: const Text('Trips already logged to this client are kept.'),
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
    );
    if (ok != true || !mounted) return;
    Navigator.of(context).pop();
    await ref.read(addressesProvider.notifier).remove(c.id);
  }

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(addressesProvider);
    final client = all.where((c) => c.id == _id).firstOrNull;
    final wide = MediaQuery.sizeOf(context).width >= _sidebarBreakpoint;
    final sidebar = _ClientSidebar(clients: all, currentId: _id, onPick: _pick);

    final Widget content = client == null
        // Deleted (possibly on the other device) while open.
        ? const Padding(
            padding: EdgeInsets.all(24),
            child: Text('This client was deleted.'),
          )
        : _ClientDetails(
            key: ValueKey(client.id),
            client: client,
            change: (edit) => _change(client.id, edit),
          );

    return Scaffold(
      key: _scaffold,
      appBar: AppBar(
        title: Text(client?.name ?? ''),
        actions: [
          if (!wide)
            IconButton(
              tooltip: 'Other clients',
              icon: const Icon(Icons.people_alt_outlined),
              onPressed: () => _scaffold.currentState?.openEndDrawer(),
            ),
          if (client != null)
            IconButton(
              tooltip: 'Delete client',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _delete(client),
            ),
        ],
      ),
      endDrawer: wide ? null : Drawer(child: SafeArea(child: sidebar)),
      body: wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 280, child: sidebar),
                const VerticalDivider(width: 1),
                Expanded(child: content),
              ],
            )
          : content,
    );
  }
}

/// Every current client (and the open one, even if archived), by name.
class _ClientSidebar extends StatelessWidget {
  const _ClientSidebar({
    required this.clients,
    required this.currentId,
    required this.onPick,
  });

  final List<SavedAddress> clients;
  final String currentId;
  final void Function(String id) onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = [
      for (final c in clients)
        if (c.status != ClientStatus.archived || c.id == currentId) c,
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              'Clients',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          for (final c in shown)
            ListTile(
              dense: true,
              selected: c.id == currentId,
              selectedTileColor: theme.colorScheme.secondaryContainer,
              shape: const StadiumBorder(),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              leading: CircleAvatar(
                radius: 16,
                backgroundColor: statusColors(c.status, theme.colorScheme).bg,
                foregroundColor: statusColors(c.status, theme.colorScheme).fg,
                child: Text(
                  clientInitials(c.name),
                  style: theme.textTheme.labelMedium,
                ),
              ),
              title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(c.status.label),
              onTap: () => onPick(c.id),
            ),
        ],
      ),
    );
  }
}

/// The page itself for one client.
class _ClientDetails extends ConsumerWidget {
  const _ClientDetails({super.key, required this.client, required this.change});

  final SavedAddress client;
  final Future<void> Function(SavedAddress Function(SavedAddress c) edit)
  change;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = client;
    final now = ref.read(clockProvider)();
    final jobs = clientJobs(
      client: c,
      jobs: ref.watch(allJobSummariesProvider),
      trips: ref.watch(tripsProvider),
      now: now,
    );

    Future<void> save(SavedAddress Function(SavedAddress c) edit) =>
        change(edit);
    Future<void> saveAddresses(
      List<ClientLocation> Function(List<ClientLocation> current) edit,
    ) => change((x) => x.withAddresses(edit(x.allAddresses)));
    // Who needs to sign may have changed: they might be signed now.
    Future<void> recheckPolicies() =>
        ref.read(policySignaturesProvider.notifier).recheck(c.id);
    Future<void> saveContacts(
      List<ClientContact> Function(List<ClientContact> current) edit,
    ) async {
      await change((x) => x.copyWith(contacts: edit(x.contacts)));
      await recheckPolicies();
    }

    final progress = ref.watch(policyProgressProvider(c.id));
    String? policyNote(String? who) {
      if (!progress.required.contains(who)) return null;
      final sig = progress.signatures
          .where((s) => s.contactId == who)
          .firstOrNull;
      return sig == null
          ? 'Needs to sign policies'
          : 'Signed policies ${formatShortDate(sig.sig.at.toLocal())}';
    }

    final signed = c.policiesSignedOn != null;
    final policyDoc = [
      _SectionTitle('Policy doc'),
      _PolicyDocCard(
        client: c,
        today: now,
        progress: progress,
        onSave: (u) => save((_) => u),
      ),
    ];
    final addresses = c.allAddresses;

    return PageListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        _Header(
          key: ValueKey('header-${c.id}'),
          client: c,
          onStatus: (next) => save((x) => withStatus(x, next, now)),
          onRename: (name) => save((x) => x.copyWith(name: name)),
        ),
        const SizedBox(height: 16),
        _ContactButtons(client: c),
        if (!signed) ...[const SizedBox(height: 24), ...policyDoc],
        const SizedBox(height: 24),
        _SectionTitle('Notes'),
        _NotesField(
          initial: c.notes,
          onSave: (v) => save((x) => x.copyWith(notes: v)),
        ),
        const SizedBox(height: 24),
        _SectionTitle('Contacts'),
        Card.outlined(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              // The client themself, then anyone else.
              _ContactRow(
                key: ValueKey('contact-primary-${c.id}'),
                contact: c.primaryContact,
                policyNote: policyNote(null),
                onSave: (updated) async {
                  await save(
                    (x) => x.copyWith(
                      name: updated.name,
                      phone: updated.phone,
                      email: updated.email,
                      // "Primary" is the default, so it isn't stored.
                      contactLabel: updated.label == 'Primary'
                          ? ''
                          : updated.label,
                      primarySigns: updated.signsPolicies,
                    ),
                  );
                  await recheckPolicies();
                },
              ),
              for (final p in c.contacts) ...[
                const Divider(height: 1),
                _ContactRow(
                  key: ValueKey('contact-${p.id}'),
                  contact: p,
                  policyNote: policyNote(p.id),
                  onSave: (updated) => saveContacts(
                    (all) => [for (final x in all) x.id == p.id ? updated : x],
                  ),
                  onRemove: () => saveContacts(
                    (all) => [
                      for (final x in all)
                        if (x.id != p.id) x,
                    ],
                  ),
                ),
              ],
              const Divider(height: 1),
              _AddContact(
                key: ValueKey('add-contact-${c.id}'),
                onAdd: (p) => saveContacts((all) => [...all, p]),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        _SectionTitle('Rate'),
        Card.outlined(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: _EditableText(
            key: ValueKey('rate-${c.id}'),
            label: 'Hourly rate',
            icon: Icons.attach_money,
            value: rateText(c.hourlyRate),
            display: (v) => '${formatDollars(c.hourlyRate)} per hour',
            prefixText: '\$ ',
            suffixText: '/ hour',
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.,$]')),
            ],
            validate: (v) => parseRate(v) == null ? 'Enter an amount' : null,
            onSave: (v) => save((x) => x.copyWith(hourlyRate: parseRate(v))),
          ),
        ),
        const SizedBox(height: 24),
        _SectionTitle('Addresses'),
        Card.outlined(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (final (i, l) in addresses.indexed) ...[
                if (i > 0) const Divider(height: 1),
                _LocationRow(
                  key: ValueKey('location-${c.id}-${l.id}'),
                  location: l,
                  onSave: (updated) => saveAddresses(
                    (all) => [for (final x in all) x.id == l.id ? updated : x],
                  ),
                  // A client always keeps at least one address.
                  onRemove: addresses.length < 2
                      ? null
                      : () => saveAddresses(
                          (all) => [
                            for (final x in all)
                              if (x.id != l.id) x,
                          ],
                        ),
                ),
              ],
              const Divider(height: 1),
              _AddLocation(
                key: ValueKey('add-location-${c.id}'),
                onAdd: (label, place) => saveAddresses(
                  (all) => [
                    ...all,
                    ClientLocation(
                      id: _uuid.v4(),
                      label: label,
                      address: place.address,
                      placeId: place.placeId,
                      lat: place.lat,
                      lng: place.lng,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        _JobsSection(
          client: c,
          entries: jobs,
          now: now,
          onSave: (edit) => save(edit),
        ),
        if (signed) ...[const SizedBox(height: 24), ...policyDoc],
      ],
    );
  }
}

final _phoneChars = FilteringTextInputFormatter.allow(RegExp(r'[0-9+()\-. x]'));

String? _checkEmail(String v) =>
    v.isNotEmpty && !looksLikeEmail(v) ? 'Check the email address' : null;

/// [c] moved to status [next]. Finishing the consultation records its day
/// (today). Changing the status never asks for a date; the signed date
/// lives in the Policy doc section.
SavedAddress withStatus(SavedAddress c, ClientStatus next, DateTime today) {
  final consultationDone =
      c.status == ClientStatus.consultation &&
      next == ClientStatus.policyDoc &&
      c.consultationOn == null;
  return c.copyWith(
    status: next,
    consultationOn: consultationDone
        ? DateTime(today.year, today.month, today.day)
        : null,
  );
}

/// Avatar, name (with a pencil to rename) and the status menu.
class _Header extends StatefulWidget {
  const _Header({
    super.key,
    required this.client,
    required this.onStatus,
    required this.onRename,
  });
  final SavedAddress client;
  final void Function(ClientStatus next) onStatus;
  final Future<void> Function(String name) onRename;

  @override
  State<_Header> createState() => _HeaderState();
}

class _HeaderState extends State<_Header> {
  final _name = TextEditingController();
  bool _editing = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _start() => setState(() {
    _name.text = widget.client.name;
    _name.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _name.text.length,
    );
    _editing = true;
  });

  Future<void> _submit() async {
    final v = _name.text.trim();
    if (v.isEmpty) return;
    setState(() => _editing = false);
    if (v != widget.client.name) await widget.onRename(v);
  }

  @override
  Widget build(BuildContext context) {
    final client = widget.client;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final status = client.status;
    final Widget name = _editing
        ? CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): () =>
                  setState(() => _editing = false),
            },
            child: TextField(
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              style: theme.textTheme.titleLarge,
              decoration: InputDecoration(
                labelText: 'Name',
                isDense: true,
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Cancel',
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() => _editing = false),
                    ),
                    IconButton(
                      tooltip: 'Save name',
                      icon: Icon(Icons.check, color: scheme.primary),
                      onPressed: _submit,
                    ),
                  ],
                ),
              ),
              onSubmitted: (_) => _submit(),
            ),
          )
        : InkWell(
            onTap: _start,
            borderRadius: BorderRadius.circular(8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    client.name,
                    style: theme.textTheme.headlineSmall,
                  ),
                ),
                const SizedBox(width: 4),
                Tooltip(
                  message: 'Edit name',
                  child: Icon(
                    Icons.edit_outlined,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        CircleAvatar(
          radius: 32,
          backgroundColor: client.isVerified
              ? scheme.primaryContainer
              : scheme.errorContainer,
          child: client.isVerified
              ? Text(
                  clientInitials(client.name),
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: scheme.onPrimaryContainer,
                  ),
                )
              : Icon(Icons.warning_amber, size: 30, color: scheme.error),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              name,
              const SizedBox(height: 6),
              PopupMenuButton<ClientStatus>(
                tooltip: 'Change status',
                onSelected: widget.onStatus,
                itemBuilder: (_) => [
                  for (final s in ClientStatus.values)
                    PopupMenuItem(
                      value: s,
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(statusIcon(s)),
                        title: Text(s.label),
                        trailing: s == status ? const Icon(Icons.check) : null,
                      ),
                    ),
                ],
                child: ClientStatusBadge(client: client, dropdown: true),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Call, text, email and directions. Buttons for missing details are
/// greyed out.
class _ContactButtons extends StatelessWidget {
  const _ContactButtons({required this.client});
  final SavedAddress client;

  /// Directions to the only address, or a choice of them.
  Future<void> _directions(BuildContext context) async {
    final all = client.allAddresses;
    final l = all.length == 1
        ? all.single
        : await showModalBottomSheet<ClientLocation>(
            context: context,
            showDragHandle: true,
            builder: (context) => SafeArea(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final l in all)
                    ListTile(
                      leading: const Icon(Icons.directions_outlined),
                      title: Text(addressTitle(l)),
                      subtitle: Text(l.address),
                      onTap: () => Navigator.pop(context, l),
                    ),
                ],
              ),
            ),
          );
    if (l == null || !context.mounted) return;
    await openClientLink(context, directionsUri(l.address, l.placeId));
  }

  @override
  Widget build(BuildContext context) {
    final c = client;
    Widget button(
      IconData icon,
      String label,
      Uri? uri, {
      VoidCallback? onPressed,
    }) => Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: FilledButton.tonal(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          onPressed:
              onPressed ??
              (uri == null ? null : () => openClientLink(context, uri)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon),
              const SizedBox(height: 4),
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ),
    );
    return Row(
      children: [
        button(
          Icons.phone,
          'Call',
          c.phone.isEmpty ? null : Uri(scheme: 'tel', path: c.phone),
        ),
        button(
          Icons.sms_outlined,
          'Text',
          c.phone.isEmpty ? null : Uri(scheme: 'sms', path: c.phone),
        ),
        button(
          Icons.email_outlined,
          'Email',
          c.email.isEmpty ? null : Uri(scheme: 'mailto', path: c.email),
        ),
        button(
          Icons.directions_outlined,
          'Directions',
          null,
          onPressed: () => _directions(context),
        ),
      ],
    );
  }
}

/// Notes about the client, saved as you type.
class _NotesField extends StatefulWidget {
  const _NotesField({required this.initial, required this.onSave});

  final String initial;
  final Future<void> Function(String notes) onSave;

  @override
  State<_NotesField> createState() => _NotesFieldState();
}

class _NotesFieldState extends State<_NotesField> {
  late final _controller = TextEditingController(text: widget.initial);
  final _focus = FocusNode();
  Timer? _pending;
  late String _saved = widget.initial;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _saveNow();
    });
  }

  @override
  void didUpdateWidget(_NotesField old) {
    super.didUpdateWidget(old);
    // Changed on the other device: show it, unless typing here.
    if (!_focus.hasFocus &&
        widget.initial != _saved &&
        widget.initial != _controller.text) {
      _controller.text = widget.initial;
      _saved = widget.initial;
    }
  }

  void _saveNow() {
    _pending?.cancel();
    _pending = null;
    final text = _controller.text.trimRight();
    if (text == _saved) return;
    _saved = text;
    widget.onSave(text);
  }

  @override
  void dispose() {
    _saveNow();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _controller,
    focusNode: _focus,
    minLines: 4,
    maxLines: 12,
    keyboardType: TextInputType.multiline,
    textCapitalization: TextCapitalization.sentences,
    decoration: const InputDecoration(
      hintText:
          'Anything to remember: preferences, access, what they\'re '
          'keeping…',
      border: OutlineInputBorder(),
      helperText: 'Saved as you type',
    ),
    onChanged: (_) {
      _pending?.cancel();
      _pending = Timer(const Duration(milliseconds: 800), _saveNow);
    },
  );
}

/// Whether (and when) the client signed the policies: the policies forms
/// they (and whoever pays) filled in, and what's still missing. Marking it
/// signed makes the client active; marking it not signed puts an active
/// client back to waiting on the policy doc. Archived clients stay
/// archived.
class _PolicyDocCard extends StatelessWidget {
  const _PolicyDocCard({
    required this.client,
    required this.today,
    required this.progress,
    required this.onSave,
  });

  final SavedAddress client;

  /// The policies forms matched to this client.
  final PolicyProgress progress;
  final DateTime today;
  final Future<void> Function(SavedAddress updated) onSave;

  bool get _archived => client.status == ClientStatus.archived;

  Future<void> _pickSignedDay(BuildContext context) async {
    final day = DateTime(today.year, today.month, today.day);
    final picked = await showDatePicker(
      context: context,
      helpText: 'Policies signed on',
      initialDate: client.policiesSignedOn ?? day,
      firstDate: DateTime(2000),
      lastDate: day,
    );
    if (picked == null) return;
    await onSave(
      client.copyWith(
        policiesSignedOn: DateTime(picked.year, picked.month, picked.day),
        status: _archived ? null : ClientStatus.active,
      ),
    );
  }

  Future<void> _unsign() => onSave(
    client.copyWith(
      clearPoliciesSigned: true,
      status: client.status == ClientStatus.active
          ? ClientStatus.policyDoc
          : null,
    ),
  );

  /// What's still missing, if anything: a form from each person who needs
  /// to sign, and one agreeing to pay.
  String? get _waitingOn {
    if (progress.signatures.isEmpty) return null;
    final parts = [
      for (final m in progress.missing) signerName(client, m),
      if (!progress.paymentSigned) 'someone agreeing to pay',
    ];
    if (parts.isEmpty) return null;
    return parts.length == 1
        ? parts.single
        : '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
  }

  /// Who needs to sign, before anyone has.
  String get _whoSigns {
    final names = [for (final r in progress.required) signerName(client, r)];
    return names.isEmpty
        ? 'Nobody is marked as needing to sign (see Contacts)'
        : 'To sign: ${names.join(', ')}';
  }

  /// One line per form signed: who, which form, when. Tapping opens the
  /// answers.
  List<Widget> _signatures(BuildContext context) => [
    for (final s in progress.signatures)
      ListTile(
        dense: true,
        contentPadding: const EdgeInsets.only(left: 72, right: 16),
        leading: Icon(
          s.sig.includesPayment
              ? Icons.request_quote_outlined
              : Icons.how_to_reg,
          size: 20,
        ),
        title: Text(signerName(client, s.contactId)),
        subtitle: Text(
          '${formLabel(s.sig)} · ${formatShortDate(s.sig.at.toLocal())}',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => showSignatureAnswers(context, s.sig),
      ),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final signed = client.policiesSignedOn;
    if (signed == null) {
      final waiting = _waitingOn;
      return Card.outlined(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.edit_document),
              title: Text(
                waiting == null ? 'Not signed yet' : 'Waiting on $waiting',
              ),
              subtitle: Text(
                [
                  if (client.consultationOn != null)
                    'Consultation ${formatShortDate(client.consultationOn!)}',
                  if (progress.signatures.isEmpty) _whoSigns,
                  _archived
                      ? 'Signing won\'t change the archived status.'
                      : 'Marked signed when the policies form is in.',
                ].join(' · '),
              ),
              trailing: FilledButton(
                onPressed: () => _pickSignedDay(context),
                child: const Text('Mark signed'),
              ),
            ),
            ..._signatures(context),
          ],
        ),
      );
    }
    final rate = progress.rate;
    return Card.outlined(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          ListTile(
            onTap: () => _pickSignedDay(context),
            leading: Icon(Icons.verified_outlined, color: scheme.primary),
            title: Text('Signed ${formatShortDate(signed)}'),
            subtitle: Text(
              progress.signatures.isEmpty
                  ? 'Tap to change the date'
                  : rate == null
                  ? 'Signed with the policies form'
                  : 'Agreed to ${hourlyRateText(rate)}',
            ),
            trailing: PopupMenuButton<String>(
              tooltip: 'Policy doc options',
              onSelected: (choice) {
                if (choice == 'date') _pickSignedDay(context);
                if (choice == 'unsign') _unsign();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'date', child: Text('Change signed date')),
                PopupMenuItem(
                  value: 'unsign',
                  child: Text('Mark as not signed'),
                ),
              ],
            ),
          ),
          ..._signatures(context),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall
          ?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}

/// A detail shown as text; tap it (or the pencil) to edit it in place.
class _EditableText extends StatefulWidget {
  const _EditableText({
    super.key,
    required this.label,
    required this.icon,
    required this.value,
    required this.onSave,
    this.validate,
    this.keyboardType,
    this.inputFormatters,
    this.display,
    this.prefixText,
    this.suffixText,
  });

  final String label;
  final IconData icon;
  final String value;
  final String? Function(String value)? validate;
  final Future<void> Function(String value) onSave;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;

  /// How [value] reads when not editing (default: as is).
  final String Function(String value)? display;
  final String? prefixText;
  final String? suffixText;

  @override
  State<_EditableText> createState() => _EditableTextState();
}

class _EditableTextState extends State<_EditableText> {
  final _controller = TextEditingController();
  bool _editing = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _start() => setState(() {
    _controller.text = widget.value;
    _controller.selection = TextSelection.collapsed(
      offset: widget.value.length,
    );
    _error = null;
    _editing = true;
  });

  void _cancel() => setState(() => _editing = false);

  Future<void> _submit() async {
    final v = _controller.text.trim();
    final error = widget.validate?.call(v);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() => _editing = false);
    if (v != widget.value) await widget.onSave(v);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_editing) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.escape): _cancel},
          child: TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: widget.keyboardType,
            inputFormatters: widget.inputFormatters,
            autocorrect: widget.keyboardType != TextInputType.emailAddress,
            decoration: InputDecoration(
              labelText: widget.label,
              prefixIcon: Icon(widget.icon),
              prefixText: widget.prefixText,
              suffixText: widget.suffixText,
              errorText: _error,
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Cancel',
                    icon: const Icon(Icons.close),
                    onPressed: _cancel,
                  ),
                  IconButton(
                    tooltip: 'Save ${widget.label.toLowerCase()}',
                    icon: Icon(Icons.check, color: scheme.primary),
                    onPressed: _submit,
                  ),
                ],
              ),
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _submit(),
          ),
        ),
      );
    }
    final empty = widget.value.isEmpty;
    return ListTile(
      onTap: _start,
      leading: Icon(widget.icon),
      title: Text(
        empty ? '' : widget.display?.call(widget.value) ?? widget.value,
        style: empty ? TextStyle(color: scheme.onSurfaceVariant) : null,
      ),
      subtitle: Text(widget.label),
      trailing: IconButton(
        tooltip: 'Edit ${widget.label.toLowerCase()}',
        icon: const Icon(Icons.edit_outlined),
        onPressed: _start,
      ),
    );
  }
}

/// Someone to reach about the client (the client themself first), with
/// their label and call and email buttons. Tap the row to edit them, or
/// remove them ([onRemove] is null for the client themself).
class _ContactRow extends StatefulWidget {
  const _ContactRow({
    super.key,
    required this.contact,
    required this.onSave,
    this.onRemove,
    this.policyNote,
  });

  final ClientContact contact;
  final Future<void> Function(ClientContact updated) onSave;
  final Future<void> Function()? onRemove;

  /// "Needs to sign policies" or "Signed policies …", if they sign them.
  final String? policyNote;

  @override
  State<_ContactRow> createState() => _ContactRowState();
}

class _ContactRowState extends State<_ContactRow> {
  bool _editing = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.contact;
    if (_editing) {
      return _ContactEditor(
        initial: p,
        onCancel: () => setState(() => _editing = false),
        onSave: (updated) async {
          setState(() => _editing = false);
          await widget.onSave(updated);
        },
        onRemove: widget.onRemove == null
            ? null
            : () async {
                setState(() => _editing = false);
                await widget.onRemove!();
              },
      );
    }
    final theme = Theme.of(context);
    final details = [p.phone, p.email].where((x) => x.isNotEmpty).join('\n');
    final note = widget.policyNote;
    final signed = note != null && note.startsWith('Signed');
    return ListTile(
      onTap: () => setState(() => _editing = true),
      leading: const Icon(Icons.person_outline),
      title: Row(
        children: [
          Flexible(child: Text(p.name)),
          if (p.label.isNotEmpty) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                p.label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            details.isEmpty ? 'Tap to add a phone number or email' : details,
            style: details.isEmpty
                ? TextStyle(color: theme.colorScheme.onSurfaceVariant)
                : null,
          ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                children: [
                  Icon(
                    signed ? Icons.verified_outlined : Icons.edit_document,
                    size: 16,
                    color: signed
                        ? theme.colorScheme.primary
                        : theme.colorScheme.tertiary,
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      note,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: signed
                            ? theme.colorScheme.primary
                            : theme.colorScheme.tertiary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (p.phone.isNotEmpty)
            IconButton(
              tooltip: 'Call ${p.name}',
              icon: const Icon(Icons.phone_outlined),
              onPressed: () =>
                  openClientLink(context, Uri(scheme: 'tel', path: p.phone)),
            ),
          if (p.email.isNotEmpty)
            IconButton(
              tooltip: 'Email ${p.name}',
              icon: const Icon(Icons.email_outlined),
              onPressed: () =>
                  openClientLink(context, Uri(scheme: 'mailto', path: p.email)),
            ),
        ],
      ),
    );
  }
}

/// "Add a contact" button, which opens an empty editor.
class _AddContact extends StatefulWidget {
  const _AddContact({super.key, required this.onAdd});

  final Future<void> Function(ClientContact contact) onAdd;

  @override
  State<_AddContact> createState() => _AddContactState();
}

class _AddContactState extends State<_AddContact> {
  bool _adding = false;

  @override
  Widget build(BuildContext context) {
    if (_adding) {
      return _ContactEditor(
        onCancel: () => setState(() => _adding = false),
        onSave: (p) async {
          setState(() => _adding = false);
          await widget.onAdd(p);
        },
      );
    }
    final primary = Theme.of(context).colorScheme.primary;
    return ListTile(
      onTap: () => setState(() => _adding = true),
      leading: Icon(Icons.person_add_alt_1_outlined, color: primary),
      title: Text('Add a contact', style: TextStyle(color: primary)),
      subtitle: const Text('Spouse, family member, who pays, …'),
    );
  }
}

/// Suggested contact labels.
const contactLabelSuggestions = [
  'Primary',
  'Spouse',
  'Partner',
  'Family',
  'Pays',
  'Property manager',
];

/// Name, label, phone and email for a contact.
class _ContactEditor extends StatefulWidget {
  const _ContactEditor({
    required this.onSave,
    required this.onCancel,
    this.onRemove,
    this.initial,
  });

  final ClientContact? initial;
  final Future<void> Function(ClientContact contact) onSave;
  final VoidCallback onCancel;
  final Future<void> Function()? onRemove;

  @override
  State<_ContactEditor> createState() => _ContactEditorState();
}

class _ContactEditorState extends State<_ContactEditor> {
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late final _phone = TextEditingController(text: widget.initial?.phone ?? '');
  late final _email = TextEditingController(text: widget.initial?.email ?? '');
  late final _label = TextEditingController(text: widget.initial?.label ?? '');
  late bool _signs = widget.initial?.signsPolicies ?? false;
  String? _emailError;

  @override
  void dispose() {
    _label.dispose();
    _name.dispose();
    _phone.dispose();
    _email.dispose();
    super.dispose();
  }

  void _save() {
    final email = _email.text.trim();
    final error = _checkEmail(email);
    if (error != null) {
      setState(() => _emailError = error);
      return;
    }
    final name = _name.text.trim();
    final phone = _phone.text.trim();
    final label = _label.text.trim();
    widget.onSave(
      widget.initial?.copyWith(
            name: name,
            phone: phone,
            email: email,
            label: label,
            signsPolicies: _signs,
          ) ??
          ClientContact(
            id: _uuid.v4(),
            name: name,
            phone: phone,
            email: email,
            label: label,
            signsPolicies: _signs,
          ),
    );
  }

  Future<void> _confirmRemove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove "${widget.initial!.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) await widget.onRemove!();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _name,
            autofocus: widget.initial == null,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Contact name',
              prefixIcon: Icon(Icons.person_outline),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _label,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Label (optional)',
              hintText: 'e.g. Spouse, Pays',
              prefixIcon: Icon(Icons.label_outline),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final l in contactLabelSuggestions)
                ActionChip(
                  label: Text(l),
                  onPressed: () => setState(() => _label.text = l),
                ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            inputFormatters: [_phoneChars],
            decoration: const InputDecoration(
              labelText: 'Phone (optional)',
              prefixIcon: Icon(Icons.phone_outlined),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: 'Email (optional)',
              prefixIcon: const Icon(Icons.email_outlined),
              errorText: _emailError,
            ),
            onChanged: (_) {
              if (_emailError != null) setState(() => _emailError = null);
            },
          ),
          CheckboxListTile(
            value: _signs,
            onChanged: (v) => setState(() => _signs = v ?? false),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Needs to sign policies'),
            subtitle: const Text(
              'The client is marked signed once everyone checked has '
              'signed a policies form.',
            ),
          ),
          Row(
            children: [
              if (widget.onRemove != null)
                IconButton(
                  tooltip: 'Remove this contact',
                  color: scheme.error,
                  onPressed: _confirmRemove,
                  icon: const Icon(Icons.delete_outline),
                ),
              const Spacer(),
              TextButton(
                onPressed: widget.onCancel,
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _name.text.trim().isEmpty ? null : _save,
                child: Text(widget.initial == null ? 'Add' : 'Save'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// What an address is called on screen: its label, or "Address".
String addressTitle(ClientLocation l) => l.label.isEmpty ? 'Address' : l.label;

/// One of the client's addresses (all equal). Tap to rename, move or
/// remove it ([onRemove] is null for the only address).
class _LocationRow extends StatefulWidget {
  const _LocationRow({
    super.key,
    required this.location,
    required this.onSave,
    required this.onRemove,
  });

  final ClientLocation location;
  final Future<void> Function(ClientLocation updated) onSave;
  final Future<void> Function()? onRemove;

  @override
  State<_LocationRow> createState() => _LocationRowState();
}

class _LocationRowState extends State<_LocationRow> {
  bool _editing = false;

  @override
  Widget build(BuildContext context) {
    final l = widget.location;
    if (_editing) {
      return _LocationEditor(
        initial: l,
        onCancel: () => setState(() => _editing = false),
        onSave: (label, place) async {
          setState(() => _editing = false);
          await widget.onSave(l.copyWith(label: label, place: place));
        },
        onRemove: widget.onRemove == null
            ? null
            : () async {
                setState(() => _editing = false);
                await widget.onRemove!();
              },
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final verified = l.placeId != null;
    return ListTile(
      onTap: () => setState(() => _editing = true),
      leading: Icon(
        verified ? Icons.place_outlined : Icons.warning_amber,
        color: verified ? null : scheme.error,
      ),
      title: Text(addressTitle(l)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.address),
          if (!verified)
            Text(
              'Not verified. Tap to pick it from Google Maps.',
              style: TextStyle(color: scheme.error),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Directions to ${addressTitle(l)}',
            icon: const Icon(Icons.directions_outlined),
            onPressed: () =>
                openClientLink(context, directionsUri(l.address, l.placeId)),
          ),
          IconButton(
            tooltip: 'Edit ${addressTitle(l)}',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => setState(() => _editing = true),
          ),
        ],
      ),
    );
  }
}

/// "Add another address" button, which opens an empty editor.
class _AddLocation extends StatefulWidget {
  const _AddLocation({super.key, required this.onAdd});

  final Future<void> Function(String label, Place place) onAdd;

  @override
  State<_AddLocation> createState() => _AddLocationState();
}

class _AddLocationState extends State<_AddLocation> {
  bool _adding = false;

  @override
  Widget build(BuildContext context) {
    if (_adding) {
      return _LocationEditor(
        onCancel: () => setState(() => _adding = false),
        onSave: (label, place) async {
          setState(() => _adding = false);
          await widget.onAdd(label, place);
        },
      );
    }
    return ListTile(
      onTap: () => setState(() => _adding = true),
      leading: Icon(
        Icons.add_location_alt_outlined,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: Text(
        'Add an address',
        style: TextStyle(color: Theme.of(context).colorScheme.primary),
      ),
      subtitle: const Text('Second home, storage unit, …'),
    );
  }
}

/// Name (optional) and Google-picked address for one of the client's
/// addresses. [initial] is set when editing an existing one.
class _LocationEditor extends StatefulWidget {
  const _LocationEditor({
    required this.onSave,
    required this.onCancel,
    this.onRemove,
    this.initial,
  });

  final ClientLocation? initial;
  final Future<void> Function(String label, Place place) onSave;
  final VoidCallback onCancel;
  final Future<void> Function()? onRemove;

  @override
  State<_LocationEditor> createState() => _LocationEditorState();
}

class _LocationEditorState extends State<_LocationEditor> {
  late final _label = TextEditingController(text: widget.initial?.label ?? '');
  // An address not picked from Google Maps has to be picked again.
  late Place? _picked = widget.initial?.placeId == null
      ? null
      : Place(
          label: widget.initial!.label,
          address: widget.initial!.address,
          placeId: widget.initial!.placeId,
          lat: widget.initial!.lat,
          lng: widget.initial!.lng,
        );

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  bool get _ready => _picked != null;

  Future<void> _confirmRemove() async {
    final name = addressTitle(widget.initial!);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove "$name"?'),
        content: const Text('Trips already logged there are kept.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) await widget.onRemove!();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _label,
            autofocus: widget.initial == null,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'What is this place? (optional)',
              hintText: 'e.g. Home, Storage unit',
              prefixIcon: Icon(Icons.label_outline),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final s in locationLabelSuggestions)
                ActionChip(
                  label: Text(s),
                  onPressed: () => setState(() => _label.text = s),
                ),
            ],
          ),
          const SizedBox(height: 12),
          AddressSearchField(
            labelText: 'Address',
            initialText: _picked?.address ?? widget.initial?.address ?? '',
            onPicked: (place, _) async => setState(() => _picked = place),
            onEdited: () => setState(() => _picked = null),
          ),
          if (_picked != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.verified, size: 18, color: scheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _picked!.address,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 4),
          Row(
            children: [
              if (widget.onRemove != null)
                IconButton(
                  tooltip: 'Remove this address',
                  color: scheme.error,
                  onPressed: _confirmRemove,
                  icon: const Icon(Icons.delete_outline),
                ),
              const Spacer(),
              TextButton(
                onPressed: widget.onCancel,
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _ready
                    ? () => widget.onSave(_label.text.trim(), _picked!)
                    : null,
                child: Text(widget.initial == null ? 'Add' : 'Save'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The client's sessions: booked ahead, running now, and done. Each shows
/// the time with the client, what it bills, and whether it's been billed
/// and paid (clients pre-pay, so upcoming sessions can be paid too).
class _JobsSection extends StatefulWidget {
  const _JobsSection({
    required this.client,
    required this.entries,
    required this.now,
    required this.onSave,
  });

  final SavedAddress client;
  final List<ClientJobEntry> entries;
  final DateTime now;
  final Future<void> Function(SavedAddress Function(SavedAddress c) edit)
  onSave;

  @override
  State<_JobsSection> createState() => _JobsSectionState();
}

class _JobsSectionState extends State<_JobsSection> {
  static const _preview = 5;
  bool _allCompleted = false;

  static String _miles(double m) => '${m.toStringAsFixed(1)} mi';

  Future<void> _schedule([ScheduledJob? existing]) async {
    final result = await showBookingDialog(
      context,
      existing: existing,
      now: widget.now,
      hourlyRate: widget.client.hourlyRate,
    );
    if (result == null) return;
    await widget.onSave((c) {
      final rest = [
        for (final s in c.scheduled)
          if (s.id != existing?.id) s,
      ];
      if (result.delete) {
        return c.copyWith(
          scheduled: rest,
          billing: {
            for (final e in c.billing.entries)
              if (e.key != existing?.id) e.key: e.value,
          },
        );
      }
      return c.copyWith(
        scheduled: [
          ...rest,
          existing?.copyWith(
                start: result.start,
                end: result.end,
                notes: result.notes,
              ) ??
              ScheduledJob(
                id: _uuid.v4(),
                start: result.start!,
                end: result.end,
                notes: result.notes,
              ),
        ]..sort((a, b) => a.start.compareTo(b.start)),
      );
    });
  }

  Future<void> _setBilling(ClientJobEntry e) async {
    final current = billingFor(widget.client, e);
    final picked = await showDialog<SessionBilling>(
      context: context,
      builder: (_) => _BillingDialog(
        initial: current,
        amount: sessionAmount(widget.client, e),
      ),
    );
    if (picked == null || picked == current) return;
    await widget.onSave((c) => withBilling(c, e, picked));
  }

  /// "3 h 30 m with the client · $262.50".
  String _timeAndAmount(ClientJobEntry e, {bool soFar = false}) {
    final t = e.time;
    final amount = sessionAmount(widget.client, e);
    return [
      if (t != null)
        '${formatHours(t)} with the client${soFar ? ' so far' : ''}',
      if (amount != null) formatDollars(amount),
    ].join(' · ');
  }

  Widget _tile(
    ClientJobEntry e, {
    required Widget leading,
    required String title,
    required List<String> lines,
    VoidCallback? onTap,
  }) => ListTile(
    leading: leading,
    title: Text(title),
    subtitle: _lines(lines),
    trailing: _BillingChip(
      billing: billingFor(widget.client, e),
      onTap: () => _setBilling(e),
    ),
    onTap: onTap ?? () => _setBilling(e),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    List<ClientJobEntry> inState(ClientJobState s) => [
      for (final e in widget.entries)
        if (e.state == s) e,
    ];
    final upcoming = inState(ClientJobState.upcoming);
    final running = inState(ClientJobState.inProgress);
    final completed = inState(ClientJobState.completed);
    final year = widget.now.year;
    final doneThisYear = completed.where(
      (e) => e.start.year == year && !e.noTrips,
    );
    final hours = doneThisYear.fold(
      Duration.zero,
      (sum, e) => sum + (e.time ?? Duration.zero),
    );

    // Money by billing status, across every session.
    double total(Iterable<ClientJobEntry> es) => es.fold<double>(
      0,
      (sum, e) => sum + (sessionAmount(widget.client, e) ?? 0),
    );
    Iterable<ClientJobEntry> withStatus(BillingStatus s) =>
        widget.entries.where((e) => billingFor(widget.client, e).status == s);
    final paidThisYear = total(
      withStatus(BillingStatus.paid).where((e) => e.start.year == year),
    );
    final toBill = withStatus(BillingStatus.needToBill).toList();
    final awaiting = withStatus(BillingStatus.billed).toList();

    Widget group(String title, List<Widget> rows) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(title, style: theme.textTheme.titleSmall),
        ),
        ...rows,
      ],
    );

    final shownCompleted = _allCompleted
        ? completed
        : completed.take(_preview).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: _SectionTitle('Sessions')),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextButton.icon(
                onPressed: _schedule,
                icon: const Icon(Icons.event_available_outlined),
                label: const Text('Schedule a session'),
              ),
            ),
          ],
        ),
        Card.outlined(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: widget.entries.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'No sessions yet. Schedule one here, or just go: arriving '
                    'at their address starts a session.',
                    style: muted,
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Row(
                        children: [
                          _Stat('${doneThisYear.length}', 'sessions in $year'),
                          _Stat(formatHours(hours), 'with the client'),
                          _Stat(formatDollars(paidThisYear), 'paid in $year'),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Text(
                        [
                          toBill.isEmpty
                              ? 'Nothing to bill'
                              : '${toBill.length} to bill · '
                                    '${formatDollars(total(toBill))}',
                          if (awaiting.isNotEmpty)
                            '${awaiting.length} billed, not paid · '
                                '${formatDollars(total(awaiting))}',
                        ].join('   ·   '),
                        style: muted,
                      ),
                    ),
                    if (upcoming.isNotEmpty) ...[
                      const Divider(height: 1),
                      group('Upcoming', [
                        for (final e in upcoming)
                          _tile(
                            e,
                            leading: const Icon(Icons.event_outlined),
                            title: _booked(e.scheduled!),
                            lines: [
                              e.scheduled!.end == null
                                  ? 'No end time'
                                  : _timeAndAmount(e),
                              e.scheduled!.notes,
                            ],
                            onTap: () => _schedule(e.scheduled),
                          ),
                      ]),
                    ],
                    if (running.isNotEmpty) ...[
                      const Divider(height: 1),
                      group('In progress', [
                        for (final e in running)
                          _tile(
                            e,
                            leading: Icon(
                              Icons.work,
                              color: theme.colorScheme.primary,
                            ),
                            title: 'Since ${formatClock(e.start)}',
                            lines: [
                              _timeAndAmount(e, soFar: true),
                              _extras(e).join(' · '),
                            ],
                          ),
                      ]),
                    ],
                    if (completed.isNotEmpty) ...[
                      const Divider(height: 1),
                      group('Completed', [
                        for (final e in shownCompleted) _completedTile(e),
                        if (completed.length > _preview)
                          TextButton(
                            onPressed: () =>
                                setState(() => _allCompleted = !_allCompleted),
                            child: Text(
                              _allCompleted
                                  ? 'Show fewer'
                                  : 'Show all ${completed.length}',
                            ),
                          ),
                      ]),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  /// Non-empty [lines], one under the other; null if none.
  static Widget? _lines(List<String> lines) {
    final shown = lines.where((l) => l.isNotEmpty).toList();
    return shown.isEmpty ? null : Text(shown.join('\n'));
  }

  /// Other addresses and other clients visited in the same session.
  List<String> _extras(ClientJobEntry e) => [
    if (e.places.isNotEmpty) 'at ${e.places.join(', ')}',
    if (e.otherClients.isNotEmpty) 'also ${e.otherClients.join(', ')}',
  ];

  Widget _completedTile(ClientJobEntry e) {
    final String title;
    final List<String> lines;
    if (e.noTrips) {
      title = _booked(e.scheduled!);
      lines = [_timeAndAmount(e), 'Booked · no trips recorded'];
    } else if (!e.timeTracked) {
      title = formatShortDate(e.start);
      lines = [
        e.scheduled?.end != null ? _timeAndAmount(e) : 'Time not tracked',
        [_miles(e.miles), ..._extras(e)].join(' · '),
      ];
    } else {
      title =
          '${formatShortDate(e.start)} · ${formatClock(e.start)} – '
          '${formatClock(e.end!)}';
      lines = [
        _timeAndAmount(e),
        [
          if (e.miles > 0) '${_miles(e.miles)} between clients',
          ..._extras(e),
        ].join(' · '),
        if (e.scheduled?.end != null)
          'Booked ${formatClock(e.scheduled!.start)} – '
              '${formatClock(e.scheduled!.end!)}',
      ];
    }
    return _tile(
      e,
      leading: Icon(
        e.noTrips ? Icons.event_busy_outlined : Icons.check_circle_outline,
      ),
      title: title,
      lines: [...lines, e.scheduled?.notes ?? ''],
      onTap: e.scheduled != null && e.noTrips
          ? () => _schedule(e.scheduled)
          : null,
    );
  }

  /// "Tue 11/18/26 · 9:30 AM – 12:30 PM".
  static String _booked(ScheduledJob s) {
    final end = s.end == null ? '' : ' – ${formatClock(s.end!)}';
    return '${_when(s.start)}$end';
  }

  /// "Tue 11/18/26 · 9:30 AM".
  static String _when(DateTime d) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return '${days[d.weekday - 1]} ${formatShortDate(d)} · ${formatClock(d)}';
  }
}

/// Colors for each billing status.
({Color bg, Color fg}) billingColors(BillingStatus s, ColorScheme scheme) =>
    switch (s) {
      BillingStatus.needToBill => (
        bg: scheme.errorContainer,
        fg: scheme.onErrorContainer,
      ),
      BillingStatus.billed => (
        bg: scheme.tertiaryContainer,
        fg: scheme.onTertiaryContainer,
      ),
      BillingStatus.paid => (
        bg: scheme.primaryContainer,
        fg: scheme.onPrimaryContainer,
      ),
    };

/// "Need to bill", "Billed", or "Paid · Venmo"; tap to change.
class _BillingChip extends StatelessWidget {
  const _BillingChip({required this.billing, required this.onTap});

  final SessionBilling billing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = billingColors(billing.status, theme.colorScheme);
    final method = billing.status == BillingStatus.paid ? billing.method : null;
    return Tooltip(
      message: 'Billing',
      child: Material(
        color: c.bg,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  billing.status.label,
                  style: theme.textTheme.labelMedium?.copyWith(color: c.fg),
                ),
                if (method != null)
                  Text(
                    method.label,
                    style: theme.textTheme.labelSmall?.copyWith(color: c.fg),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Set a session's billing status, and how it was paid.
class _BillingDialog extends StatefulWidget {
  const _BillingDialog({required this.initial, required this.amount});

  final SessionBilling initial;
  final double? amount;

  @override
  State<_BillingDialog> createState() => _BillingDialogState();
}

class _BillingDialogState extends State<_BillingDialog> {
  late BillingStatus _status = widget.initial.status;
  late PaymentDetails _paid = (
    method: widget.initial.method,
    date: widget.initial.paidOn ?? DateTime.now(),
    amount: widget.initial.amount ?? widget.amount,
  );

  bool get _ready =>
      _status != BillingStatus.paid ||
      (_paid.method != null && _paid.amount != null);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Text(
        widget.amount == null
            ? 'Billing'
            : 'Billing · ${formatDollars(widget.amount!)}',
      ),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<BillingStatus>(
                segments: [
                  for (final s in BillingStatus.values)
                    ButtonSegment(value: s, label: Text(s.label)),
                ],
                selected: {_status},
                showSelectedIcon: false,
                onSelectionChanged: (v) => setState(() => _status = v.first),
              ),
              if (_status == BillingStatus.paid) ...[
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
          // Paid needs a payment method and amount.
          onPressed: !_ready
              ? null
              : () => Navigator.of(context).pop(
                  _status == BillingStatus.paid
                      ? SessionBilling(
                          status: _status,
                          method: _paid.method,
                          paidOn: DateTime(
                            _paid.date.year,
                            _paid.date.month,
                            _paid.date.day,
                          ),
                          amount: _paid.amount,
                          // Still the Stripe payment it was matched to.
                          stripeId: widget.initial.stripeId,
                        )
                      : SessionBilling(status: _status),
                ),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.value, this.label);
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: theme.textTheme.titleLarge),
          Text(label, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// Book a session for a client (or edit [existing]): day, start and end
/// time, notes. [initialStart] picks the time (e.g. a free spot tapped on
/// the calendar); [clientName] shows whose session it is.
Future<BookingResult?> showBookingDialog(
  BuildContext context, {
  ScheduledJob? existing,
  required DateTime now,
  required double hourlyRate,
  DateTime? initialStart,
  String? clientName,
}) => showDialog<BookingResult>(
  context: context,
  builder: (_) => _BookingDialog(
    existing: existing,
    now: now,
    hourlyRate: hourlyRate,
    initialStart: initialStart,
    clientName: clientName,
  ),
);

typedef BookingResult = ({
  DateTime? start,
  DateTime? end,
  String notes,
  bool delete,
});

/// Book (or move, or cancel) a session: day, start and end time, and
/// notes. Shows what it bills at the client's rate.
class _BookingDialog extends StatefulWidget {
  const _BookingDialog({
    required this.existing,
    required this.now,
    required this.hourlyRate,
    this.initialStart,
    this.clientName,
  });

  final DateTime? initialStart;
  final String? clientName;
  final ScheduledJob? existing;
  final DateTime now;
  final double hourlyRate;

  @override
  State<_BookingDialog> createState() => _BookingDialogState();
}

class _BookingDialogState extends State<_BookingDialog> {
  /// Length of a new booking until an end time is picked.
  static const _defaultLength = Duration(hours: 3);

  late DateTime _day = () {
    final s = widget.existing?.start ?? widget.initialStart;
    if (s != null) return DateTime(s.year, s.month, s.day);
    final tomorrow = widget.now.add(const Duration(days: 1));
    return DateTime(tomorrow.year, tomorrow.month, tomorrow.day);
  }();
  late TimeOfDay _start = widget.existing != null
      ? TimeOfDay.fromDateTime(widget.existing!.start)
      : widget.initialStart != null
      ? TimeOfDay.fromDateTime(widget.initialStart!)
      : const TimeOfDay(hour: 9, minute: 0);
  late TimeOfDay _end = () {
    final e = widget.existing?.end;
    if (e != null) return TimeOfDay.fromDateTime(e);
    final s = DateTime(2000, 1, 1, _start.hour, _start.minute);
    return TimeOfDay.fromDateTime(s.add(_defaultLength));
  }();
  late final _notes = TextEditingController(text: widget.existing?.notes ?? '');

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  DateTime _at(TimeOfDay t) =>
      DateTime(_day.year, _day.month, _day.day, t.hour, t.minute);

  bool get _valid => _at(_end).isAfter(_at(_start));

  Future<void> _pickDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2000),
      lastDate: DateTime(widget.now.year + 5),
    );
    if (picked != null) setState(() => _day = picked);
  }

  Future<void> _pickStart() async {
    final picked = await showTimePicker(context: context, initialTime: _start);
    if (picked == null) return;
    setState(() {
      // Moving the start keeps the length.
      final length = _valid
          ? _at(_end).difference(_at(_start))
          : _defaultLength;
      _start = picked;
      _end = TimeOfDay.fromDateTime(_at(picked).add(length));
    });
  }

  Future<void> _pickEnd() async {
    final picked = await showTimePicker(context: context, initialTime: _end);
    if (picked != null) setState(() => _end = picked);
  }

  void _save() => Navigator.of(context).pop((
    start: _at(_start),
    end: _at(_end),
    notes: _notes.text.trim(),
    delete: false,
  ));

  @override
  Widget build(BuildContext context) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final theme = Theme.of(context);
    final length = _at(_end).difference(_at(_start));
    final bill =
        (length.inMinutes / 60 * widget.hourlyRate * 100).round() / 100;
    return AlertDialog(
      title: Text(
        [
          widget.existing == null ? 'Schedule a session' : 'Edit session',
          if (widget.clientName != null) widget.clientName!,
        ].join(' · '),
      ),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.calendar_today_outlined),
              title: Text('${days[_day.weekday - 1]} ${formatShortDate(_day)}'),
              subtitle: const Text('Day'),
              onTap: _pickDay,
            ),
            Row(
              children: [
                Expanded(
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.schedule),
                    title: Text(formatClock(_at(_start))),
                    subtitle: const Text('Start time'),
                    onTap: _pickStart,
                  ),
                ),
                Expanded(
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.schedule_outlined),
                    title: Text(formatClock(_at(_end))),
                    subtitle: const Text('End time'),
                    onTap: _pickEnd,
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _valid
                    ? '${formatHours(length)} at '
                          '${formatDollars(widget.hourlyRate)}/hour = '
                          '${formatDollars(bill)}'
                    : 'The end time must be after the start time.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: _valid
                      ? theme.colorScheme.primary
                      : theme.colorScheme.error,
                ),
              ),
            ),
            TextField(
              controller: _notes,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Notes (optional)',
                hintText: 'e.g. Garage clean-out, bring bins',
              ),
              maxLines: 2,
              minLines: 1,
            ),
          ],
        ),
      ),
      actions: [
        if (widget.existing != null)
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
            onPressed: () =>
                Navigator.of(context)
                    .pop((start: null, end: null, notes: '', delete: true)),
            child: const Text('Cancel session'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton(
          onPressed: _valid ? _save : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
