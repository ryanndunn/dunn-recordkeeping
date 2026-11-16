import 'package:flutter_test/flutter_test.dart';
import 'package:mileage_log/models/place.dart';
import 'package:mileage_log/models/saved_address.dart';
import 'package:mileage_log/models/trip.dart';
import 'package:mileage_log/services/auto_trip.dart';

void main() {
  const home = Place(label: 'Home', address: '1 Home Rd', placeId: 'h');
  const clinic = SavedAddress(
    id: 'c',
    name: 'Clinic',
    address: '2 Main St',
    placeId: 'pc',
    lat: 1,
    lng: 1,
  );
  const dentist = SavedAddress(
    id: 'd',
    name: 'Dentist',
    address: '3 Oak Ave',
    placeId: 'pd',
    lat: 2,
    lng: 2,
  );
  final saved = [clinic, dentist];
  final morning = DateTime(2026, 11, 16, 9);

  Trip trip(Place from, Place to, DateTime at) =>
      Trip(id: '${to.label}-$at', date: at, from: from, to: to, miles: 5);

  ({Place from, Place to})? decide(
    String fence,
    DateTime at,
    List<Trip> trips,
  ) => decideAutoTrip(
    fenceId: fence,
    arrivedAt: at,
    home: home,
    saved: saved,
    trips: trips,
  );

  test('first appointment of the day starts from home', () {
    final t = decide(addressFenceId('c'), morning, []);
    expect(t?.from, home);
    expect(t?.to, clinic.toPlace());
  });

  test('next appointment starts from the last one', () {
    final earlier = [trip(home, clinic.toPlace(), morning)];
    final t = decide(addressFenceId('d'), morning.add(_h(2)), earlier);
    expect(t?.from, clinic.toPlace());
    expect(t?.to, dentist.toPlace());
  });

  test('a repeat alert for the same visit is ignored', () {
    final earlier = [trip(home, clinic.toPlace(), morning)];
    expect(decide(addressFenceId('c'), morning.add(_h(1)), earlier), isNull);
  });

  test('arriving home after appointments logs the drive back', () {
    final earlier = [trip(home, clinic.toPlace(), morning)];
    final t = decide(homeFenceId, morning.add(_h(3)), earlier);
    expect(t?.from, clinic.toPlace());
    expect(t?.to, home);
  });

  test('arriving home with no appointment today is not a trip', () {
    expect(decide(homeFenceId, morning, []), isNull);
  });

  test('arriving home twice after returning is not logged twice', () {
    final earlier = [
      trip(home, clinic.toPlace(), morning),
      trip(clinic.toPlace(), home, morning.add(_h(2))),
    ];
    expect(decide(homeFenceId, morning.add(_h(5)), earlier), isNull);
  });

  test('yesterday\'s trips don\'t count; today starts from home', () {
    final yesterday = [trip(home, clinic.toPlace(), morning.subtract(_h(24)))];
    final t = decide(addressFenceId('c'), morning, yesterday);
    expect(t?.from, home);
  });

  test('an address that was deleted is ignored', () {
    expect(decide(addressFenceId('gone'), morning, []), isNull);
  });

  test('no home set and nothing logged today: nothing to measure from', () {
    expect(
      decideAutoTrip(
        fenceId: addressFenceId('c'),
        arrivedAt: morning,
        home: null,
        saved: saved,
        trips: const [],
      ),
      isNull,
    );
  });
}

Duration _h(int hours) => Duration(hours: hours);
