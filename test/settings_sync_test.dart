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
import 'package:mileage_log/services/mileage_sheet.dart';
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
  Set<String> _pendingDeletes = {};
  bool _autoTrips = false;
  String? _email;

  @override
  bool get autoTripsEnabled => _autoTrips;
  @override
  Future<void> setAutoTripsEnabled(bool on) async => _autoTrips = on;
  @override
  String? get googleEmail => _email;
  @override
  Future<void> setGoogleEmail(String? email) async => _email = email;

  @override
  Set<String> loadPendingDeletes() => {..._pendingDeletes};
  @override
  Future<void> savePendingDeletes(Set<String> ids) async =>
      _pendingDeletes = {...ids};

  Map<String, DateTime> _clientDeletions = {};
  @override
  Map<String, DateTime> loadClientDeletions() => {..._clientDeletions};
  @override
  Future<void> saveClientDeletions(Map<String, DateTime> d) async =>
      _clientDeletions = {...d};

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

/// Stands in for the user's spreadsheet(s): rows keyed by trip ID.
class FakeSheet implements MileageSheet {
  final sheets = <String, Map<String, Trip>>{};
  int created = 0;
  bool offline = false;

  @override
  Future<String> create({double? ratePerMile}) async {
    if (offline) throw const SheetException('offline');
    created++;
    final id = 'sheet-$created';
    sheets[id] = {};
    return id;
  }

  @override
  Future<void> addTrips(String id, List<Trip> trips) async {
    if (offline) throw const SheetException('offline');
    final rows = sheets[id];
    if (rows == null) throw const SheetException('gone', missing: true);
    for (final t in trips) {
      rows[t.id] = t;
    }
  }

  @override
  Future<void> deleteTrips(String id, Set<String> tripIds) async {
    if (offline) throw const SheetException('offline');
    final rows = sheets[id];
    if (rows == null) throw const SheetException('gone', missing: true);
    rows.removeWhere((k, _) => tripIds.contains(k));
  }
}

/// One simulated device: its own storage, the shared remote.
Future<ProviderContainer> device(
  FakeRemote remote, {
  required DateTime Function() clock,
  FakeSheet? sheet,
  DistanceService? distance,
}) async {
  final container = ProviderContainer(
    overrides: [
      localStoreProvider.overrideWithValue(MemoryLocalStore()),
      secretStoreProvider.overrideWithValue(MemorySecretStore()),
      googleAccountServiceProvider.overrideWithValue(FakeAccount()),
      settingsRemoteFactoryProvider.overrideWithValue((_) => remote),
      mileageSheetFactoryProvider.overrideWithValue(
        (_) => sheet ?? FakeSheet(),
      ),
      distanceServiceProvider.overrideWithValue(
        distance ?? const DemoDistanceService(),
      ),
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

    test('clients round-trip through the sync file', () {
      final jane = SavedAddress(
        id: 'j',
        name: 'Jane Smith',
        address: '9 Elm St',
        email: 'jane@example.com',
        phone: '555-0142',
        placeId: 'elm',
        lat: 40.7,
        lng: -89.6,
        updatedAt: t1,
      );
      final doc = decodeDoc(
        encodeDoc(clientDocFromLocal([jane], {'gone': t2})),
      );
      final back = clientsFromDoc(doc);
      final c = back.clients.single;
      expect(
        (c.id, c.name, c.email, c.phone, c.placeId, c.lat, c.updatedAt),
        ('j', 'Jane Smith', 'jane@example.com', '555-0142', 'elm', 40.7, t1),
      );
      expect(back.deletions, {'gone': t2});
    });

    test('the same client added on both devices is kept once', () {
      Map<String, dynamic> jane(String id) => {
        'id': id,
        'name': 'Jane Smith ',
        'address': '9 Elm',
        'placeId': 'elm',
      };
      final doc = dedupeClients({
        'client:a': SyncField(jane('a'), t1),
        'client:b': SyncField(jane('b'), t2),
        'client:c': SyncField({
          'id': 'c',
          'name': 'Bob',
          'address': '9 Elm',
          'placeId': 'elm',
        }, t1),
      });
      // Newest copy kept; the older one is marked deleted after its own
      // change, so it can't come back. A different client at the same
      // place is untouched.
      expect(doc['client:b']!.value, isNotNull);
      expect(doc['client:a']!.value, isNull);
      expect(doc['client:a']!.at.isAfter(t1), isTrue);
      expect(doc['client:c']!.value, isNotNull);
      // Running it again changes nothing.
      expect(docsEqual(dedupeClients(doc), doc), isTrue);
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
            mileageSheetFactoryProvider.overrideWithValue((_) => FakeSheet()),
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

  group('clients on two devices', () {
    const elm = Place(
      label: '9 Elm St',
      address: '9 Elm St, Peoria, IL',
      placeId: 'elm',
      lat: 40.69,
      lng: -89.59,
    );
    const oak = Place(
      label: '5 Oak Ave',
      address: '5 Oak Ave, Peoria, IL',
      placeId: 'oak',
      lat: 40.7,
      lng: -89.6,
    );

    test('added, edited and deleted clients reach the other device', () async {
      final remote = FakeRemote();
      var now = DateTime.utc(2026, 11, 15, 9);
      DateTime clock() => now;
      final mac = await device(remote, clock: clock);
      final phone = await device(remote, clock: clock);
      await mac.read(syncProvider.notifier).signIn();
      await phone.read(syncProvider.notifier).signIn();

      // Added on the Mac.
      final jane = await mac
          .read(addressesProvider.notifier)
          .add(name: 'Jane Smith', place: elm, phone: '555-0142');
      await mac.read(syncProvider.notifier).syncNow();
      await phone.read(syncProvider.notifier).syncNow();
      final onPhone = phone.read(addressesProvider).single;
      expect(
        (onPhone.id, onPhone.name, onPhone.phone, onPhone.lat),
        (jane.id, 'Jane Smith', '555-0142', 40.69),
      );

      // Edited on the phone.
      now = now.add(const Duration(minutes: 1));
      await phone
          .read(addressesProvider.notifier)
          .replace(onPhone.copyWith(email: 'jane@example.com'));
      await phone.read(syncProvider.notifier).syncNow();
      await mac.read(syncProvider.notifier).syncNow();
      expect(mac.read(addressesProvider).single.email, 'jane@example.com');

      // Deleted on the Mac.
      now = now.add(const Duration(minutes: 1));
      await mac.read(addressesProvider.notifier).remove(jane.id);
      await mac.read(syncProvider.notifier).syncNow();
      await phone.read(syncProvider.notifier).syncNow();
      expect(phone.read(addressesProvider), isEmpty);

      // And it stays deleted after more syncing both ways.
      await mac.read(syncProvider.notifier).syncNow();
      expect(mac.read(addressesProvider), isEmpty);
    });

    test(
      'clients saved on both before syncing are combined, once each',
      () async {
        final remote = FakeRemote();
        final now = DateTime.utc(2026, 11, 15, 9);
        final mac = await device(remote, clock: () => now);
        final phone = await device(
          remote,
          clock: () => now.add(const Duration(minutes: 3)),
        );
        await mac
            .read(addressesProvider.notifier)
            .add(name: 'Jane', place: elm);
        await phone
            .read(addressesProvider.notifier)
            .add(name: 'Jane', place: elm, email: 'jane@example.com');
        await phone
            .read(addressesProvider.notifier)
            .add(name: 'Bob', place: oak);

        await mac.read(syncProvider.notifier).signIn();
        await phone.read(syncProvider.notifier).signIn();
        await mac.read(syncProvider.notifier).syncNow();

        for (final d in [mac, phone]) {
          final clients = d.read(addressesProvider);
          expect(clients.map((c) => c.name), ['Bob', 'Jane']);
          // The newer copy (the phone's, with the email) is the one kept.
          expect(clients.last.email, 'jane@example.com');
        }
      },
    );

    test('a client added here during a sync is not lost', () async {
      final remote = FakeRemote();
      final now = DateTime.utc(2026, 11, 15, 9);
      final mac = await device(remote, clock: () => now);
      await mac.read(syncProvider.notifier).signIn();
      final phone = await device(remote, clock: () => now);
      await phone.read(addressesProvider.notifier).add(name: 'Bob', place: oak);
      await phone.read(syncProvider.notifier).signIn();

      // Mac adds Jane, then a sync brings Bob in: both remain.
      await mac.read(addressesProvider.notifier).add(name: 'Jane', place: elm);
      await mac.read(syncProvider.notifier).syncNow();
      expect(mac.read(addressesProvider).map((c) => c.name), ['Bob', 'Jane']);
      await phone.read(syncProvider.notifier).syncNow();
      expect(phone.read(addressesProvider).map((c) => c.name), ['Bob', 'Jane']);
    });
  });

  group('trips to the spreadsheet', () {
    const clinic = Place(label: 'Clinic', address: '2 Main St', placeId: 'c');
    const dentist = Place(label: 'Dentist', address: '3 Oak Ave', placeId: 'd');
    final now = DateTime(2026, 11, 15, 9);

    test(
      'first sign-in creates one spreadsheet and uploads earlier trips',
      () async {
        final remote = FakeRemote();
        final sheet = FakeSheet();
        final mac = await device(remote, clock: () => now, sheet: sheet);
        await mac.read(settingsProvider.notifier).setHome(home);
        final trip = await mac.read(tripsProvider.notifier).logTripTo(clinic);

        await mac.read(syncProvider.notifier).signIn();

        expect(sheet.created, 1);
        expect(sheet.sheets['sheet-1']!.keys, [trip.id]);
        expect(mac.read(tripsProvider).single.synced, isTrue);
        expect(mac.read(settingsProvider).spreadsheetId, 'sheet-1');
        expect(remote.stored!['spreadsheetId']!.value, 'sheet-1');
        expect(mac.read(syncProvider).phase, SyncPhase.ready);
      },
    );

    test('the second device adds to the same spreadsheet', () async {
      final remote = FakeRemote();
      final sheet = FakeSheet();
      final mac = await device(remote, clock: () => now, sheet: sheet);
      final phone = await device(remote, clock: () => now, sheet: sheet);
      await mac.read(syncProvider.notifier).signIn();
      await phone.read(syncProvider.notifier).signIn();
      expect(sheet.created, 1);
      expect(phone.read(settingsProvider).spreadsheetId, 'sheet-1');

      await phone.read(settingsProvider.notifier).setHome(home);
      final trip = await phone.read(tripsProvider.notifier).logTripTo(dentist);
      await phone.read(syncProvider.notifier).syncNow();
      expect(sheet.sheets['sheet-1']!.keys, contains(trip.id));
    });

    test(
      'deleting an uploaded trip removes its row; Undo brings it back',
      () async {
        final sheet = FakeSheet();
        final mac = await device(FakeRemote(), clock: () => now, sheet: sheet);
        await mac.read(settingsProvider.notifier).setHome(home);
        await mac.read(syncProvider.notifier).signIn();
        final trips = mac.read(tripsProvider.notifier);
        final trip = await trips.logTripTo(clinic);
        await mac.read(syncProvider.notifier).syncNow();
        expect(sheet.sheets['sheet-1']!.keys, [trip.id]);

        await trips.remove(trip.id);
        await mac.read(syncProvider.notifier).syncNow();
        expect(sheet.sheets['sheet-1'], isEmpty);

        await trips.restore(trip);
        expect(mac.read(tripsProvider).single.synced, isFalse);
        await mac.read(syncProvider.notifier).syncNow();
        expect(sheet.sheets['sheet-1']!.keys, [trip.id]);
      },
    );

    test('Undo before the next sync just cancels the delete', () async {
      final sheet = FakeSheet();
      final mac = await device(FakeRemote(), clock: () => now, sheet: sheet);
      await mac.read(settingsProvider.notifier).setHome(home);
      await mac.read(syncProvider.notifier).signIn();
      final trips = mac.read(tripsProvider.notifier);
      final trip = await trips.logTripTo(clinic);
      await mac.read(syncProvider.notifier).syncNow();

      await trips.remove(trip.id);
      await trips.restore(trip);
      expect(mac.read(tripsProvider).single.synced, isTrue);
      await mac.read(syncProvider.notifier).syncNow();
      expect(sheet.sheets['sheet-1']!.keys, [trip.id]);
    });

    test('offline trips wait, then upload when Google is reachable', () async {
      final sheet = FakeSheet();
      final mac = await device(FakeRemote(), clock: () => now, sheet: sheet);
      await mac.read(settingsProvider.notifier).setHome(home);
      await mac.read(syncProvider.notifier).signIn();

      sheet.offline = true;
      final trip = await mac.read(tripsProvider.notifier).logTripTo(clinic);
      await mac.read(syncProvider.notifier).syncNow();
      expect(mac.read(syncProvider).phase, SyncPhase.error);
      expect(mac.read(syncProvider).message, contains('Trips not uploaded'));
      expect(mac.read(tripsProvider).single.synced, isFalse);

      sheet.offline = false;
      await mac.read(syncProvider.notifier).syncNow();
      expect(mac.read(syncProvider).phase, SyncPhase.ready);
      expect(sheet.sheets['sheet-1']!.keys, [trip.id]);
    });

    test(
      'if the spreadsheet is deleted, a new one gets this device\'s trips',
      () async {
        final sheet = FakeSheet();
        final mac = await device(FakeRemote(), clock: () => now, sheet: sheet);
        await mac.read(settingsProvider.notifier).setHome(home);
        final first = await mac.read(tripsProvider.notifier).logTripTo(clinic);
        await mac.read(syncProvider.notifier).signIn();

        sheet.sheets.remove('sheet-1');
        final second = await mac
            .read(tripsProvider.notifier)
            .logTripTo(dentist);
        await mac.read(syncProvider.notifier).syncNow();

        expect(sheet.created, 2);
        expect(mac.read(settingsProvider).spreadsheetId, 'sheet-2');
        expect(
          sheet.sheets['sheet-2']!.keys,
          unorderedEquals([first.id, second.id]),
        );
      },
    );
  });
}
