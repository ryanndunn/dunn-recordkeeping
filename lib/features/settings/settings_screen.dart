import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../state/providers.dart';
import '../../widgets/place_dialog.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  Future<void> _editHome(BuildContext context, WidgetRef ref) async {
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

  Future<void> _editApiKey(BuildContext context, WidgetRef ref) async {
    final result = await showDialog<_KeyResult>(
      context: context,
      builder: (_) => _ApiKeyDialog(hasKey: ref.read(apiKeyProvider) != null),
    );
    if (result == null) return;
    try {
      await ref.read(apiKeyProvider.notifier).set(result.key);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Couldn\'t save the key securely: $e')),
        );
      }
    }
  }

  Future<void> _editRate(BuildContext context, WidgetRef ref) async {
    final current = ref.read(settingsProvider).ratePerMile;
    final result = await showDialog<_RateResult>(
      context: context,
      builder: (_) => _RateDialog(initial: current),
    );
    if (result == null) return;
    await ref.read(settingsProvider.notifier).setRatePerMile(result.rate);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final apiKey = ref.watch(apiKeyProvider);
    final home = settings.home;
    final header = Theme.of(context).textTheme.titleSmall
        ?.copyWith(color: Theme.of(context).colorScheme.primary);

    Widget section(String title) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(title, style: header),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            children: [
              if (ref.watch(autoTripProvider).supported) ...[
                section('Automatic trips'),
                const _AutoTripsSection(),
              ],
              section('Google account'),
              const _GoogleAccountSection(),
              section('Starting point'),
              ListTile(
                leading: home == null || home.isVerified
                    ? const Icon(Icons.home_outlined)
                    : Icon(
                        Icons.warning_amber,
                        color: Theme.of(context).colorScheme.error,
                      ),
                title: Text(home?.label ?? 'Home / office'),
                subtitle: Text(
                  home == null
                      ? 'Not set'
                      : home.isVerified
                      ? home.address
                      : '${home.address}\nNot verified. Tap to pick it '
                            'from Google Maps.',
                ),
                isThreeLine: home != null && !home.isVerified,
                trailing: const Icon(Icons.edit_outlined),
                onTap: () => _editHome(context, ref),
              ),
              section('Mileage rate'),
              ListTile(
                leading: const Icon(Icons.attach_money),
                title: const Text('Rate per mile'),
                subtitle: Text(
                  settings.ratePerMile == null
                      ? 'Not set (optional, used for the Summary tab)'
                      : '\$${settings.ratePerMile!.toStringAsFixed(3)} per mile',
                ),
                trailing: const Icon(Icons.edit_outlined),
                onTap: () => _editRate(context, ref),
              ),
              section('Google Maps'),
              ListTile(
                leading: const Icon(Icons.key_outlined),
                title: const Text('API key'),
                subtitle: Text(
                  apiKey == null
                      ? 'Not set. Needed for address search and driving '
                            'miles. See docs/GOOGLE_CLOUD_SETUP.md.'
                      : 'Saved on this device (ending '
                            '…${apiKey.substring(apiKey.length - 4)})',
                ),
                trailing: const Icon(Icons.edit_outlined),
                onTap: () => _editApiKey(context, ref),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

/// Turns arrival detection on/off and explains what it needs.
class _AutoTripsSection extends ConsumerWidget {
  const _AutoTripsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auto = ref.watch(autoTripProvider);
    final notifier = ref.read(autoTripProvider.notifier);
    final scheme = Theme.of(context).colorScheme;

    final String status;
    if (!auto.enabled) {
      status =
          'Off. When on, arriving at a client\'s address (or home after '
          'appointments) and staying 5 minutes logs the trip, even with the '
          'app closed. Works with Google Maps, Waze, or no navigation app.';
    } else if (!auto.permissionOk) {
      status =
          'Paused: location is not set to "Allow all the time". Tap to fix.';
    } else {
      status =
          'Watching ${auto.watching} '
          '${auto.watching == 1 ? 'place' : 'places'}. Trips are logged when '
          'you arrive and stay 5 minutes, whether you drove with Google '
          'Maps, Waze, or neither.';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          secondary: Icon(
            auto.enabled && auto.permissionOk
                ? Icons.share_location
                : Icons.location_off_outlined,
            color: auto.enabled && !auto.permissionOk ? scheme.error : null,
          ),
          title: const Text('Log trips automatically'),
          subtitle: Text(status),
          isThreeLine: true,
          value: auto.enabled,
          onChanged: (on) => on ? notifier.enable() : notifier.disable(),
        ),
        if (auto.enabled && !auto.permissionOk)
          Padding(
            padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
            child: FilledButton(
              onPressed: notifier.enable,
              child: const Text('Allow location all the time'),
            ),
          ),
        if (auto.enabled && auto.skipped > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
            child: Text(
              '${auto.skipped} saved '
              '${auto.skipped == 1 ? 'place isn\'t' : 'places aren\'t'} '
              'watched because '
              '${auto.skipped == 1 ? 'it wasn\'t' : 'they weren\'t'} picked '
              'from Google Maps. Re-pick '
              '${auto.skipped == 1 ? 'it' : 'them'} to include '
              '${auto.skipped == 1 ? 'it' : 'them'}.',
              style: TextStyle(color: scheme.error),
            ),
          ),
        if (auto.message != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
            child: Text(auto.message!, style: TextStyle(color: scheme.error)),
          ),
        if (auto.enabled)
          const Padding(
            padding: EdgeInsets.fromLTRB(72, 0, 16, 8),
            child: Text(
              'Samsung phones: also add Dunn Record Keeping under Settings → Battery '
              '→ Background usage limits → Never sleeping apps, so arrivals '
              'aren\'t delayed.',
            ),
          ),
      ],
    );
  }
}

/// Sign-in status and sync controls.
class _GoogleAccountSection extends ConsumerWidget {
  const _GoogleAccountSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncProvider);
    final notifier = ref.read(syncProvider.notifier);
    final spreadsheetId = ref.watch(
      settingsProvider.select((s) => s.spreadsheetId),
    );
    final scheme = Theme.of(context).colorScheme;

    String syncedText() {
      final at = sync.lastSynced;
      if (at == null) return 'Not synced yet';
      return 'Synced at ${TimeOfDay.fromDateTime(at).format(context)}';
    }

    switch (sync.phase) {
      case SyncPhase.unavailable:
        return const ListTile(
          enabled: false,
          leading: Icon(Icons.account_circle_outlined),
          title: Text('Sign in with Google'),
          subtitle: Text(
            'Not set up in this build (Google client IDs missing).',
          ),
        );
      case SyncPhase.signedOut:
        return Column(
          children: [
            ListTile(
              leading: const Icon(Icons.account_circle_outlined),
              title: const Text('Sign in with Google'),
              subtitle: const Text(
                'Keeps your clients, settings and API key the same on your '
                'phone and Mac, and uploads trips to your spreadsheet.',
              ),
              trailing: FilledButton(
                onPressed: notifier.signIn,
                child: const Text('Sign in'),
              ),
            ),
            if (sync.message != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
                child: Text(sync.message!),
              ),
          ],
        );
      case SyncPhase.working:
        return ListTile(
          leading: const SizedBox.square(
            dimension: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          title: Text(sync.email ?? 'Google account'),
          subtitle: Text(sync.message ?? 'Syncing…'),
        );
      case SyncPhase.ready:
      case SyncPhase.error:
        final failed = sync.phase == SyncPhase.error;
        if (!sync.signedIn && failed) {
          return ListTile(
            leading: Icon(Icons.error_outline, color: scheme.error),
            title: const Text('Sign-in didn\'t work'),
            subtitle: Text(sync.message ?? ''),
            trailing: FilledButton(
              onPressed: notifier.signIn,
              child: const Text('Try again'),
            ),
          );
        }
        return Column(
          children: [
            ListTile(
              leading: Icon(
                failed ? Icons.sync_problem : Icons.cloud_done_outlined,
                color: failed ? scheme.error : scheme.primary,
              ),
              title: Text(sync.email ?? 'Signed in'),
              subtitle: Text(failed ? (sync.message ?? '') : syncedText()),
              trailing: IconButton(
                tooltip: 'Sync now',
                icon: const Icon(Icons.sync),
                onPressed: notifier.syncNow,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  if (spreadsheetId != null)
                    TextButton.icon(
                      icon: const Icon(Icons.table_chart_outlined),
                      label: const Text('Open spreadsheet'),
                      onPressed: () => launchUrl(
                        Uri.parse(
                          'https://docs.google.com/spreadsheets/d/$spreadsheetId',
                        ),
                      ),
                    ),
                  const Spacer(),
                  TextButton(
                    onPressed: notifier.signOut,
                    child: const Text('Sign out'),
                  ),
                ],
              ),
            ),
          ],
        );
    }
  }
}

class _KeyResult {
  const _KeyResult(this.key);

  /// Null removes the saved key.
  final String? key;
}

class _ApiKeyDialog extends StatefulWidget {
  const _ApiKeyDialog({required this.hasKey});
  final bool hasKey;

  @override
  State<_ApiKeyDialog> createState() => _ApiKeyDialogState();
}

class _ApiKeyDialogState extends State<_ApiKeyDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final key = _controller.text.trim();
    if (key.length < 20 || key.contains(' ')) {
      setState(() => _error = 'That doesn\'t look like a Google API key.');
      return;
    }
    Navigator.pop(context, _KeyResult(key));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Google Maps API key'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: widget.hasKey ? 'New key' : 'Key',
          helperText: 'Stored in this device\'s secure storage',
          errorText: _error,
        ),
        onSubmitted: (_) => _save(),
      ),
      actions: [
        if (widget.hasKey)
          TextButton(
            onPressed: () => Navigator.pop(context, const _KeyResult(null)),
            child: const Text('Remove key'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

class _RateResult {
  const _RateResult(this.rate);
  final double? rate;
}

class _RateDialog extends StatefulWidget {
  const _RateDialog({required this.initial});
  final double? initial;

  @override
  State<_RateDialog> createState() => _RateDialogState();
}

class _RateDialogState extends State<_RateDialog> {
  late final _controller = TextEditingController(
    text: widget.initial?.toString() ?? '',
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final text = _controller.text.trim().replaceAll('\$', '');
    if (text.isEmpty) {
      Navigator.pop(context, const _RateResult(null));
      return;
    }
    final rate = double.tryParse(text);
    if (rate == null || rate < 0 || rate > 10) {
      setState(() => _error = 'Enter dollars per mile, e.g. 0.70');
      return;
    }
    Navigator.pop(context, _RateResult(rate));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rate per mile'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          prefixText: '\$ ',
          hintText: '0.70',
          helperText: 'Leave blank to clear',
          errorText: _error,
        ),
        onSubmitted: (_) => _save(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
