import 'package:flutter_test/flutter_test.dart';
import 'package:mileage_log/models/place.dart';
import 'package:mileage_log/services/cached_distance_service.dart';
import 'package:mileage_log/services/local_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

void main() {
  const a = Place(label: 'A', address: '1 A St', placeId: 'a');
  const b = Place(label: 'B', address: '2 B St', placeId: 'b');

  test(
    'measures each direction once and reuses it, even after restart',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final inner = FakeDistanceService(miles: 12.3);
      final cached = CachedDistanceService(inner, LocalStore(prefs));

      expect(await cached.drivingMiles(a, b), 12.3);
      expect(await cached.drivingMiles(a, b), 12.3);
      expect(inner.calls, 1);

      // Reverse direction is measured separately.
      await cached.drivingMiles(b, a);
      expect(inner.calls, 2);

      // A fresh store (app restart) still has the saved distance.
      final inner2 = FakeDistanceService(miles: 99);
      final afterRestart = CachedDistanceService(inner2, LocalStore(prefs));
      expect(await afterRestart.drivingMiles(a, b), 12.3);
      expect(inner2.calls, 0);
    },
  );

  test('failures are not cached', () async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    final failing = FakeDistanceService(fail: true);
    final cached = CachedDistanceService(failing, store);

    await expectLater(cached.drivingMiles(a, b), throwsA(anything));
    final working = CachedDistanceService(FakeDistanceService(miles: 4), store);
    expect(await working.drivingMiles(a, b), 4);
  });
}
