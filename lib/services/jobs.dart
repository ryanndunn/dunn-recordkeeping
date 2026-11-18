import '../models/job.dart';
import '../models/place.dart';
import '../models/saved_address.dart';
import '../models/trip.dart';
import 'address_matcher.dart';
import 'places_service.dart';
import 'start_point.dart';

/// What kind of place a stop is. Clients, donation centers and gas
/// stations keep a job going; anywhere else (home included) ends it.
enum StopKind { home, client, donation, gas, other }

bool keepsJobGoing(StopKind kind) =>
    kind == StopKind.client ||
    kind == StopKind.donation ||
    kind == StopKind.gas;

/// Average speed used to estimate when you left, if the phone didn't see
/// you leave (30 mph).
const estimateMilesPerHour = 30.0;

/// What a stop means for the mileage log and the job clock.
class StopDecision {
  const StopDecision({
    this.trip,
    this.startsJob = false,
    this.endsJob = false,
    this.departedAt,
  });

  /// Nothing to log (e.g. a donation drop-off on your own, or the same
  /// stop reported twice).
  static const none = StopDecision();

  /// The drive to log, if any.
  final ({Place from, Place to})? trip;

  /// This stop is the first client of a job.
  final bool startsJob;

  /// This stop ends the running job.
  final bool endsJob;

  /// When you left [trip]'s start, if the phone saw it. Used as the job's
  /// start time.
  final DateTime? departedAt;
}

/// Where the next drive starts: the later of the last stop the phone saw
/// today and the last trip logged today; otherwise home.
Place? currentStart({
  required List<Trip> trips,
  required PlaceVisit? lastStop,
  required Place? home,
  required DateTime now,
}) {
  Trip? latestTrip;
  for (final t in trips) {
    if (!isSameDay(t.date, now)) continue;
    if (latestTrip == null || !t.date.isBefore(latestTrip.date)) {
      latestTrip = t;
    }
  }
  final stop = lastStop != null && isSameDay(lastStop.at, now)
      ? lastStop
      : null;
  if (stop != null &&
      (latestTrip == null || stop.at.isAfter(latestTrip.date))) {
    return stop.place;
  }
  return latestTrip?.to ?? home;
}

/// The running job, if any. A job left open from an earlier day is not
/// running any more (see [closeStaleJobs]).
Job? activeJob(List<Job> jobs, DateTime now) {
  for (final j in jobs.reversed) {
    if (j.isActive) return isSameDay(j.start, now) ? j : null;
  }
  return null;
}

/// Ends jobs still open from an earlier day at their last stop.
List<Job> closeStaleJobs(List<Job> jobs, DateTime now) => [
  for (final j in jobs)
    j.isActive && !isSameDay(j.start, now)
        ? j.copyWith(end: j.lastActivity ?? j.start)
        : j,
];

/// The rules for a stop of [kind] at [place]:
///
/// * Not on a job: arriving at a client starts one (and logs the drive
///   there). Anywhere else is not a job, so nothing is logged.
/// * On a job: the drive is always logged. Clients, donation centers and
///   gas stations keep the job going; anywhere else ends it.
StopDecision decideStop({
  required StopKind kind,
  required Place place,
  required Place? start,
  required bool onJob,
  PlaceVisit? lastDeparture,
  required DateTime arrivedAt,
}) {
  if (start == null) return StopDecision.none;
  // Still at the same place (or the same stop reported twice).
  if (isSamePlace(start, place)) return StopDecision.none;

  final trip = (from: start, to: place);
  if (onJob) {
    return StopDecision(trip: trip, endsJob: !keepsJobGoing(kind));
  }
  if (kind != StopKind.client) return StopDecision.none;

  final left = lastDeparture;
  final departedAt =
      left != null &&
          isSamePlace(left.place, start) &&
          isSameDay(left.at, arrivedAt) &&
          left.at.isBefore(arrivedAt)
      ? left.at
      : null;
  return StopDecision(trip: trip, startsJob: true, departedAt: departedAt);
}

/// When the job started: when you left, or (not seen) the arrival time
/// less the drive at [estimateMilesPerHour].
({DateTime start, bool estimated}) jobStartTime({
  required DateTime? departedAt,
  required DateTime arrivedAt,
  required double miles,
}) {
  if (departedAt != null) return (start: departedAt, estimated: false);
  final minutes = (miles / estimateMilesPerHour * 60).round();
  return (
    start: arrivedAt.subtract(Duration(minutes: minutes)),
    estimated: true,
  );
}

/// Applies [decision] (whose drive measured [miles]) to the job list.
List<Job> applyStop({
  required List<Job> jobs,
  required StopDecision decision,
  required StopKind kind,
  required Place place,
  required DateTime arrivedAt,
  required double miles,
  required String Function() newId,
}) {
  var list = closeStaleJobs(jobs, arrivedAt);
  if (decision.trip == null) return list;
  final running = activeJob(list, arrivedAt);

  Job updated;
  if (running != null) {
    updated = running.copyWith(lastActivity: arrivedAt);
  } else if (decision.startsJob) {
    final start = jobStartTime(
      departedAt: decision.departedAt,
      arrivedAt: arrivedAt,
      miles: miles,
    );
    updated = Job(
      id: newId(),
      start: start.start,
      startEstimated: start.estimated,
      lastActivity: arrivedAt,
    );
    list = [...list, updated];
  } else {
    return list;
  }
  if (kind == StopKind.client) updated = updated.visiting(place.label);
  if (decision.endsJob) updated = updated.copyWith(end: arrivedAt);
  return [for (final j in list) j.id == updated.id ? updated : j];
}

/// Total miles of the trips logged during [job].
double jobMiles(Job job, List<Trip> trips) {
  final end = job.end ?? DateTime.now();
  var total = 0.0;
  for (final t in trips) {
    if (!t.date.isBefore(job.start) && !t.date.isAfter(end)) {
      total += t.miles;
    }
  }
  return (total * 10).round() / 10;
}

/// What [place] is: home, one of the clients' addresses, a donation
/// center, or something else. Matches by place ID, address, or (for a
/// position from the phone) within [radiusMeters].
({StopKind kind, Place place}) classifyKnownPlace(
  Place place, {
  required Place? home,
  required List<SavedAddress> clientStops,
  required List<SavedAddress> donationCenters,
  double radiusMeters = 150,
}) {
  bool near(Place a, Place b) {
    if (isSamePlace(a, b)) return true;
    if (!a.hasCoordinates || !b.hasCoordinates) return false;
    return AddressMatcher.distanceMeters(a.lat!, a.lng!, b.lat!, b.lng!) <=
        radiusMeters;
  }

  if (home != null && near(place, home)) {
    return (kind: StopKind.home, place: home);
  }
  for (final c in clientStops) {
    if (near(place, c.toPlace())) {
      return (kind: StopKind.client, place: c.toPlace());
    }
  }
  for (final d in donationCenters) {
    if (near(place, d.toPlace())) {
      return (kind: StopKind.donation, place: d.toPlace());
    }
  }
  return (kind: StopKind.other, place: place);
}

/// Names an unsaved stop from Google's nearby places (nearest first): a gas
/// station keeps the job going; otherwise the nearest place's name and
/// address, or [here] as is when Google found nothing.
({StopKind kind, Place place}) classifyNearby(
  Place here,
  List<NearbyPlace> nearby,
) {
  for (final n in nearby) {
    if (n.isGasStation) return (kind: StopKind.gas, place: n.place);
  }
  if (nearby.isEmpty) return (kind: StopKind.other, place: here);
  return (kind: StopKind.other, place: nearby.first.place);
}

String _two(int n) => n.toString().padLeft(2, '0');

/// "9:05 AM".
String formatClock(DateTime t) {
  final l = t.toLocal();
  final h = l.hour % 12 == 0 ? 12 : l.hour % 12;
  return '$h:${_two(l.minute)} ${l.hour < 12 ? 'AM' : 'PM'}';
}

/// "3 h 05 m", or "45 m" under an hour.
String formatHours(Duration d) {
  final minutes = d.inMinutes < 0 ? 0 : d.inMinutes;
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return h == 0 ? '$m m' : '$h h ${_two(m)} m';
}

/// [job] with its stops and miles, from this device's [trips].
JobSummary summarizeJob(Job job, List<Trip> trips, DateTime now) {
  final end = job.end ?? (job.isActive ? now : job.lastActivity ?? job.start);
  final during = [
    for (final t in trips)
      if (!t.date.isBefore(job.start) && !t.date.isAfter(end)) t,
  ]..sort((a, b) => a.date.compareTo(b.date));
  return JobSummary(
    job,
    miles: jobMiles(job.copyWith(end: end), trips),
    stops: [for (final t in during) t.to],
  );
}
