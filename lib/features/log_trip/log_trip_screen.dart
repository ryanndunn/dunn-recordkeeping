import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/place.dart';
import '../../models/saved_address.dart';
import '../../models/trip.dart';
import '../../services/address_matcher.dart';
import '../../services/distance_service.dart';
import '../../state/providers.dart';
import '../../widgets/address_search_field.dart';
import '../../widgets/client_dialog.dart';
import '../../widgets/place_dialog.dart';

class LogTripScreen extends ConsumerStatefulWidget {
  const LogTripScreen({super.key});

  @override
  ConsumerState<LogTripScreen> createState() => _LogTripScreenState();
}

enum _UnmatchedChoice { saveAndLog, logOnce }

class _LogTripScreenState extends ConsumerState<LogTripScreen> {
  /// Start chosen by hand for the next trip only; null = automatic.
  Place? _fromOverride;
  bool _busy = false;

  // ------------------------------------------------------------- actions

  Future<void> _logTo(Place to) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final trip = await ref
          .read(tripsProvider.notifier)
          .logTripTo(to, fromOverride: _fromOverride);
      if (!mounted) return;
      setState(() => _fromOverride = null);
      _showLogged(trip);
    } on TripException catch (e) {
      _snack(e.toString());
    } on DistanceException catch (e) {
      _snack('Trip not logged. ${e.message}');
    } catch (e) {
      _snack('Could not log trip: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A destination was picked from the dropdown.
  Future<void> _onPicked(Place place, SavedAddress? saved) async {
    if (saved != null) return _logTo(saved.toPlace());

    // A Google result can still be a saved place (same place ID, or close by).
    final match = ref
        .read(addressMatcherProvider)
        .match(
          AddressQuery(
            text: place.address,
            placeId: place.placeId,
            lat: place.lat,
            lng: place.lng,
          ),
          ref.read(addressesProvider),
        );
    if (match != null) return _logTo(match.toPlace());

    final choice = await showDialog<_UnmatchedChoice>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Not one of your clients'),
        content: Text('${place.label}\n${place.address}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, _UnmatchedChoice.logOnce),
            child: const Text('Log once'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, _UnmatchedChoice.saveAndLog),
            child: const Text('Add client & log'),
          ),
        ],
      ),
    );
    if (!mounted || choice == null) return;

    switch (choice) {
      case _UnmatchedChoice.logOnce:
        await _logTo(place);
      case _UnmatchedChoice.saveAndLog:
        final input = await showClientDialog(
          context,
          title: 'New client',
          initialPlace: place,
          saveLabel: 'Save & log',
        );
        if (!mounted || input == null) return;
        final created = await ref
            .read(addressesProvider.notifier)
            .add(
              name: input.name,
              place: input.place,
              email: input.email,
              phone: input.phone,
            );
        await _logTo(created.toPlace());
    }
  }

  Future<void> _returnHome() async {
    final home = ref.read(settingsProvider).home;
    if (home != null) await _logTo(home);
  }

  Future<void> _chooseStart() async {
    final home = ref.read(settingsProvider).home;
    final saved = [...ref.read(addressesProvider)]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    final picked = await showModalBottomSheet<Object>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Start this trip from…')),
            ListTile(
              leading: const Icon(Icons.auto_mode),
              title: const Text('Automatic'),
              subtitle: const Text('Last stop today, otherwise home'),
              onTap: () => Navigator.pop(context, 'auto'),
            ),
            if (home != null)
              ListTile(
                leading: const Icon(Icons.home_outlined),
                title: Text(home.label),
                subtitle: Text(home.address),
                onTap: () => Navigator.pop(context, home),
              ),
            for (final a in saved)
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(a.name),
                subtitle: Text(a.address),
                onTap: () => Navigator.pop(context, a.toPlace()),
              ),
          ],
        ),
      ),
    );
    if (!mounted || picked == null) return;
    setState(() => _fromOverride = picked is Place ? picked : null);
  }

  Future<void> _setHome() async {
    final home = ref.read(settingsProvider).home;
    final input = await showPlaceDialog(
      context,
      title: 'Home / office address',
      initialName: home?.label ?? 'Home',
      initialPlace: home,
      nameHint: 'Home or Office',
    );
    if (input == null) return;
    await ref
        .read(settingsProvider.notifier)
        .setHome(input.place.relabel(input.name));
  }

  Future<void> _deleteTrip(Trip trip) async {
    await ref.read(tripsProvider.notifier).remove(trip.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Deleted trip to ${trip.to.label}'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => ref.read(tripsProvider.notifier).restore(trip),
          ),
        ),
      );
  }

  void _showLogged(Trip trip) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Logged ${_miles(trip.miles)} to ${trip.to.label}'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => ref.read(tripsProvider.notifier).remove(trip.id),
          ),
        ),
      );
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final autoStart = ref.watch(nextStartProvider);
    final start = _fromOverride ?? autoStart;
    final home = ref.watch(settingsProvider).home;
    final today = ref.watch(todaysTripsProvider);
    final isDemo = ref.watch(distanceServiceProvider).isDemo;
    final totalToday = today.fold<double>(0, (sum, t) => sum + t.miles);
    final atHome = home != null && start == home;
    // Only meaningful once signed in; before that nothing uploads.
    final signedIn = ref.watch(syncProvider.select((s) => s.signedIn));
    final waitingUpload = signedIn
        ? ref.watch(tripsProvider).where((t) => !t.synced).length
        : 0;

    return Scaffold(
      appBar: AppBar(title: const Text('Log Trip')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (isDemo) const _DemoBanner(),
              if (start == null)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.home_outlined),
                    title: const Text('Set your home/office address'),
                    subtitle: const Text(
                      'The first trip each day is measured from here.',
                    ),
                    trailing: FilledButton(
                      onPressed: _setHome,
                      child: const Text('Set'),
                    ),
                  ),
                )
              else
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.trip_origin),
                    title: Text('From: ${start.label}'),
                    subtitle: Text(
                      _fromOverride == null
                          ? start.address
                          : '${start.address}\n(chosen for this trip)',
                    ),
                    isThreeLine: _fromOverride != null,
                    trailing: TextButton(
                      onPressed: _chooseStart,
                      child: const Text('Change'),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              AddressSearchField(
                labelText: 'Going to',
                includeSaved: true,
                clearAfterPick: true,
                enabled: start != null,
                busy: _busy,
                biasNear: home,
                onPicked: _onPicked,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _busy || home == null || start == null || atHome
                    ? null
                    : _returnHome,
                icon: const Icon(Icons.home_outlined),
                label: Text('Return to ${home?.label ?? 'home'}'),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Text('Today', style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  Text(
                    _miles(totalToday),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
              const Divider(),
              if (waitingUpload > 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Icon(
                        Icons.cloud_upload_outlined,
                        size: 18,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          waitingUpload == 1
                              ? '1 trip waiting to upload to your spreadsheet'
                              : '$waitingUpload trips waiting to upload to '
                                    'your spreadsheet',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
              if (today.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: Text('No trips logged yet today.')),
                ),
              for (final trip in today.reversed)
                Dismissible(
                  key: ValueKey(trip.id),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 16),
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: const Icon(Icons.delete_outline),
                  ),
                  onDismissed: (_) => _deleteTrip(trip),
                  child: ListTile(
                    title: Text('${trip.from.label} → ${trip.to.label}'),
                    subtitle: Text(
                      TimeOfDay.fromDateTime(trip.date).format(context),
                    ),
                    trailing: Text(
                      trip.estimated
                          ? '${_miles(trip.miles)} est.'
                          : _miles(trip.miles),
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static String _miles(double miles) => '${miles.toStringAsFixed(1)} mi';
}

class _DemoBanner extends StatelessWidget {
  const _DemoBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.tertiaryContainer,
      child: ListTile(
        leading: Icon(Icons.info_outline, color: scheme.onTertiaryContainer),
        title: Text(
          'Estimated miles',
          style: TextStyle(color: scheme.onTertiaryContainer),
        ),
        subtitle: Text(
          'Add your Google Maps API key in Settings to log real driving '
          'distances.',
          style: TextStyle(color: scheme.onTertiaryContainer),
        ),
      ),
    );
  }
}
