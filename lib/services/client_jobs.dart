import '../models/job.dart';
import '../models/place.dart';
import '../models/saved_address.dart';
import '../models/trip.dart';
import 'start_point.dart';

enum ClientJobState { upcoming, inProgress, completed }

/// One job on a client's page: booked ahead (upcoming), running now, or
/// done.
class ClientJobEntry {
  const ClientJobEntry({
    required this.state,
    required this.start,
    this.end,
    this.job,
    this.scheduled,
    this.miles = 0,
    this.otherClients = const [],
    this.places = const [],
    this.timeTracked = true,
  });

  final ClientJobState state;

  /// The booked time, the job's start, or (for trips logged before jobs
  /// were tracked) the day.
  final DateTime start;
  final DateTime? end;

  /// The tracked job, if the phone (or a trip logged by hand) recorded it.
  final Job? job;

  /// The booking, if the job was scheduled.
  final ScheduledJob? scheduled;

  /// Miles driven during the job (the whole job, all stops).
  final double miles;

  /// Other clients visited in the same job.
  final List<String> otherClients;

  /// The client's other addresses visited (e.g. "Storage unit").
  final List<String> places;

  /// False for days with trips but no tracked job time.
  final bool timeTracked;

  Duration? get duration => end?.difference(start);

  /// Scheduled, but no trip to the client was recorded that day.
  bool get noTrips => job == null && timeTracked && scheduled != null;
}

/// Everything on [client]'s Jobs list. Upcoming soonest first, then the
/// job in progress, then completed newest first. [jobs] come from both
/// devices (matched to the client by their stops); [trips] are this
/// device's, for days before jobs were tracked.
List<ClientJobEntry> clientJobs({
  required SavedAddress client,
  required List<JobSummary> jobs,
  required List<Trip> trips,
  required DateTime now,
}) {
  // The client's addresses: main (no label) and others (labelled).
  final places = <(Place, String?)>[
    (client.toPlace(), null),
    for (final l in client.locations)
      (Place(label: l.label, address: l.address, placeId: l.placeId), l.label),
  ];
  (bool, String?) visitPlace(Place to) {
    for (final (p, label) in places) {
      if (isSamePlace(to, p)) return (true, label);
    }
    return (false, null);
  }

  (bool, String?) visit(Trip t) => visitPlace(t.to);

  final toClient = [
    for (final t in trips)
      if (visit(t).$1) t,
  ];
  final unmatched = [...client.scheduled];
  final covered = <Trip>{};
  final entries = <ClientJobEntry>[];

  ScheduledJob? takeBooking(DateTime day) {
    final b = unmatched.where((s) => isSameDay(s.start, day)).firstOrNull;
    if (b != null) unmatched.remove(b);
    return b;
  }

  for (final summary in jobs) {
    final job = summary.job;
    final running = job.isActive && isSameDay(job.start, now);
    final end = job.end ?? (running ? now : (job.lastActivity ?? job.start));
    covered.addAll([
      for (final t in toClient)
        if (!t.date.isBefore(job.start) && !t.date.isAfter(end)) t,
    ]);
    final here = [
      for (final p in summary.stops)
        if (visitPlace(p).$1) p,
    ];
    if (here.isEmpty) continue;
    entries.add(
      ClientJobEntry(
        state: running ? ClientJobState.inProgress : ClientJobState.completed,
        start: job.start,
        end: running ? null : end,
        job: job,
        scheduled: takeBooking(job.start),
        miles: summary.miles,
        otherClients: [
          for (final c in job.clients)
            if (c != client.name && !c.startsWith('${client.name} (')) c,
        ],
        places: {
          for (final p in here)
            if (visitPlace(p).$2 case final String label) label,
        }.toList(),
      ),
    );
  }

  // Trips from before jobs were tracked: one entry per day.
  final byDay = <DateTime, List<Trip>>{};
  for (final t in toClient) {
    if (covered.contains(t)) continue;
    final l = t.date.toLocal();
    (byDay[DateTime(l.year, l.month, l.day)] ??= []).add(t);
  }
  for (final e in byDay.entries) {
    entries.add(
      ClientJobEntry(
        state: ClientJobState.completed,
        start: e.key,
        scheduled: takeBooking(e.key),
        miles:
            (e.value.fold<double>(0, (sum, t) => sum + t.miles) * 10).round() /
            10,
        places: {
          for (final t in e.value)
            if (visit(t).$2 case final String label) label,
        }.toList(),
        timeTracked: false,
      ),
    );
  }

  // Bookings with nothing recorded: upcoming from today on, else past.
  final today = DateTime(now.year, now.month, now.day);
  for (final b in unmatched) {
    entries.add(
      ClientJobEntry(
        state: b.start.isBefore(today)
            ? ClientJobState.completed
            : ClientJobState.upcoming,
        start: b.start,
        scheduled: b,
      ),
    );
  }

  int order(ClientJobEntry e) => e.state.index;
  entries.sort((a, b) {
    final byState = order(a).compareTo(order(b));
    if (byState != 0) return byState;
    return a.state == ClientJobState.upcoming
        ? a.start.compareTo(b.start)
        : b.start.compareTo(a.start);
  });
  return entries;
}
