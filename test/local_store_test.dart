import 'package:flutter_test/flutter_test.dart';
import 'package:mileage_log/models/app_settings.dart';
import 'package:mileage_log/models/place.dart';
import 'package:mileage_log/models/saved_address.dart';
import 'package:mileage_log/models/trip.dart';
import 'package:mileage_log/services/local_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('addresses, trips and settings survive a save and reload', () async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());

    const address = SavedAddress(
      id: 'a1',
      name: 'Clinic',
      address: '1 Main St',
      lat: 1.5,
      lng: -2.5,
    );
    final trip = Trip(
      id: 't1',
      date: DateTime(2026, 11, 14, 9, 30),
      from: const Place(label: 'Home', address: '1 Home Rd'),
      to: address.toPlace(),
      miles: 12.3,
      notes: 'checkup',
    );
    const settings = AppSettings(
      home: Place(label: 'Home', address: '1 Home Rd'),
      navApp: NavApp.waze,
      ratePerMile: 0.7,
    );

    await store.saveAddresses([address]);
    await store.saveTrips([trip]);
    await store.saveSettings(settings);

    final reloaded = LocalStore(await SharedPreferences.getInstance());
    final a = reloaded.loadAddresses().single;
    expect(
      (a.id, a.name, a.address, a.lat, a.lng),
      ('a1', 'Clinic', '1 Main St', 1.5, -2.5),
    );

    final t = reloaded.loadTrips().single;
    expect(
      (t.id, t.date, t.from, t.to, t.miles, t.notes),
      (trip.id, trip.date, trip.from, trip.to, 12.3, 'checkup'),
    );

    final s = reloaded.loadSettings();
    expect(
      (s.home, s.navApp, s.ratePerMile),
      (settings.home, NavApp.waze, 0.7),
    );
  });

  test('empty store returns defaults', () async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    expect(store.loadAddresses(), isEmpty);
    expect(store.loadTrips(), isEmpty);
    expect(store.loadSettings().navApp, NavApp.googleMaps);
  });
}
