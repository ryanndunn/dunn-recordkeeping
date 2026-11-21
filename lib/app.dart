import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'background/job_watcher.dart';
import 'features/calendar/calendar_screen.dart';
import 'features/club/club_screen.dart';
import 'features/clients/clients_screen.dart';
import 'features/leads/leads_screen.dart';
import 'features/payments/payments_screen.dart';
import 'features/settings/settings_screen.dart';
import 'state/leads_provider.dart';
import 'state/providers.dart';
import 'state/stripe_provider.dart';

class MileageApp extends StatelessWidget {
  const MileageApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF2E7D32);
    // Titles line up on the left everywhere (the Mac centers them by
    // default).
    const appBar = AppBarTheme(centerTitle: false);
    return MaterialApp(
      title: 'Dunn Record Keeping',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, appBarTheme: appBar),
      darkTheme: ThemeData(
        colorSchemeSeed: seed,
        brightness: Brightness.dark,
        appBarTheme: appBar,
      ),
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
        await ref.read(stripeProvider.notifier).watch();
      },
    );
    // Arrivals detected while the app is open show up within a minute, and
    // bills paid through Stripe within a couple of minutes.
    _inboxTimer = Timer.periodic(const Duration(minutes: 1), (_) async {
      await _catchUp();
      await ref.read(stripeProvider.notifier).watch();
    });
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

  static const _pages = [
    ClientsScreen(),
    LeadsScreen(),
    ClubScreen(),
    CalendarScreen(),
    PaymentsScreen(),
    SettingsScreen(),
  ];

  /// Each tab has its own page stack, so the bottom bar stays on screen
  /// when a client page (or the Mileage Log) opens.
  final _tabs = [for (final _ in _pages) GlobalKey<NavigatorState>()];

  void _select(int i) {
    if (i == _index) {
      // Tapping the open tab goes back to its first page.
      _tabs[i].currentState?.popUntil((r) => r.isFirst);
    } else {
      setState(() => _index = i);
    }
  }

  /// The phone's back button: back within the tab, then to Clients, then
  /// out of the app.
  void _back() {
    final tab = _tabs[_index].currentState;
    if (tab != null && tab.canPop()) {
      tab.pop();
    } else if (_index != 0) {
      setState(() => _index = 0);
    } else {
      SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final newLeads = ref.watch(openLeadsProvider).length;
    // A bill just paid through Stripe: say so, wherever you are.
    ref.listen(stripePaidNoticesProvider, (_, notices) {
      if (notices.isEmpty) return;
      final messenger = ScaffoldMessenger.of(context);
      for (final n in notices) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(n),
            duration: const Duration(seconds: 8),
            showCloseIcon: true,
          ),
        );
      }
      Future.microtask(
        () => ref.read(stripePaidNoticesProvider.notifier).clear(),
      );
    });
    return Scaffold(
      body: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _back();
        },
        child: IndexedStack(
          index: _index,
          children: [
            for (var i = 0; i < _pages.length; i++)
              HeroControllerScope.none(
                child: Navigator(
                  key: _tabs[i],
                  onGenerateRoute: (_) =>
                      MaterialPageRoute<void>(builder: (_) => _pages[i]),
                ),
              ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _select,
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.people_outline),
            selectedIcon: Icon(Icons.people),
            label: 'Clients',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: newLeads > 0,
              label: Text('$newLeads'),
              child: const Icon(Icons.mark_email_unread_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: newLeads > 0,
              label: Text('$newLeads'),
              child: const Icon(Icons.mark_email_unread),
            ),
            label: 'Leads',
          ),
          const NavigationDestination(
            icon: Icon(Icons.groups_outlined),
            selectedIcon: Icon(Icons.groups),
            label: 'Club',
          ),
          const NavigationDestination(
            icon: Icon(Icons.calendar_month_outlined),
            selectedIcon: Icon(Icons.calendar_month),
            label: 'Calendar',
          ),
          const NavigationDestination(
            icon: Icon(Icons.payments_outlined),
            selectedIcon: Icon(Icons.payments),
            label: 'Billing',
          ),
          const NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
