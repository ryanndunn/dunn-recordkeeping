import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/saved_address.dart';
import '../../state/providers.dart';
import '../../widgets/place_dialog.dart';

/// The donation centers you drop items off at. Stopping at one during a
/// job keeps the job going; going to one on its own isn't a job.
class DonationCentersSection extends ConsumerWidget {
  const DonationCentersSection({super.key});

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final input = await showPlaceDialog(
      context,
      title: 'New donation center',
      nameHint: 'e.g. Goodwill on Main St',
    );
    if (input == null) return;
    await ref
        .read(donationCentersProvider.notifier)
        .add(name: input.name, place: input.place);
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    SavedAddress center,
  ) async {
    final input = await showPlaceDialog(
      context,
      title: 'Edit donation center',
      initialName: center.name,
      initialPlace: center.toPlace(),
      nameHint: 'e.g. Goodwill on Main St',
    );
    if (input == null) return;
    final p = input.place;
    await ref
        .read(donationCentersProvider.notifier)
        .replace(
          center.copyWith(
            name: input.name,
            address: p.address,
            placeId: p.placeId,
            lat: p.lat,
            lng: p.lng,
          ),
        );
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    SavedAddress center,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${center.name}"?'),
        content: const Text('Trips already logged there are kept.'),
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
    if (ok == true) {
      await ref.read(donationCentersProvider.notifier).remove(center.id);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final centers = [...ref.watch(donationCentersProvider)]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('Donation centers', style: theme.textTheme.titleMedium),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _add(context, ref),
              icon: const Icon(Icons.add),
              label: const Text('Add'),
            ),
          ],
        ),
        const Divider(),
        if (centers.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Add the places you drop off donations. Stopping at one during '
              'a job keeps the job going.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        for (final c in centers)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.volunteer_activism_outlined),
            title: Text(c.name),
            subtitle: Text(c.address),
            onTap: () => _edit(context, ref, c),
            trailing: IconButton(
              tooltip: 'Delete ${c.name}',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _delete(context, ref, c),
            ),
          ),
      ],
    );
  }
}
