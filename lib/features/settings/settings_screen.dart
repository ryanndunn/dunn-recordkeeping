import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/app_settings.dart';
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
              section('Google account'),
              const ListTile(
                enabled: false,
                leading: Icon(Icons.account_circle_outlined),
                title: Text('Sign in with Google'),
                subtitle: Text(
                  'Chooses which Google account holds your mileage '
                  'spreadsheet. Coming in the next build.',
                ),
              ),
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
              section('Navigation app'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SegmentedButton<NavApp>(
                  segments: [
                    for (final app in NavApp.values)
                      ButtonSegment(value: app, label: Text(app.label)),
                  ],
                  selected: {settings.navApp},
                  onSelectionChanged: (s) =>
                      ref.read(settingsProvider.notifier).setNavApp(s.first),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  'Opens with whatever account is signed in to that app on '
                  'this device.',
                ),
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
