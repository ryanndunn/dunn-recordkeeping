import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/saved_address.dart';
import '../../state/providers.dart';
import '../../widgets/client_dialog.dart';
import 'client_page.dart';
import 'client_status.dart';

/// The client list, and the app's first screen. Tap a client to open their
/// page. Each client's address is where appointments happen: logging a trip
/// there is one tap, and arriving there logs it on its own.
class ClientsScreen extends ConsumerStatefulWidget {
  const ClientsScreen({super.key});

  @override
  ConsumerState<ClientsScreen> createState() => _ClientsScreenState();
}

class _ClientsScreenState extends ConsumerState<ClientsScreen> {
  /// The status shown, or null for everyone not archived.
  ClientStatus? _show;

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final input = await showClientDialog(context, title: 'New client');
    if (input == null) return;
    await ref
        .read(addressesProvider.notifier)
        .add(
          name: input.name,
          place: input.place,
          email: input.email,
          phone: input.phone,
        );
  }

  void _openClient(BuildContext context, SavedAddress client) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ClientPage(clientId: client.id),
        ),
      );

  Future<bool> _confirmDelete(BuildContext context, SavedAddress c) async {
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
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(addressesProvider);
    int count(ClientStatus s) => all.where((c) => c.status == s).length;
    final current = all.length - count(ClientStatus.archived);
    final clients = [
      for (final c in all)
        if (_show == null
            ? c.status != ClientStatus.archived
            : c.status == _show)
          c,
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return Scaffold(
      appBar: AppBar(title: const Text('Clients')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _add(context, ref),
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Add client'),
      ),
      body: all.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Add your clients and where you meet them. Trips to a '
                  'client\'s address are logged with the driving miles.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(
                  children: [
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: Row(
                        children: [
                          for (final s in <ClientStatus?>[
                            null,
                            ...ClientStatus.values,
                          ])
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(
                                  s == null
                                      ? 'All $current'
                                      : '${s.shortLabel} ${count(s)}',
                                ),
                                selected: _show == s,
                                onSelected: (_) => setState(() => _show = s),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: clients.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(32),
                                child: Text(
                                  _show == null
                                      ? 'Everyone is archived.'
                                      : 'No clients are '
                                            '"${_show!.label}".',
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            )
                          : ListView.separated(
                              padding: const EdgeInsets.only(bottom: 88),
                              itemCount: clients.length,
                              separatorBuilder: (_, _) =>
                                  const Divider(height: 1),
                              itemBuilder: (context, i) {
                                final c = clients[i];
                                return Dismissible(
                                  key: ValueKey(c.id),
                                  direction: DismissDirection.endToStart,
                                  background: Container(
                                    alignment: Alignment.centerRight,
                                    padding: const EdgeInsets.only(right: 16),
                                    color: Theme.of(context)
                                        .colorScheme
                                        .errorContainer,
                                    child: const Icon(Icons.delete_outline),
                                  ),
                                  confirmDismiss: (_) =>
                                      _confirmDelete(context, c),
                                  onDismissed: (_) => ref
                                      .read(addressesProvider.notifier)
                                      .remove(c.id),
                                  child: _ClientTile(
                                    client: c,
                                    onTap: () => _openClient(context, c),
                                    onCall: c.phone.isEmpty
                                        ? null
                                        : () => openClientLink(
                                            context,
                                            Uri(scheme: 'tel', path: c.phone),
                                          ),
                                    onEmail: c.email.isEmpty
                                        ? null
                                        : () => openClientLink(
                                            context,
                                            Uri(
                                              scheme: 'mailto',
                                              path: c.email,
                                            ),
                                          ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _ClientTile extends StatelessWidget {
  const _ClientTile({
    required this.client,
    required this.onTap,
    required this.onCall,
    required this.onEmail,
  });

  final SavedAddress client;
  final VoidCallback onTap;
  final VoidCallback? onCall;
  final VoidCallback? onEmail;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = client;
    final contact = [c.phone, c.email].where((s) => s.isNotEmpty).join(' · ');
    return ListTile(
      onTap: onTap,
      leading: c.isVerified
          ? CircleAvatar(child: Text(clientInitials(c.name)))
          : CircleAvatar(
              backgroundColor: scheme.errorContainer,
              child: Icon(Icons.warning_amber, color: scheme.error),
            ),
      title: Text(c.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!c.isActive)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: ClientStatusBadge(client: c),
            ),
          Text(
            [
              c.address,
              if (c.locations.isNotEmpty)
                '+ ${c.locations.map((l) => l.label).join(', ')}',
              if (contact.isNotEmpty) contact,
              if (!c.isVerified)
                'Address not verified. Tap to pick it from '
                    'Google Maps.',
            ].join('\n'),
          ),
        ],
      ),
      isThreeLine: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onCall != null)
            IconButton(
              tooltip: 'Call ${c.name}',
              icon: const Icon(Icons.phone_outlined),
              onPressed: onCall,
            ),
          if (onEmail != null)
            IconButton(
              tooltip: 'Email ${c.name}',
              icon: const Icon(Icons.email_outlined),
              onPressed: onEmail,
            ),
        ],
      ),
    );
  }
}
