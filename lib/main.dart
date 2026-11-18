import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'background/job_watcher.dart';
import 'services/auto_trip.dart';
import 'services/local_store.dart';
import 'services/secret_store.dart';
import 'state/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final secrets = await SecureSecretStore.load();
  try {
    await configureJobWatcher();
  } catch (e) {
    debugPrint('Dunn Record Keeping: job watcher not set up: $e');
  }
  runApp(
    ProviderScope(
      overrides: [
        localStoreProvider.overrideWithValue(LocalStore(prefs)),
        autoTripInboxProvider.overrideWithValue(AutoTripInbox(prefs)),
        secretStoreProvider.overrideWithValue(secrets),
      ],
      child: const MileageApp(),
    ),
  );
}
