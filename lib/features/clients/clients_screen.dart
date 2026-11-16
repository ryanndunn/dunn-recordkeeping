import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/saved_address.dart';
import '../../state/providers.dart';
import '../../widgets/client_dialog.dart';

/// The client list. Each client's address is where appointments happen:
/// logging a trip there is one tap, and arriving there logs it on its own.
class ClientsScreen extends ConsumerWidget {
  const ClientsScreen({super.key});

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

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    SavedAddress client,
  ) async {
    final input = await showClientDialog(
      context,
      title: 'Edit client',
      client: client,
    );
    if (input == null) return;
    final place = input.place;
    await ref
        .read(addressesProvider.notifier)
        .replace(
          client.copyWith(
            name: input.name,
            email: input.email,
            phone: input.phone,
            address: place.address,
            placeId: place.placeId,
            lat: place.lat,
            lng: place.lng,
          ),
        );
  }

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

  static Future<void> _open(BuildContext context, Uri uri) async {
    final messenger = ScaffoldMessenger.of(context);
    var opened = false;
    try {
      opened = await launchUrl(uri);
    } catch (_) {}
    if (!opened) {
      messenger.showSnackBar(
        SnackBar(content: Text('No app on this device can open ${uri.path}')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clients = [...ref.watch(addressesProvider)]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return Scaffold(
      appBar: AppBar(title: const Text('Clients')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _add(context, ref),
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Add client'),
      ),
      body: clients.isEmpty
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
                child: ListView.separated(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: clients.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final c = clients[i];
                    return Dismissible(
                      key: ValueKey(c.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 16),
                        color: Theme.of(context).colorScheme.errorContainer,
                        child: const Icon(Icons.delete_outline),
                      ),
                      confirmDismiss: (_) => _confirmDelete(context, c),
                      onDismissed: (_) =>
                          ref.read(addressesProvider.notifier).remove(c.id),
                      child: _ClientTile(
                        client: c,
                        onTap: () => _edit(context, ref, c),
                        onCall: c.phone.isEmpty
                            ? null
                            : () => _open(
                                context,
                                Uri(scheme: 'tel', path: c.phone),
                              ),
                        onEmail: c.email.isEmpty
                            ? null
                            : () => _open(
                                context,
                                Uri(scheme: 'mailto', path: c.email),
                              ),
                      ),
                    );
                  },
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
          ? CircleAvatar(child: Text(_initials(c.name)))
          : CircleAvatar(
              backgroundColor: scheme.errorContainer,
              child: Icon(Icons.warning_amber, color: scheme.error),
            ),
      title: Text(c.name),
      subtitle: Text(
        [
          c.address,
          if (contact.isNotEmpty) contact,
          if (!c.isVerified)
            'Address not verified. Tap to pick it from '
                'Google Maps.',
        ].join('\n'),
      ),
      isThreeLine: contact.isNotEmpty || !c.isVerified,
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

  static String _initials(String name) {
    final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    return words.take(2).map((w) => w[0].toUpperCase()).join();
  }
}
