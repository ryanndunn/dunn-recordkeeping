import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mileage_log/models/place.dart';
import 'package:mileage_log/models/trip.dart';
import 'package:mileage_log/services/auto_trip.dart';
import 'package:mileage_log/services/local_store.dart';
import 'package:mileage_log/services/secret_store.dart';
import 'package:mileage_log/state/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

class FakeGeofences implements GeofencePlatform {
  bool granted = true;
  bool hasPermission = false;
  Map<String, Place> fences = {};
  int requests = 0;

  @override
  Future<bool> hasBackgroundLocation() async => hasPermission;

  @override
  Future<bool> requestPermissions() async {
    requests++;
    hasPermission = granted;
    return granted;
  }

  @override
  Future<void> setFences(Map<String, Place> f) async => fences = {...f};

  @override
  Future<void> clearFences() async => fences = {};
}

const home = Place(
  label: 'Home',
  address: '1 Home Rd',
  placeId: 'h',
  lat: 40,
  lng: -89,
);
const clinic = Place(
  label: 'Clinic',
  address: '2 Main St',
  placeId: 'c',
  lat: 40.1,
  lng: -89.1,
);

Future<(ProviderContainer, FakeGeofences, AutoTripInbox)> setUpApp({
  FakeDistanceService? distance,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final geofences = FakeGeofences();
  final inbox = AutoTripInbox(prefs);
  final container = ProviderContainer(
    overrides: [
      localStoreProvider.overrideWithValue(LocalStore(prefs)),
      autoTripInboxProvider.overrideWithValue(inbox),
      secretStoreProvider.overrideWithValue(MemorySecretStore()),
      geofencePlatformProvider.overrideWithValue(geofences),
      distanceServiceProvider.overrideWithValue(
        distance ?? FakeDistanceService(miles: 7.5),
      ),
      clockProvider.overrideWithValue(() => DateTime(2026, 11, 16, 12)),
    ],
  );
  addTearDown(container.dispose);
  return (container, geofences, inbox);
}

void main() {
  group('watching places', () {
    test(
      'turning on asks for permission and watches home + addresses',
      () async {
        final (app, geofences, _) = await setUpApp();
        await app.read(settingsProvider.notifier).setHome(home);
        await app
            .read(addressesProvider.notifier)
            .add(name: 'Clinic', place: clinic);
        await app
            .read(addressesProvider.notifier)
            .add(
              name: 'Old typed one',
              place: const Place(label: 'x', address: '9 Typed St'),
            );

        await app.read(autoTripProvider.notifier).enable();

        final state = app.read(autoTripProvider);
        expect(geofences.requests, 1);
        expect(state.enabled, isTrue);
        expect(state.permissionOk, isTrue);
        expect(state.watching, 2);
        expect(state.skipped, 1, reason: 'no map position to watch');
        expect(geofences.fences.keys, contains(homeFenceId));
        expect(geofences.fences.values, contains(clinic));
        expect(app.read(localStoreProvider).autoTripsEnabled, isTrue);
      },
    );

    test('a newly saved address is watched right away', () async {
      final (app, geofences, _) = await setUpApp();
      await app.read(settingsProvider.notifier).setHome(home);
      await app.read(autoTripProvider.notifier).enable();
      expect(geofences.fences, hasLength(1));

      await app
          .read(addressesProvider.notifier)
          .add(name: 'Clinic', place: clinic);
      await Future<void>.delayed(Duration.zero);
      expect(geofences.fences, hasLength(2));
    });

    test(
      'denied "Allow all the time" leaves it off with an explanation',
      () async {
        final (app, geofences, _) = await setUpApp();
        geofences.granted = false;
        await app.read(autoTripProvider.notifier).enable();
        final state = app.read(autoTripProvider);
        expect(state.enabled, isFalse);
        expect(state.message, contains('Allow all the time'));
        expect(geofences.fences, isEmpty);
      },
    );

    test('turning off stops watching', () async {
      final (app, geofences, _) = await setUpApp();
      await app.read(settingsProvider.notifier).setHome(home);
      await app.read(autoTripProvider.notifier).enable();
      await app.read(autoTripProvider.notifier).disable();
      expect(geofences.fences, isEmpty);
      expect(app.read(localStoreProvider).autoTripsEnabled, isFalse);
    });
  });

  group('trips detected in the background', () {
    Trip detected(String id, {bool synced = false}) => Trip(
      id: id,
      date: DateTime(2026, 11, 16, 10),
      from: home,
      to: clinic,
      miles: 12,
      synced: synced,
    );

    test('are added to the app once, keeping their upload status', () async {
      final (app, _, inbox) = await setUpApp();
      await inbox.add(InboxTrip(detected('a', synced: true)));
      await inbox.add(InboxTrip(detected('b')));

      expect(await app.read(tripsProvider.notifier).mergeInbox(), 2);
      final trips = app.read(tripsProvider);
      expect(trips.map((t) => t.id), ['a', 'b']);
      expect(trips.firstWhere((t) => t.id == 'a').synced, isTrue);
      expect(trips.firstWhere((t) => t.id == 'b').synced, isFalse);
      expect(await inbox.load(), isEmpty);

      // Nothing new the second time.
      expect(await app.read(tripsProvider.notifier).mergeInbox(), 0);
    });

    test('trips logged offline get their miles measured when added', () async {
      final (app, _, inbox) = await setUpApp();
      await inbox.add(InboxTrip(detected('x'), needsMiles: true));
      await app.read(tripsProvider.notifier).mergeInbox();
      expect(app.read(tripsProvider).single.miles, 7.5);
    });

    test('still offline: they wait in the inbox', () async {
      final (app, _, inbox) = await setUpApp(
        distance: FakeDistanceService(fail: true),
      );
      await inbox.add(InboxTrip(detected('x'), needsMiles: true));
      expect(await app.read(tripsProvider.notifier).mergeInbox(), 0);
      expect(await inbox.load(), hasLength(1));
    });

    test('a manual trip starts from the last detected stop', () async {
      final (app, _, inbox) = await setUpApp();
      await app.read(settingsProvider.notifier).setHome(home);
      await inbox.add(InboxTrip(detected('auto')));

      const dentist = Place(label: 'Dentist', address: '3 Oak', placeId: 'd');
      final manual = await app.read(tripsProvider.notifier).logTripTo(dentist);
      expect(manual.from, clinic);
    });
  });
}
