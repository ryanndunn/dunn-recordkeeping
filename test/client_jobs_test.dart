import 'package:flutter_test/flutter_test.dart';
import 'package:mileage_log/models/job.dart';
import 'package:mileage_log/models/place.dart';
import 'package:mileage_log/models/saved_address.dart';
import 'package:mileage_log/models/trip.dart';
import 'package:mileage_log/services/client_jobs.dart';
import 'package:mileage_log/services/jobs.dart';

const home = Place(label: 'Home', address: '1 Home Rd', placeId: 'h');
const other = Place(label: 'Dentist', address: '3 Oak Ave', placeId: 'pd');

final jane = SavedAddress(
  id: 'j',
  name: 'Jane',
  address: '9 Elm St',
  placeId: 'elm',
  locations: const [
    ClientLocation(id: 's', label: 'Storage unit', address: '8 Depot Rd'),
  ],
  scheduled: [
    ScheduledJob(id: 'b1', start: DateTime(2026, 11, 17, 9)),
    ScheduledJob(id: 'b2', start: DateTime(2026, 11, 20, 13), notes: 'Attic'),
    ScheduledJob(id: 'b3', start: DateTime(2026, 11, 3, 10)),
  ],
);
final storage = const Place(
  label: 'Jane (Storage unit)',
  address: '8 Depot Rd',
);

Trip trip(String id, Place from, Place to, DateTime at, double miles) =>
    Trip(id: id, date: at, from: from, to: to, miles: miles);

void main() {
  final now = DateTime(2026, 11, 17, 15);

  test('jobs sort into upcoming, in progress and completed', () {
    final trips = [
      // Before job tracking: a day of trips only.
      trip('t0', home, jane.toPlace(), DateTime(2026, 11, 1, 9), 20),
      // A finished job with another client too.
      trip('t1', home, jane.toPlace(), DateTime(2026, 11, 10, 9), 20),
      trip('t2', jane.toPlace(), other, DateTime(2026, 11, 10, 12), 5),
      trip('t3', other, home, DateTime(2026, 11, 10, 14), 18),
      // Today's job, still running, at the storage unit.
      trip('t4', home, storage, DateTime(2026, 11, 17, 9, 30), 22),
      // Someone else's job.
      trip('t5', home, other, DateTime(2026, 11, 12, 9), 9),
    ];
    final jobs = [
      Job(
        id: 'done',
        start: DateTime(2026, 11, 10, 8, 30),
        end: DateTime(2026, 11, 10, 14),
        clients: const ['Jane', 'Dentist'],
      ),
      Job(
        id: 'other',
        start: DateTime(2026, 11, 12, 8, 40),
        end: DateTime(2026, 11, 12, 11),
        clients: const ['Dentist'],
      ),
      Job(
        id: 'now',
        start: DateTime(2026, 11, 17, 9),
        clients: const ['Jane (Storage unit)'],
      ),
    ];

    final list = clientJobs(
      client: jane,
      jobs: [for (final j in jobs) summarizeJob(j, trips, now)],
      trips: trips,
      now: now,
    );
    expect(
      [for (final e in list) (e.state, e.start)],
      [
        (ClientJobState.upcoming, DateTime(2026, 11, 20, 13)),
        (ClientJobState.inProgress, DateTime(2026, 11, 17, 9)),
        (ClientJobState.completed, DateTime(2026, 11, 10, 8, 30)),
        (ClientJobState.completed, DateTime(2026, 11, 3, 10)),
        (ClientJobState.completed, DateTime(2026, 11, 1)),
      ],
    );

    final running = list[1];
    expect(running.scheduled?.id, 'b1', reason: 'today\'s booking');
    expect(running.places, ['Storage unit']);
    expect(running.otherClients, isEmpty);

    final done = list[2];
    expect(done.duration, const Duration(hours: 5, minutes: 30));
    expect(done.miles, 43);
    expect(done.otherClients, ['Dentist']);

    expect(list[3].noTrips, isTrue, reason: 'booked, nothing recorded');
    expect(list[4].timeTracked, isFalse);
    expect(list[4].miles, 20);
  });

  test('bookings sync with the client', () {
    final back = SavedAddress.fromJson(jane.toJson());
    expect([for (final s in back.scheduled) s.id], ['b3', 'b1', 'b2']);
    expect(back.scheduled.last.start, DateTime(2026, 11, 20, 13));
    expect(back.scheduled.last.notes, 'Attic');
  });

  test('a job from the other device shows without its trips', () {
    // Recorded on the phone: the Mac has the summary, not the trips.
    final fromPhone = JobSummary(
      Job(
        id: 'p',
        start: DateTime(2026, 11, 12, 8),
        end: DateTime(2026, 11, 12, 11, 30),
        clients: const ['Jane'],
      ),
      miles: 41.5,
      stops: [jane.toPlace(), home],
    );
    final list = clientJobs(
      client: jane.copyWith(scheduled: const []),
      jobs: [fromPhone],
      trips: const [],
      now: now,
    );
    final done = list.single;
    expect(done.state, ClientJobState.completed);
    expect(done.miles, 41.5);
    expect(done.duration, const Duration(hours: 3, minutes: 30));
  });

  test('job summaries round-trip through the sync file', () {
    final s = JobSummary(
      Job(id: 'x', start: DateTime(2026, 11, 12, 8), clients: const ['Jane']),
      miles: 12.5,
      stops: [jane.toPlace()],
    );
    final back = JobSummary.fromJson(s.toJson());
    expect(back.job.start, s.job.start);
    expect(back.job.isActive, isTrue);
    expect(back.miles, 12.5);
    expect(back.stops.single.address, '9 Elm St');
    expect(s.toJson().containsKey('synced'), isFalse);
  });
}
