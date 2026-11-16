import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/place.dart';
import '../models/saved_address.dart';
import '../models/trip.dart';
import 'start_point.dart';

/// How long you must stay at a place before it counts as arriving.
const arrivalStayTime = Duration(minutes: 5);

/// Geofence size. Android recommends 100–150 m for reliable detection.
const arrivalRadiusMeters = 150.0;

const homeFenceId = 'home';
const _addressPrefix = 'addr:';

String addressFenceId(String savedAddressId) =>
    '$_addressPrefix$savedAddressId';

/// What an arrival means: the trip to log, or null for "ignore".
({Place from, Place to})? decideAutoTrip({
  required String fenceId,
  required DateTime arrivedAt,
  required Place? home,
  required List<SavedAddress> saved,
  required List<Trip> trips,
}) {
  final Place? destination;
  if (fenceId == homeFenceId) {
    destination = home;
  } else if (fenceId.startsWith(_addressPrefix)) {
    final id = fenceId.substring(_addressPrefix.length);
    destination = saved.where((a) => a.id == id).firstOrNull?.toPlace();
  } else {
    destination = null;
  }
  if (destination == null) return null;

  final start = resolveStartPoint(trips: trips, home: home, now: arrivedAt);
  if (start == null) return null;

  // Already here (also stops repeat alerts for the same visit).
  if (isSamePlace(start, destination)) return null;

  // Home: only log the drive back after an appointment today. The start
  // is home itself when nothing was logged today, caught just above.
  return (from: start, to: destination);
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
