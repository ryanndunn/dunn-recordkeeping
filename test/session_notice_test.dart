import 'package:flutter_test/flutter_test.dart';
import 'package:mileage_log/background/arrival_handler.dart';
import 'package:mileage_log/models/job.dart';

void main() {
  final start = DateTime(2026, 11, 23, 9, 44);
  final running = Job(id: 'a', start: start, clients: const ['Orokawa Y']);
  final ended = running.copyWith(end: DateTime(2026, 11, 23, 11, 30));

  test('only sessions starting or ending notify', () {
    expect(sessionNotice(), isNull, reason: 'a trip on its own');

    final started = sessionNotice(started: running)!;
    expect(started.title, 'Session started at Orokawa Y');
    expect(started.body, contains('9:44 AM'));

    final done = sessionNotice(ended: ended, jobUploaded: true)!;
    expect(done.title, 'Session ended at Orokawa Y');
    expect(done.body, contains('ended 11:30 AM after 1 h 46 m'));
    expect(done.body, contains('spreadsheet'));

    final next = Job(
      id: 'b',
      start: DateTime(2026, 11, 23, 13),
      clients: const ['Duckpin'],
    );
    final both = sessionNotice(started: next, ended: ended)!;
    expect(both.title, 'New session at Duckpin');
    expect(both.body, contains('Started 1:00 PM'));
    expect(both.body, contains('at Orokawa Y ended 11:30 AM'));
  });
}
