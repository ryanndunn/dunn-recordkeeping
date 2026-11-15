import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/saved_address.dart';
import '../../state/providers.dart';
import '../../widgets/place_dialog.dart';

class AddressesScreen extends ConsumerWidget {
  const AddressesScreen({super.key});

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final input = await showPlaceDialog(context, title: 'New address');
    if (input == null) return;
    await ref
        .read(addressesProvider.notifier)
        .add(name: input.name, place: input.place);
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    SavedAddress address,
  ) async {
    final input = await showPlaceDialog(
      context,
      title: 'Edit address',
      initialName: address.name,
      initialPlace: address.toPlace(),
    );
    if (input == null) return;
    final place = input.place;
    await ref
        .read(addressesProvider.notifier)
        .replace(
          address.copyWith(
            name: input.name,
            address: place.address,
            placeId: place.placeId,
            lat: place.lat,
            lng: place.lng,
          ),
        );
  }

  Future<bool> _confirmDelete(BuildContext context, SavedAddress a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${a.name}"?'),
        content: const Text('Trips already logged to this address are kept.'),
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
  Widget build(BuildContext context, WidgetRef ref) {
    final addresses = [...ref.watch(addressesProvider)]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return Scaffold(
      appBar: AppBar(title: const Text('Saved Addresses')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _add(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Add address'),
      ),
      body: addresses.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Add the places you drive to for appointments. '
                  'When you log a trip to one of them, the miles are '
                  'recorded automatically.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: ListView.separated(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: addresses.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final a = addresses[i];
                    return Dismissible(
                      key: ValueKey(a.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 16),
                        color: Theme.of(context).colorScheme.errorContainer,
                        child: const Icon(Icons.delete_outline),
                      ),
                      confirmDismiss: (_) => _confirmDelete(context, a),
                      onDismissed: (_) =>
                          ref.read(addressesProvider.notifier).remove(a.id),
                      child: ListTile(
                        leading: a.isVerified
                            ? const Icon(Icons.bookmark_outline)
                            : Icon(
                                Icons.warning_amber,
                                color: Theme.of(context).colorScheme.error,
                              ),
                        title: Text(a.name),
                        subtitle: Text(
                          a.isVerified
                              ? a.address
                              : '${a.address}\nNot verified. Tap to pick it '
                                    'from Google Maps.',
                        ),
                        isThreeLine: !a.isVerified,
                        trailing: const Icon(Icons.edit_outlined),
                        onTap: () => _edit(context, ref, a),
                      ),
                    );
                  },
                ),
              ),
            ),
    );
  }
}
