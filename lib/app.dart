import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'background/job_watcher.dart';
import 'features/clients/clients_screen.dart';
import 'features/settings/settings_screen.dart';
import 'state/providers.dart';

class MileageApp extends StatelessWidget {
  const MileageApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF2E7D32);
    return MaterialApp(
      title: 'Dunn Record Keeping',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark),
      home: const HomeShell(),
    );
  }
}

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;
  late final AppLifecycleListener _lifecycle;
  Timer? _inboxTimer;

  @override
  void initState() {
    super.initState();
    // Sign back in to Google (no UI), pick up settings from the other
    // device, add trips detected while the app was closed, and re-check
    // automatic trips. Repeat whenever the app comes back to the front.
    Future.microtask(() async {
      await _catchUp();
      await ref.read(autoTripProvider.notifier).refresh();
      await syncJobWatcher(ref.read(localStoreProvider));
      await ref.read(syncProvider.notifier).restore();
    });
    _lifecycle = AppLifecycleListener(
      onResume: () async {
        await _catchUp();
        await ref.read(autoTripProvider.notifier).refresh();
        await syncJobWatcher(ref.read(localStoreProvider));
        await ref.read(syncProvider.notifier).syncNow();
      },
    );
    // Arrivals detected while the app is open show up within a minute.
    _inboxTimer = Timer.periodic(const Duration(minutes: 1), (_) => _catchUp());
  }

  /// Adds trips and job changes made in the background.
  Future<void> _catchUp() async {
    await ref.read(jobsProvider.notifier).refresh();
    await ref.read(tripsProvider.notifier).mergeInbox();
  }

  @override
  void dispose() {
    _inboxTimer?.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  static const _pages = [ClientsScreen(), SettingsScreen()];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.people_outline),
            selectedIcon: Icon(Icons.people),
            label: 'Clients',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
