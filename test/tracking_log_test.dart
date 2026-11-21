import 'package:flutter_test/flutter_test.dart';
import 'package:mileage_log/services/tracking_log.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('keeps the newest events, newest first', () async {
    SharedPreferences.setMockInitialValues({});
    final start = DateTime(2026, 11, 20, 9);
    for (var i = 0; i < TrackingLog.keep + 5; i++) {
      await TrackingLog.add(
        'event $i | with a bar',
        at: start.add(Duration(minutes: i)),
      );
    }
    final prefs = await SharedPreferences.getInstance();
    final events = TrackingLog.read(prefs);
    expect(events, hasLength(TrackingLog.keep));
    expect(events.first.message, 'event ${TrackingLog.keep + 4} | with a bar');
    expect(events.last.message, 'event 5 | with a bar');
    expect(events.first.at, start.add(Duration(minutes: TrackingLog.keep + 4)));

    await TrackingLog.clear(prefs);
    expect(TrackingLog.read(prefs), isEmpty);
  });
}
