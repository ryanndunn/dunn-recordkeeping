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
    double? driveMiles,
    this.otherClients = const [],
    this.places = const [],
    this.timeTracked = true,
    this.withClient,
  }) : driveMiles = driveMiles ?? miles;

  final ClientJobState state;

  /// The booked time, the job's start, or (for trips logged before jobs
  /// were tracked) the day.
  final DateTime start;
  final DateTime? end;

  /// The tracked job, if the phone (or a trip logged by hand) recorded it.
  final Job? job;

  /// The booking, if the job was scheduled.
  final ScheduledJob? scheduled;

  /// Miles driven between clients during the session.
  final double miles;

  /// All the driving for it, including the drive there and back.
  final double driveMiles;

  /// Other clients visited in the same job.
  final List<String> otherClients;

  /// The client's other addresses visited (e.g. "Storage unit").
  final List<String> places;

  /// False for days with trips but no tracked job time.
  final bool timeTracked;

  /// Time at this client's addresses (so far, if running). For sessions
  /// recorded before visits were kept, the whole session.
  final Duration? withClient;

  Duration? get duration => end?.difference(start);

  /// Keys this session's billing may be saved under, the one to save
  /// under first: the booking, the recorded session, or the day.
  List<String> get billingKeys => [
    if (scheduled != null) scheduled!.id,
    if (job != null) job!.id,
    if (scheduled == null && job == null)
      'day:${start.year}-${start.month}-${start.day}',
  ];

  /// Time with the client: as recorded, else as booked.
  Duration? get time => withClient ?? scheduled?.duration;

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
        withClient:
            job.timeWith(client.name, now) ??
            (running ? now : end).difference(job.start),
        scheduled: takeBooking(job.start),
        miles: summary.miles,
        driveMiles: summary.driveMiles,
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

/// [client]'s billing record for [e] (need to bill, if none yet).
SessionBilling billingFor(SavedAddress client, ClientJobEntry e) {
  for (final k in e.billingKeys) {
    final b = client.billing[k];
    if (b != null) return b;
  }
  return SessionBilling.unbilled;
}

/// What [e] bills: the booked time at [client]'s rate, or (not booked
/// with an end time) the time spent with them. Null if neither is known.
double? sessionAmount(SavedAddress client, ClientJobEntry e) {
  // Once paid, what was actually received.
  final paid = billingFor(client, e);
  if (paid.status == BillingStatus.paid && paid.amount != null) {
    return paid.amount;
  }
  final booked = e.scheduled?.billFor(client.hourlyRate);
  if (booked != null) return booked;
  final t = e.withClient;
  if (t == null) return null;
  return (t.inMinutes / 60 * client.hourlyRate * 100).round() / 100;
}

/// [client] with [e]'s billing set to [billing].
SavedAddress withBilling(
  SavedAddress client,
  ClientJobEntry e,
  SessionBilling billing,
) => client.copyWith(
  billing: {
    for (final x in client.billing.entries)
      if (!e.billingKeys.contains(x.key)) x.key: x.value,
    e.billingKeys.first: billing,
  },
);

/// One session of one client, with where it is in getting paid.
class SessionRow {
  const SessionRow({
    required this.client,
    required this.session,
    required this.billing,
    this.amount,
  });

  final SavedAddress client;
  final ClientJobEntry session;
  final SessionBilling billing;

  /// What it bills (or was paid), if known.
  final double? amount;

  BillingStatus get status => billing.status;

  /// The day it was paid, or else the session's day.
  DateTime get paidDay => billing.paidOn ?? session.start;
}

/// Every session of every client (as on their pages), with its billing:
/// to bill and billed oldest first, paid newest first.
List<SessionRow> allSessions({
  required List<SavedAddress> clients,
  required List<JobSummary> jobs,
  required List<Trip> trips,
  required DateTime now,
}) {
  final rows = [
    for (final c in clients)
      for (final e in clientJobs(client: c, jobs: jobs, trips: trips, now: now))
        SessionRow(
          client: c,
          session: e,
          billing: billingFor(c, e),
          amount: sessionAmount(c, e),
        ),
  ];
  rows.sort((a, b) {
    if (a.status != b.status) return a.status.index.compareTo(b.status.index);
    final byDate = a.status == BillingStatus.paid
        ? b.paidDay.compareTo(a.paidDay)
        : a.session.start.compareTo(b.session.start);
    return byDate != 0 ? byDate : a.client.name.compareTo(b.client.name);
  });
  return rows;
}
