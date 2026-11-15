import 'package:flutter_test/flutter_test.dart';
import 'package:mileage_log/models/place.dart';
import 'package:mileage_log/models/trip.dart';
import 'package:mileage_log/services/start_point.dart';

void main() {
  const home = Place(label: 'Home', address: '1 Home Rd');
  const a = Place(label: 'A', address: '10 A St');
  const b = Place(label: 'B', address: '20 B St');

  Trip trip(String id, DateTime date, Place to) =>
      Trip(id: id, date: date, from: home, to: to, miles: 5);

  final now = DateTime(2026, 11, 14, 15);

  test('first trip of the day starts from home', () {
    expect(resolveStartPoint(trips: [], home: home, now: now), home);
  });

  test('ignores trips from yesterday', () {
    final trips = [trip('1', DateTime(2026, 11, 13, 17), a)];
    expect(resolveStartPoint(trips: trips, home: home, now: now), home);
  });

  test('later trips start from the most recent stop today', () {
    final trips = [
      trip('2', DateTime(2026, 11, 14, 13), b),
      trip('1', DateTime(2026, 11, 14, 9), a),
    ];
    expect(resolveStartPoint(trips: trips, home: home, now: now), b);
  });

  test('on a time tie, the most recently logged trip wins', () {
    final t = DateTime(2026, 11, 14, 10);
    final trips = [trip('1', t, a), trip('2', t, b)];
    expect(resolveStartPoint(trips: trips, home: home, now: now), b);
  });

  test('returns null with no home and no trips today', () {
    expect(resolveStartPoint(trips: [], home: null, now: now), isNull);
  });
}
