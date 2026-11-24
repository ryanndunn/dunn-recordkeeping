import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/job.dart';
import '../models/place.dart';
import '../models/saved_address.dart';
import '../models/trip.dart';
import 'distance_service.dart';
import 'jobs.dart';
import 'local_store.dart';

/// How long you must stay at a place before it counts as arriving.
const arrivalStayTime = Duration(minutes: 5);

/// Geofence size. Android recommends 100–150 m for reliable detection.
/// Clients' big properties (schools, campuses) use [largeSiteMeters].
const arrivalRadiusMeters = normalSiteMeters;

/// A watched place and how near it counts as being there.
typedef Fence = ({Place place, double radius});

const homeFenceId = 'home';
const _addressPrefix = 'addr:';
const _donationPrefix = 'don:';

String addressFenceId(String savedAddressId) =>
    '$_addressPrefix$savedAddressId';

String donationFenceId(String donationCenterId) =>
    '$_donationPrefix$donationCenterId';

/// The place a geofence watches and what kind it is, or null if it was
/// deleted since.
({StopKind kind, Place place})? placeForFence(
  String fenceId, {
  required Place? home,
  required List<SavedAddress> clientStops,
  required List<SavedAddress> donationCenters,
}) {
  if (fenceId == homeFenceId) {
    return home == null ? null : (kind: StopKind.home, place: home);
  }
  if (fenceId.startsWith(_addressPrefix)) {
    final id = fenceId.substring(_addressPrefix.length);
    final c = clientStops.where((a) => a.id == id).firstOrNull;
    return c == null ? null : (kind: StopKind.client, place: c.toPlace());
  }
  if (fenceId.startsWith(_donationPrefix)) {
    final id = fenceId.substring(_donationPrefix.length);
    final d = donationCenters.where((a) => a.id == id).firstOrNull;
    return d == null ? null : (kind: StopKind.donation, place: d.toPlace());
  }
  return null;
}

/// What happened at a stop.
class StopOutcome {
  const StopOutcome({
    this.trip,
    this.needsMiles = false,
    this.startedJob,
    this.endedJob,
  });

  /// The drive logged (null if the stop wasn't part of a job).
  final Trip? trip;

  /// Google couldn't be reached to measure [trip] yet.
  final bool needsMiles;
  final Job? startedJob;
  final Job? endedJob;
}

/// Applies the job rules (see [decideStop]) to a stop of [kind] at
/// [place]: logs the drive into [inbox] (for the app to pick up),
/// starts or ends the job, and remembers the stop as where the next drive
/// starts. Used by the phone's background handlers.
Future<StopOutcome> recordStop({
  required LocalStore store,
  required AutoTripInbox inbox,
  required DistanceService distance,
  required StopKind kind,
  required Place place,
  required DateTime arrivedAt,
  required String Function() newId,
}) async {
  await store.reload();
  final waiting = await inbox.load();
  final trips = [...store.loadTrips(), for (final e in waiting) e.trip];
  final jobs = closeStaleJobs(store.loadJobs(), arrivedAt);
  final start = currentStart(
    trips: trips,
    lastStop: store.lastStop,
    home: store.loadSettings().home,
    now: arrivedAt,
  );
  final decision = decideStop(
    kind: kind,
    place: place,
    start: start,
    onJob: activeJob(jobs, arrivedAt) != null,
    lastDeparture: store.lastDeparture,
    arrivedAt: arrivedAt,
  );
  await store.setLastStop(PlaceVisit(place, arrivedAt));
  final drive = decision.trip;
  if (drive == null) {
    await store.saveJobs(jobs);
    return const StopOutcome();
  }

  var miles = 0.0;
  var needsMiles = false;
  try {
    miles = await distance.drivingMiles(drive.from, drive.to);
  } catch (_) {
    needsMiles = true; // Offline: the app measures it later.
  }
  final trip = Trip(
    id: newId(),
    date: arrivedAt,
    from: drive.from,
    to: drive.to,
    miles: miles,
    estimated: distance.isDemo,
  );
  await inbox.add(InboxTrip(trip, needsMiles: needsMiles));

  final before = {for (final j in jobs) j.id: j};
  final after = applyStop(
    jobs: jobs,
    decision: decision,
    kind: kind,
    place: place,
    arrivedAt: arrivedAt,
    miles: miles,
    newId: newId,
  );
  await store.saveJobs(after);
  return StopOutcome(
    trip: trip,
    needsMiles: needsMiles,
    startedJob: after.where((j) => !before.containsKey(j.id)).firstOrNull,
    endedJob: after
        .where((j) => !j.isActive && (before[j.id]?.isActive ?? false))
        .firstOrNull,
  );
}

/// A trip the phone detected while the app wasn't open, waiting to be
/// added to the app's trip list. [needsMiles] means Google couldn't be
/// reached to measure it yet.
class InboxTrip {
  const InboxTrip(this.trip, {this.needsMiles = false});

  final Trip trip;
  final bool needsMiles;

  Map<String, dynamic> toJson() => {
    'trip': trip.toJson(),
    if (needsMiles) 'needsMiles': true,
  };

  factory InboxTrip.fromJson(Map<String, dynamic> json) => InboxTrip(
    Trip.fromJson(json['trip'] as Map<String, dynamic>),
    needsMiles: json['needsMiles'] as bool? ?? false,
  );
}

/// Hand-off between the background arrival handler (adds) and the app
/// (merges into its trip list and removes). Kept separate from the trip
/// list so the two never overwrite each other's changes.
class AutoTripInbox {
  AutoTripInbox(this._prefs);

  final SharedPreferences _prefs;
  static const _key = 'auto_trip_inbox_v1';

  /// Re-reads storage, since the other side may have written meanwhile.
  Future<List<InboxTrip>> load() async {
    await _prefs.reload();
    final raw = _prefs.getString(_key);
    if (raw == null) return [];
    return [
      for (final e in jsonDecode(raw) as List)
        InboxTrip.fromJson(e as Map<String, dynamic>),
    ];
  }

  Future<void> add(InboxTrip entry) async {
    final all = await load();
    await _save([...all.where((e) => e.trip.id != entry.trip.id), entry]);
  }

  /// Removes entries by trip ID (after the app has taken them).
  Future<void> remove(Set<String> tripIds) async {
    final all = await load();
    await _save([
      for (final e in all)
        if (!tripIds.contains(e.trip.id)) e,
    ]);
  }

  Future<void> replace(InboxTrip entry) => add(entry);

  Future<void> _save(List<InboxTrip> entries) =>
      _prefs.setString(_key, jsonEncode([for (final e in entries) e.toJson()]));
}
