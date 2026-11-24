import '../models/job.dart';
import '../models/place.dart';
import '../models/saved_address.dart';
import '../models/trip.dart';
import 'address_matcher.dart';
import 'places_service.dart';
import 'start_point.dart';

/// What kind of place a stop is. Clients, donation centers and gas
/// stations keep a session going; anywhere else (home included) ends it.
enum StopKind { home, client, donation, gas, other }

bool keepsJobGoing(StopKind kind) =>
    kind == StopKind.client ||
    kind == StopKind.donation ||
    kind == StopKind.gas;

/// Average speed used to estimate when you left a client, if the phone
/// didn't see you leave (30 mph).
const estimateMilesPerHour = 30.0;

/// Time between leaving a client and arriving at the next one, beyond the
/// drive itself, that means you stopped somewhere the phone didn't catch
/// (a haircut, lunch): the session ended when you left, and the next
/// client starts a new one.
const unexplainedBreak = Duration(minutes: 30);

/// How long a drive of [miles] takes at [estimateMilesPerHour].
Duration driveTime(double miles) =>
    Duration(minutes: (miles / estimateMilesPerHour * 60).round());

/// True if arriving at [arrivedAt] after leaving at [departedAt] took
/// [unexplainedBreak] longer than a drive of [miles].
bool tookABreak({
  required DateTime? departedAt,
  required DateTime arrivedAt,
  required double miles,
}) {
  if (departedAt == null || miles <= 0) return false;
  final away = arrivedAt.difference(departedAt) - driveTime(miles);
  return away > unexplainedBreak;
}

/// What a stop means for the mileage log and the session clock.
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

  /// This stop is the first client of a session.
  final bool startsJob;

  /// This stop ends the running session.
  final bool endsJob;

  /// When you left [trip]'s start, if the phone saw it.
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

/// The running session, if any. One left open from an earlier day is not
/// running any more (see [closeStaleJobs]).
Job? activeJob(List<Job> jobs, DateTime now) {
  for (final j in jobs.reversed) {
    if (j.isActive) return isSameDay(j.start, now) ? j : null;
  }
  return null;
}

/// Ends sessions still open from an earlier day when you left the last
/// client (or, not seen, at the last stop).
List<Job> closeStaleJobs(List<Job> jobs, DateTime now) => [
  for (final j in jobs) j.isActive && !isSameDay(j.start, now) ? _closed(j) : j,
];

Job _closed(Job j) {
  final end = j.leftClientAt ?? j.lastActivity ?? j.start;
  return j.copyWith(end: end, visits: j.visitsLeftAt(end));
}

/// The rules for a stop of [kind] at [place]:
///
/// * Not in a session: arriving at a client starts one (and logs the
///   drive there). Anywhere else is not a session, so nothing is logged.
/// * In a session: the drive is always logged. Clients, donation centers
///   and gas stations keep the session going; anywhere else ends it.
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
  if (!onJob && kind != StopKind.client) return StopDecision.none;

  final left = lastDeparture;
  final departedAt =
      left != null &&
          isSamePlace(left.place, start) &&
          isSameDay(left.at, arrivedAt) &&
          left.at.isBefore(arrivedAt)
      ? left.at
      : null;
  final trip = (from: start, to: place);
  if (onJob) {
    return StopDecision(
      trip: trip,
      endsJob: !keepsJobGoing(kind),
      departedAt: departedAt,
    );
  }
  return StopDecision(trip: trip, startsJob: true, departedAt: departedAt);
}

/// When you left the place a drive of [miles] started from: as the phone
/// saw it, or the arrival less the drive at [estimateMilesPerHour] (never
/// before [notBefore]).
DateTime departureTime({
  required DateTime? departedAt,
  required DateTime arrivedAt,
  required double miles,
  DateTime? notBefore,
}) {
  if (departedAt != null) return departedAt;
  final t = arrivedAt.subtract(driveTime(miles));
  return notBefore != null && t.isBefore(notBefore) ? notBefore : t;
}

/// Applies [decision] (whose drive measured [miles]) to the session list.
/// A session starts on arriving at the first client and ends when you
/// left the last one. Arriving at a client long after leaving the last
/// stop (see [tookABreak]) ends the session at that departure and starts
/// a new one, in case the phone missed a stop in between.
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
  var running = activeJob(list, arrivedAt);
  final left = decision.departedAt;
  var startsJob = decision.startsJob;
  if (running != null &&
      left != null &&
      kind == StopKind.client &&
      tookABreak(departedAt: left, arrivedAt: arrivedAt, miles: miles)) {
    final end = running.endingAt(left);
    final closed = running.copyWith(
      end: end,
      leftClientAt: running.atClient ? left : null,
      visits: running.visitsLeftAt(end),
      atClient: false,
    );
    list = [for (final j in list) j.id == closed.id ? closed : j];
    running = null;
    startsJob = true;
  }

  Job updated;
  if (running != null) {
    updated = running.copyWith(lastActivity: arrivedAt);
    // This drive left a client: their time ended when you left.
    if (running.atClient) {
      final left = departureTime(
        departedAt: decision.departedAt,
        arrivedAt: arrivedAt,
        miles: miles,
        notBefore: running.lastActivity ?? running.start,
      );
      updated = updated.copyWith(
        leftClientAt: left,
        visits: running.visitsLeftAt(left),
      );
    }
  } else if (startsJob) {
    updated = Job(id: newId(), start: arrivedAt, lastActivity: arrivedAt);
    list = [...list, updated];
  } else {
    return list;
  }
  updated = kind == StopKind.client
      ? updated
            .visiting(place.label)
            .copyWith(
              atClient: true,
              visits: [...updated.visits, ClientVisit(place.label, arrivedAt)],
            )
      : updated.copyWith(atClient: false);
  if (decision.endsJob) {
    updated = updated.copyWith(end: updated.endingAt(arrivedAt));
  }
  return [for (final j in list) j.id == updated.id ? updated : j];
}

/// The phone left [place] (of [kind]) at [at]: if that was the client
/// you're with, their time ends there (unless you come back).
List<Job> applyDeparture({
  required List<Job> jobs,
  required StopKind kind,
  required DateTime at,
}) {
  final running = activeJob(jobs, at);
  if (running == null || !running.atClient || kind != StopKind.client) {
    return jobs;
  }
  final updated = running.copyWith(
    leftClientAt: at,
    visits: running.visitsLeftAt(at),
  );
  return [for (final j in jobs) j.id == running.id ? updated : j];
}

/// Miles driven during [job]: the drives between clients (and to any
/// donation or gas stops between them), not the drive to the first
/// client or home from the last.
double jobMiles(Job job, List<Trip> trips) {
  final end = job.end ?? DateTime.now();
  var total = 0.0;
  for (final t in trips) {
    if (t.date.isAfter(job.start) && !t.date.isAfter(end)) total += t.miles;
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
  bool near(Place a, Place b, [double? within]) {
    if (isSamePlace(a, b)) return true;
    if (!a.hasCoordinates || !b.hasCoordinates) return false;
    return AddressMatcher.distanceMeters(a.lat!, a.lng!, b.lat!, b.lng!) <=
        (within ?? radiusMeters);
  }

  if (home != null && near(place, home)) {
    return (kind: StopKind.home, place: home);
  }
  for (final c in clientStops) {
    // A big property (a school) counts from farther away.
    if (near(place, c.toPlace(), c.largeSite ? largeSiteMeters : null)) {
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

/// How close a gas station must be to a stop, if something else is
/// nearer, for the stop to count as getting gas. Pumps are usually
/// farther from the station's map pin than a shop is from its own.
const gasStationMeters = 35.0;

/// Names an unsaved stop from Google's nearby places (nearest first): at a
/// gas station it keeps the job going; otherwise it's named after the
/// nearest place, or keeps [here] as is when Google found nothing.
///
/// Only the nearest place, or a station right at the stop, counts as gas:
/// a barber or restaurant next door to a gas station is not a gas stop.
({StopKind kind, Place place}) classifyNearby(
  Place here,
  List<NearbyPlace> nearby,
) {
  if (nearby.isEmpty) return (kind: StopKind.other, place: here);
  final nearest = nearby.first;
  if (nearest.isGasStation) return (kind: StopKind.gas, place: nearest.place);
  for (final n in nearby) {
    if (n.isGasStation && _within(here, n.place, gasStationMeters)) {
      return (kind: StopKind.gas, place: n.place);
    }
  }
  return (kind: StopKind.other, place: nearest.place);
}

bool _within(Place a, Place b, double meters) =>
    a.hasCoordinates &&
    b.hasCoordinates &&
    AddressMatcher.distanceMeters(a.lat!, a.lng!, b.lat!, b.lng!) <= meters;

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

/// [job] with its stops (the first client included) and miles, from this
/// device's [trips].
JobSummary summarizeJob(Job job, List<Trip> trips, DateTime now) {
  final end = job.end ?? (job.isActive ? now : job.lastActivity ?? job.start);
  final during = [
    for (final t in trips)
      if (!t.date.isBefore(job.start) && !t.date.isAfter(end)) t,
  ]..sort((a, b) => a.date.compareTo(b.date));
  // The drive there arrives as it starts; the drive away from the last
  // client arrives at the stop that ended it (its last activity).
  final last = job.lastActivity;
  final until = last != null && last.isAfter(end) ? last : end;
  var drive = 0.0;
  for (final t in trips) {
    if (!t.date.isBefore(job.start) && !t.date.isAfter(until)) {
      drive += t.miles;
    }
  }
  return JobSummary(
    job,
    miles: jobMiles(job.copyWith(end: end), trips),
    stops: [for (final t in during) t.to],
    driveMiles: (drive * 10).round() / 10,
  );
}
