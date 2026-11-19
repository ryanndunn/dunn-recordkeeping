import 'package:flutter_test/flutter_test.dart';
import 'package:mileage_log/services/google_calendar.dart';

void main() {
  ({DateTime start, DateTime end}) at(int h1, int m1, int h2, int m2) => (
    start: DateTime(2026, 11, 14, h1, m1),
    end: DateTime(2026, 11, 14, h2, m2),
  );

  test('events that overlap sit side by side; others take the full width', () {
    final layout = layoutOverlaps([
      at(9, 0, 10, 0), // A
      at(9, 30, 11, 0), // B overlaps A
      at(10, 0, 10, 30), // C overlaps B, fits under A
      at(12, 0, 13, 0), // D alone
    ]);
    expect(layout[0], (column: 0, columns: 2));
    expect(layout[1], (column: 1, columns: 2));
    expect(layout[2], (column: 0, columns: 2));
    expect(layout[3], (column: 0, columns: 1));
  });

  test('back-to-back events don\'t share the width', () {
    final layout = layoutOverlaps([at(9, 0, 10, 0), at(10, 0, 11, 0)]);
    expect(layout, [(column: 0, columns: 1), (column: 0, columns: 1)]);
  });
}
