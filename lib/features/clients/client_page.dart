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
import '../../services/client_jobs.dart';
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
  'Second home',
  'Vacation home',
  'Storage unit',
  'Office',
];

String clientInitials(String name) {
  final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  return words.take(2).map((w) => w[0].toUpperCase()).join();
}

/// One client's page: how to reach them, their details (tap any to edit)
/// and the trips logged to their address.
class ClientPage extends ConsumerWidget {
  const ClientPage({super.key, required this.clientId});

  final String clientId;

  Future<void> _save(WidgetRef ref, SavedAddress updated) =>
      ref.read(addressesProvider.notifier).replace(updated);

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    SavedAddress c,
  ) async {
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
    if (ok != true || !context.mounted) return;
    Navigator.of(context).pop();
    await ref.read(addressesProvider.notifier).remove(c.id);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref
        .watch(addressesProvider)
        .where((c) => c.id == clientId)
        .firstOrNull;
    if (client == null) {
      // Deleted (possibly on the other device) while open.
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('This client was deleted.')),
      );
    }
    final c = client;
    final now = ref.read(clockProvider)();
    final jobs = clientJobs(
      client: c,
      jobs: ref.watch(allJobSummariesProvider),
      trips: ref.watch(tripsProvider),
      now: now,
    );

    Future<void> saveLocations(List<ClientLocation> next) =>
        _save(ref, c.copyWith(locations: next));

    return Scaffold(
      appBar: AppBar(
        title: Text(c.name),
        actions: [
          IconButton(
            tooltip: 'Delete client',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _delete(context, ref, c),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _Header(client: c),
              const SizedBox(height: 16),
              _ContactButtons(client: c),
              const SizedBox(height: 24),
              _SectionTitle('Status'),
              _StatusCard(
                client: c,
                today: ref.read(clockProvider)(),
                onSave: (updated) => _save(ref, updated),
              ),
              const SizedBox(height: 24),
              _SectionTitle('Policy doc'),
              _PolicyDocCard(
                client: c,
                today: ref.read(clockProvider)(),
                onSave: (updated) => _save(ref, updated),
              ),
              const SizedBox(height: 24),
              _SectionTitle('Details'),
              Card.outlined(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    _EditableText(
                      key: ValueKey('name-${c.id}'),
                      label: 'Name',
                      icon: Icons.person_outline,
                      value: c.name,
                      capitalization: TextCapitalization.words,
                      validate: (v) => v.isEmpty ? 'Required' : null,
                      onSave: (v) => _save(ref, c.copyWith(name: v)),
                    ),
                    const Divider(height: 1),
                    _EditableText(
                      key: ValueKey('phone-${c.id}'),
                      label: 'Phone',
                      icon: Icons.phone_outlined,
                      value: c.phone,
                      placeholder: 'Add a phone number',
                      keyboardType: TextInputType.phone,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                          RegExp(r'[0-9+()\-. x]'),
                        ),
                      ],
                      onSave: (v) => _save(ref, c.copyWith(phone: v)),
                    ),
                    const Divider(height: 1),
                    _EditableText(
                      key: ValueKey('email-${c.id}'),
                      label: 'Email',
                      icon: Icons.email_outlined,
                      value: c.email,
                      placeholder: 'Add an email address',
                      keyboardType: TextInputType.emailAddress,
                      validate: (v) => v.isNotEmpty && !looksLikeEmail(v)
                          ? 'Check the email address'
                          : null,
                      onSave: (v) => _save(ref, c.copyWith(email: v)),
                    ),
                    const Divider(height: 1),
                    _EditableText(
                      key: ValueKey('rate-${c.id}'),
                      label: 'Hourly rate',
                      icon: Icons.attach_money,
                      value: rateText(c.hourlyRate),
                      display: (v) => '${formatDollars(c.hourlyRate)} per hour',
                      prefixText: '\$ ',
                      suffixText: '/ hour',
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.,$]')),
                      ],
                      validate: (v) =>
                          parseRate(v) == null ? 'Enter an amount' : null,
                      onSave: (v) =>
                          _save(ref, c.copyWith(hourlyRate: parseRate(v))),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              _SectionTitle('Addresses'),
              Card.outlined(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    _EditableAddress(
                      key: ValueKey('address-${c.id}'),
                      client: c,
                      onSave: (p) => _save(
                        ref,
                        c.copyWith(
                          address: p.address,
                          placeId: p.placeId,
                          lat: p.lat,
                          lng: p.lng,
                        ),
                      ),
                    ),
                    for (final l in c.locations) ...[
                      const Divider(height: 1),
                      _LocationRow(
                        key: ValueKey('location-${l.id}'),
                        location: l,
                        onSave: (updated) => saveLocations([
                          for (final x in c.locations)
                            x.id == l.id ? updated : x,
                        ]),
                        onRemove: () => saveLocations([
                          for (final x in c.locations)
                            if (x.id != l.id) x,
                        ]),
                      ),
                    ],
                    const Divider(height: 1),
                    _AddLocation(
                      key: ValueKey('add-location-${c.id}'),
                      onAdd: (label, place) => saveLocations([
                        ...c.locations,
                        ClientLocation(
                          id: _uuid.v4(),
                          label: label,
                          address: place.address,
                          placeId: place.placeId,
                          lat: place.lat,
                          lng: place.lng,
                        ),
                      ]),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              _JobsSection(
                client: c,
                entries: jobs,
                now: now,
                onSave: (updated) => _save(ref, updated),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.client});
  final SavedAddress client;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      children: [
        CircleAvatar(
          radius: 40,
          backgroundColor: client.isVerified
              ? scheme.primaryContainer
              : scheme.errorContainer,
          child: client.isVerified
              ? Text(
                  clientInitials(client.name),
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: scheme.onPrimaryContainer,
                  ),
                )
              : Icon(Icons.warning_amber, size: 36, color: scheme.error),
        ),
        const SizedBox(height: 12),
        Text(
          client.name,
          style: theme.textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
        ClientStatusBadge(client: client),
        const SizedBox(height: 6),
        Text(
          client.address,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
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

  @override
  Widget build(BuildContext context) {
    final c = client;
    Widget button(IconData icon, String label, Uri? uri) => Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: FilledButton.tonal(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          onPressed: uri == null ? null : () => openClientLink(context, uri),
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
          directionsUri(c.address, c.placeId),
        ),
      ],
    );
  }
}

/// Where the client is (new → consultation → policy doc → active), with a
/// button for the next step and a menu to set any status. Changing the
/// status never asks for a date; the signed date lives in the Policy doc
/// section.
class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.client,
    required this.today,
    required this.onSave,
  });

  final SavedAddress client;
  final DateTime today;
  final Future<void> Function(SavedAddress updated) onSave;

  Future<void> _moveTo(ClientStatus next) {
    final c = client;
    // Finishing the consultation records its day (today).
    final consultationDone =
        c.status == ClientStatus.consultation &&
        next == ClientStatus.policyDoc &&
        c.consultationOn == null;
    return onSave(
      c.copyWith(
        status: next,
        consultationOn: consultationDone
            ? DateTime(today.year, today.month, today.day)
            : null,
      ),
    );
  }

  /// Back from the archive to where the client left off.
  ClientStatus get _restoreTo => client.policiesSignedOn != null
      ? ClientStatus.active
      : client.consultationOn != null
      ? ClientStatus.policyDoc
      : ClientStatus.newClient;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = client;
    final status = c.status;
    final colors = statusColors(status, theme.colorScheme);

    final (
      String detail,
      String? action,
      ClientStatus? next,
    ) = switch (status) {
      ClientStatus.newClient => (
        'Next: book the free 30-minute consultation',
        'Consultation booked',
        ClientStatus.consultation,
      ),
      ClientStatus.consultation => (
        'Free 30-minute consultation, in person',
        'Consultation done',
        ClientStatus.policyDoc,
      ),
      ClientStatus.policyDoc => (
        [
          if (c.consultationOn != null)
            'Consultation ${formatShortDate(c.consultationOn!)}',
          'Mark the policy doc signed below to make them active',
        ].join(' · '),
        null,
        null,
      ),
      ClientStatus.active => ('Current client', null, null),
      ClientStatus.archived => (
        'Not a current client. Trips there aren\'t treated as client '
            'visits.',
        'Restore',
        _restoreTo,
      ),
    };

    return Card.filled(
      color: colors.bg,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
        child: Row(
          children: [
            Icon(statusIcon(status), color: colors.fg),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    status.label,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: colors.fg,
                    ),
                  ),
                  Text(detail, style: TextStyle(color: colors.fg)),
                  if (action != null && next != null) ...[
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: () => _moveTo(next),
                      child: Text(action),
                    ),
                  ],
                ],
              ),
            ),
            PopupMenuButton<ClientStatus>(
              tooltip: 'Change status',
              iconColor: colors.fg,
              onSelected: _moveTo,
              itemBuilder: (_) => [
                for (final s in ClientStatus.values)
                  if (s != status)
                    PopupMenuItem(
                      value: s,
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(statusIcon(s)),
                        title: Text(
                          s == ClientStatus.archived
                              ? 'Archive'
                              : 'Set to ${s.label}',
                        ),
                      ),
                    ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Whether (and when) the client signed the policies document. Marking it
/// signed makes the client active; marking it not signed puts an active
/// client back to waiting on the policy doc. Archived clients stay
/// archived.
class _PolicyDocCard extends StatelessWidget {
  const _PolicyDocCard({
    required this.client,
    required this.today,
    required this.onSave,
  });

  final SavedAddress client;
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final signed = client.policiesSignedOn;
    if (signed == null) {
      return Card.outlined(
        margin: EdgeInsets.zero,
        child: ListTile(
          leading: const Icon(Icons.edit_document),
          title: const Text('Not signed yet'),
          subtitle: Text(
            _archived
                ? 'Signing won\'t change the archived status.'
                : 'Signing makes the client active.',
          ),
          trailing: FilledButton(
            onPressed: () => _pickSignedDay(context),
            child: const Text('Mark signed'),
          ),
        ),
      );
    }
    return Card.outlined(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: () => _pickSignedDay(context),
        leading: Icon(Icons.verified_outlined, color: scheme.primary),
        title: Text('Signed ${formatShortDate(signed)}'),
        subtitle: const Text('Tap to change the date'),
        trailing: PopupMenuButton<String>(
          tooltip: 'Policy doc options',
          onSelected: (choice) {
            if (choice == 'date') _pickSignedDay(context);
            if (choice == 'unsign') _unsign();
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'date', child: Text('Change signed date')),
            PopupMenuItem(value: 'unsign', child: Text('Mark as not signed')),
          ],
        ),
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
    this.placeholder,
    this.validate,
    this.keyboardType,
    this.inputFormatters,
    this.capitalization = TextCapitalization.none,
    this.display,
    this.prefixText,
    this.suffixText,
  });

  final String label;
  final IconData icon;
  final String value;
  final String? placeholder;
  final String? Function(String value)? validate;
  final Future<void> Function(String value) onSave;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final TextCapitalization capitalization;

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
            textCapitalization: widget.capitalization,
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
        empty
            ? (widget.placeholder ?? '')
            : widget.display?.call(widget.value) ?? widget.value,
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

/// The client's address; editing means picking a new one from Google Maps.
class _EditableAddress extends StatefulWidget {
  const _EditableAddress({
    super.key,
    required this.client,
    required this.onSave,
  });

  final SavedAddress client;
  final Future<void> Function(Place place) onSave;

  @override
  State<_EditableAddress> createState() => _EditableAddressState();
}

class _EditableAddressState extends State<_EditableAddress> {
  bool _editing = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = widget.client;
    if (_editing) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AddressSearchField(
              labelText: 'New address',
              autofocus: true,
              onPicked: (place, _) async {
                setState(() => _editing = false);
                await widget.onSave(place);
              },
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => setState(() => _editing = false),
                child: const Text('Cancel'),
              ),
            ),
          ],
        ),
      );
    }
    return ListTile(
      onTap: () => setState(() => _editing = true),
      leading: Icon(
        c.isVerified ? Icons.place_outlined : Icons.warning_amber,
        color: c.isVerified ? null : scheme.error,
      ),
      title: const Text('Main address'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(c.address),
          if (!c.isVerified)
            Text(
              'Not verified. Tap to pick it from Google Maps.',
              style: TextStyle(color: scheme.error),
            ),
        ],
      ),
      trailing: IconButton(
        tooltip: 'Edit main address',
        icon: const Icon(Icons.edit_outlined),
        onPressed: () => setState(() => _editing = true),
      ),
    );
  }
}

/// One of the client's other addresses. Tap to rename, move or remove it.
class _LocationRow extends StatefulWidget {
  const _LocationRow({
    super.key,
    required this.location,
    required this.onSave,
    required this.onRemove,
  });

  final ClientLocation location;
  final Future<void> Function(ClientLocation updated) onSave;
  final Future<void> Function() onRemove;

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
        onRemove: () async {
          setState(() => _editing = false);
          await widget.onRemove();
        },
      );
    }
    return ListTile(
      onTap: () => setState(() => _editing = true),
      leading: const Icon(Icons.place_outlined),
      title: Text(l.label),
      subtitle: Text(l.address),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Directions to ${l.label}',
            icon: const Icon(Icons.directions_outlined),
            onPressed: () =>
                openClientLink(context, directionsUri(l.address, l.placeId)),
          ),
          IconButton(
            tooltip: 'Edit ${l.label}',
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
        'Add another address',
        style: TextStyle(color: Theme.of(context).colorScheme.primary),
      ),
      subtitle: const Text('Second home, storage unit, …'),
    );
  }
}

/// Name and Google-picked address for one of the client's other
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
  late Place? _picked = widget.initial == null
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

  bool get _ready => _label.text.trim().isNotEmpty && _picked != null;

  Future<void> _confirmRemove() async {
    final name = widget.initial!.label;
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
              labelText: 'What is this place?',
              hintText: 'e.g. Storage unit',
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
            initialText: _picked?.address ?? '',
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

/// The client's jobs: booked ahead, running now, and done. Booking a job
/// here makes it upcoming; the phone records it when you go.
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
  final Future<void> Function(SavedAddress updated) onSave;

  @override
  State<_JobsSection> createState() => _JobsSectionState();
}

class _JobsSectionState extends State<_JobsSection> {
  static const _preview = 5;
  bool _allCompleted = false;

  static String _miles(double m) => '${m.toStringAsFixed(1)} mi';

  Future<void> _schedule([ScheduledJob? existing]) async {
    final result = await showDialog<_BookingResult>(
      context: context,
      builder: (_) => _BookingDialog(existing: existing, now: widget.now),
    );
    if (result == null) return;
    final c = widget.client;
    final rest = [
      for (final s in c.scheduled)
        if (s.id != existing?.id) s,
    ];
    final next = result.delete
        ? rest
        : ([
            ...rest,
            existing?.copyWith(start: result.start, notes: result.notes) ??
                ScheduledJob(
                  id: _uuid.v4(),
                  start: result.start!,
                  notes: result.notes,
                ),
          ]..sort((a, b) => a.start.compareTo(b.start)));
    await widget.onSave(c.copyWith(scheduled: next));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final upcoming = [
      for (final e in widget.entries)
        if (e.state == ClientJobState.upcoming) e,
    ];
    final running = [
      for (final e in widget.entries)
        if (e.state == ClientJobState.inProgress) e,
    ];
    final completed = [
      for (final e in widget.entries)
        if (e.state == ClientJobState.completed) e,
    ];
    final year = widget.now.year;
    final doneThisYear = completed.where(
      (e) => e.start.year == year && !e.noTrips,
    );
    final hours = doneThisYear.fold(
      Duration.zero,
      (sum, e) => sum + (e.duration ?? Duration.zero),
    );
    final miles = doneThisYear.fold<double>(0, (sum, e) => sum + e.miles);

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
            Expanded(child: _SectionTitle('Jobs')),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextButton.icon(
                onPressed: _schedule,
                icon: const Icon(Icons.event_available_outlined),
                label: const Text('Schedule a job'),
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
                    'No jobs yet. Schedule one here, or just go: arriving at '
                    'their address starts a job.',
                    style: muted,
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Row(
                        children: [
                          _Stat('${doneThisYear.length}', 'jobs in $year'),
                          _Stat(formatHours(hours), 'on the job'),
                          _Stat(_miles(miles), 'driven'),
                        ],
                      ),
                    ),
                    if (upcoming.isNotEmpty) ...[
                      const Divider(height: 1),
                      group('Upcoming', [
                        for (final e in upcoming)
                          ListTile(
                            leading: const Icon(Icons.event_outlined),
                            title: Text(_when(e.start)),
                            subtitle: e.scheduled!.notes.isEmpty
                                ? null
                                : Text(e.scheduled!.notes),
                            trailing: const Icon(Icons.edit_outlined),
                            onTap: () => _schedule(e.scheduled),
                          ),
                      ]),
                    ],
                    if (running.isNotEmpty) ...[
                      const Divider(height: 1),
                      group('In progress', [
                        for (final e in running)
                          ListTile(
                            leading: Icon(
                              Icons.work,
                              color: theme.colorScheme.primary,
                            ),
                            title: Text('Since ${formatClock(e.start)}'),
                            subtitle: Text(
                              [
                                '${formatHours(widget.now.difference(e.start))} '
                                    'so far',
                                _miles(e.miles),
                                ..._extras(e),
                              ].join(' · '),
                            ),
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

  /// Other addresses and other clients visited in the same job.
  List<String> _extras(ClientJobEntry e) => [
    if (e.places.isNotEmpty) 'at ${e.places.join(', ')}',
    if (e.otherClients.isNotEmpty) 'also ${e.otherClients.join(', ')}',
  ];

  Widget _completedTile(ClientJobEntry e) {
    final String title;
    final List<String> details;
    if (e.noTrips) {
      title = _when(e.start);
      details = ['Scheduled · no trips recorded', e.scheduled!.notes];
    } else if (!e.timeTracked) {
      title = formatShortDate(e.start);
      details = ['${_miles(e.miles)} · time not tracked', ..._extras(e)];
    } else {
      title =
          '${formatShortDate(e.start)} · ${formatClock(e.start)} – '
          '${formatClock(e.end!)}';
      details = [_miles(e.miles), ..._extras(e)];
    }
    return ListTile(
      dense: true,
      leading: Icon(
        e.noTrips ? Icons.event_busy_outlined : Icons.check_circle_outline,
      ),
      title: Text(title),
      subtitle: Text(details.where((d) => d.isNotEmpty).join(' · ')),
      trailing: e.duration == null
          ? null
          : Text(
              formatHours(e.duration!),
              style: Theme.of(context).textTheme.bodyLarge,
            ),
      onTap: e.scheduled != null && e.noTrips
          ? () => _schedule(e.scheduled)
          : null,
    );
  }

  /// "Tue 11/18/26 · 9:30 AM".
  static String _when(DateTime d) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return '${days[d.weekday - 1]} ${formatShortDate(d)} · ${formatClock(d)}';
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
        children: [
          Text(value, style: theme.textTheme.titleLarge),
          Text(label, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

typedef _BookingResult = ({DateTime? start, String notes, bool delete});

/// Book (or move, or cancel) a job: day, start time and notes.
class _BookingDialog extends StatefulWidget {
  const _BookingDialog({required this.existing, required this.now});

  final ScheduledJob? existing;
  final DateTime now;

  @override
  State<_BookingDialog> createState() => _BookingDialogState();
}

class _BookingDialogState extends State<_BookingDialog> {
  late DateTime _day = () {
    final s = widget.existing?.start;
    if (s != null) return DateTime(s.year, s.month, s.day);
    final tomorrow = widget.now.add(const Duration(days: 1));
    return DateTime(tomorrow.year, tomorrow.month, tomorrow.day);
  }();
  late TimeOfDay _time = widget.existing == null
      ? const TimeOfDay(hour: 9, minute: 0)
      : TimeOfDay.fromDateTime(widget.existing!.start);
  late final _notes = TextEditingController(text: widget.existing?.notes ?? '');

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _pickDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2000),
      lastDate: DateTime(widget.now.year + 5),
    );
    if (picked != null) setState(() => _day = picked);
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(context: context, initialTime: _time);
    if (picked != null) setState(() => _time = picked);
  }

  void _save() => Navigator.of(context).pop((
    start: DateTime(_day.year, _day.month, _day.day, _time.hour, _time.minute),
    notes: _notes.text.trim(),
    delete: false,
  ));

  @override
  Widget build(BuildContext context) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final at = DateTime(2000, 1, 1, _time.hour, _time.minute);
    return AlertDialog(
      title: Text(widget.existing == null ? 'Schedule a job' : 'Edit job'),
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
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.schedule),
              title: Text(formatClock(at)),
              subtitle: const Text('Start time'),
              onTap: _pickTime,
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
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () =>
                Navigator.of(context)
                    .pop((start: null, notes: '', delete: true)),
            child: const Text('Cancel job'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
