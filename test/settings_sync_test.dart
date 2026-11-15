import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:mileage_log/app.dart';
import 'package:mileage_log/models/app_settings.dart';
import 'package:mileage_log/models/place.dart';
import 'package:mileage_log/models/saved_address.dart';
import 'package:mileage_log/models/trip.dart';
import 'package:mileage_log/services/distance_service.dart';
import 'package:mileage_log/services/google_account.dart';
import 'package:mileage_log/services/local_store.dart';
import 'package:mileage_log/services/secret_store.dart';
import 'package:mileage_log/services/settings_sync.dart';
import 'package:mileage_log/state/providers.dart';

/// Stands in for the hidden Drive file both devices share.
class FakeRemote implements SettingsRemote {
  SyncDoc? stored;
  int writes = 0;

  @override
  Future<SyncDoc?> read() async =>
      stored == null ? null : decodeDoc(encodeDoc(stored!));

  @override
  Future<void> write(SyncDoc doc) async {
    stored = decodeDoc(encodeDoc(doc));
    writes++;
  }

  @override
  Future<String?> accountEmail() async => 'me@example.com';
}

class FakeAccount implements GoogleAccountService {
  bool signedIn = false;

  @override
  Future<GoogleSession?> restore() async =>
      signedIn ? GoogleSession(client: http.Client()) : null;

  @override
  Future<GoogleSession> signIn() async {
    signedIn = true;
    return GoogleSession(client: http.Client());
  }

  @override
  Future<void> signOut() async => signedIn = false;
}

/// Per-device storage (test SharedPreferences is one shared instance, so
/// it can't stand in for two devices).
class MemoryLocalStore implements LocalStore {
  List<SavedAddress> _addresses = [];
  List<Trip> _trips = [];
  String? _settingsJson;
  final _distances = <String, double>{};

  @override
  List<SavedAddress> loadAddresses() => [..._addresses];
  @override
  Future<void> saveAddresses(List<SavedAddress> a) async => _addresses = [...a];
  @override
  List<Trip> loadTrips() => [..._trips];
  @override
  Future<void> saveTrips(List<Trip> t) async => _trips = [...t];
  @override
  AppSettings loadSettings() => _settingsJson == null
      ? const AppSettings()
      : AppSettings.fromJson(
          jsonDecode(_settingsJson!) as Map<String, dynamic>,
        );
  @override
  Future<void> saveSettings(AppSettings s) async =>
      _settingsJson = jsonEncode(s.toJson());
  @override
  double? cachedMiles(String key) => _distances[key];
  @override
  Future<void> cacheMiles(String key, double miles) async =>
      _distances[key] = miles;
}

/// One simulated device: its own storage, the shared remote.
Future<ProviderContainer> device(
  FakeRemote remote, {
  required DateTime Function() clock,
}) async {
  final container = ProviderContainer(
    overrides: [
      localStoreProvider.overrideWithValue(MemoryLocalStore()),
      secretStoreProvider.overrideWithValue(MemorySecretStore()),
      googleAccountServiceProvider.overrideWithValue(FakeAccount()),
      settingsRemoteFactoryProvider.overrideWithValue((_) => remote),
      clockProvider.overrideWithValue(clock),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  const home = Place(label: 'Home', address: '1 Home Rd', placeId: 'h');

  group('merge rules', () {
    final t1 = DateTime.utc(2026, 11, 15, 9);
    final t2 = DateTime.utc(2026, 11, 15, 10);

    test('newer change wins field by field', () {
      final local = {
        'apiKey': SyncField('new-key', t2),
        'ratePerMile': SyncField(0.5, t1),
      };
      final remote = {
        'apiKey': SyncField('old-key', t1),
        'ratePerMile': SyncField(0.7, t2),
        'home': SyncField(home.toJson(), t1),
      };
      final merged = mergeDocs(local, remote);
      expect(merged['apiKey']!.value, 'new-key');
      expect(merged['ratePerMile']!.value, 0.7);
      expect(merged['home']!.value, home.toJson());
    });

    test('values from before syncing existed lose to any later change', () {
      final local = docFromLocal(const AppSettings(home: home), 'legacy-key');
      expect(local['home']!.at, legacyTime);
      expect(local['apiKey']!.at, legacyTime);
      // Default nav app with no change time is not offered at all.
      expect(local.containsKey('navApp'), isFalse);

      final merged = mergeDocs(local, {'apiKey': SyncField('their-key', t1)});
      expect(merged['apiKey']!.value, 'their-key');
      expect(merged['home']!.value, home.toJson());
    });

    test('a removed key (null) that is newer removes it elsewhere', () {
      final applied = applyDoc(
        {'apiKey': SyncField(null, t2)},
        AppSettings(changedAt: {'apiKey': t1}),
        'old-key',
      );
      expect(applied.apiKey, isNull);
      expect(applied.apiKeyChanged, isTrue);
    });

    test('file format round-trips', () {
      final doc = {
        'home': SyncField(home.toJson(), t1),
        'navApp': SyncField('waze', t2),
        'apiKey': SyncField(null, t2),
      };
      expect(docsEqual(decodeDoc(encodeDoc(doc)), doc), isTrue);
    });
  });

  group('two devices', () {
    test(
      'key set on the Mac reaches the phone; phone home reaches the Mac',
      () async {
        final remote = FakeRemote();
        var now = DateTime.utc(2026, 11, 15, 9);
        DateTime clock() => now;

        final mac = await device(remote, clock: clock);
        final phone = await device(remote, clock: clock);

        // Mac: sign in, enter the key.
        await mac.read(syncProvider.notifier).signIn();
        await mac.read(apiKeyProvider.notifier).set('mac-entered-key');
        await mac.read(syncProvider.notifier).syncNow();
        expect(remote.stored!['apiKey']!.value, 'mac-entered-key');

        // Phone: set home first (before signing in), then sign in.
        now = now.add(const Duration(minutes: 5));
        await phone.read(settingsProvider.notifier).setHome(home);
        await phone.read(syncProvider.notifier).signIn();

        expect(phone.read(apiKeyProvider), 'mac-entered-key');
        expect(phone.read(settingsProvider).home, home);
        expect(phone.read(syncProvider).phase, SyncPhase.ready);
        expect(phone.read(syncProvider).email, 'me@example.com');

        // Mac picks up the phone's home on its next sync.
        await mac.read(syncProvider.notifier).syncNow();
        expect(mac.read(settingsProvider).home, home);
        expect(mac.read(apiKeyProvider), 'mac-entered-key');
      },
    );

    test('a later change on either device wins', () async {
      final remote = FakeRemote();
      var now = DateTime.utc(2026, 11, 15, 9);
      DateTime clock() => now;
      final mac = await device(remote, clock: clock);
      final phone = await device(remote, clock: clock);
      await mac.read(syncProvider.notifier).signIn();
      await phone.read(syncProvider.notifier).signIn();

      await mac.read(settingsProvider.notifier).setNavApp(NavApp.waze);
      await mac.read(syncProvider.notifier).syncNow();
      now = now.add(const Duration(minutes: 1));
      await phone.read(settingsProvider.notifier).setRatePerMile(0.7);
      await phone.read(syncProvider.notifier).syncNow();
      now = now.add(const Duration(minutes: 1));
      await mac.read(settingsProvider.notifier).setRatePerMile(0.65);
      await mac.read(syncProvider.notifier).syncNow();
      await phone.read(syncProvider.notifier).syncNow();

      for (final d in [mac, phone]) {
        expect(d.read(settingsProvider).navApp, NavApp.waze);
        expect(d.read(settingsProvider).ratePerMile, 0.65);
      }
    });

    test('nothing is written when already in sync', () async {
      final remote = FakeRemote();
      final mac = await device(remote, clock: () => DateTime.utc(2026, 11, 15));
      await mac.read(syncProvider.notifier).signIn();
      await mac.read(apiKeyProvider.notifier).set('k');
      await mac.read(syncProvider.notifier).syncNow();
      final writes = remote.writes;
      await mac.read(syncProvider.notifier).syncNow();
      expect(remote.writes, writes);
    });

    testWidgets('Settings: sign in shows the account and sync time', (
      tester,
    ) async {
      final remote = FakeRemote();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localStoreProvider.overrideWithValue(MemoryLocalStore()),
            secretStoreProvider.overrideWithValue(MemorySecretStore()),
            googleAccountServiceProvider.overrideWithValue(FakeAccount()),
            settingsRemoteFactoryProvider.overrideWithValue((_) => remote),
            placesServiceProvider.overrideWithValue(null),
            distanceServiceProvider.overrideWithValue(
              const DemoDistanceService(),
            ),
          ],
          child: const MileageApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();

      expect(find.text('Sign in with Google'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();

      expect(find.text('me@example.com'), findsOneWidget);
      expect(find.textContaining('Synced at'), findsOneWidget);
      expect(remote.stored, isNotNull);

      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      expect(find.text('Sign in with Google'), findsOneWidget);
    });

    test('signing out stops syncing', () async {
      final remote = FakeRemote();
      final mac = await device(remote, clock: () => DateTime.utc(2026, 11, 15));
      await mac.read(syncProvider.notifier).signIn();
      await mac.read(syncProvider.notifier).signOut();
      await mac.read(apiKeyProvider.notifier).set('after-sign-out');
      await mac.read(syncProvider.notifier).syncNow();
      expect(remote.stored?['apiKey']?.value, isNot('after-sign-out'));
      expect(mac.read(syncProvider).phase, SyncPhase.signedOut);
    });
  });
}
