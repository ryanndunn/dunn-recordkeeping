import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../models/app_settings.dart';
import '../models/place.dart';
import '../models/saved_address.dart';
import '../models/trip.dart';
import '../services/address_matcher.dart';
import '../services/cached_distance_service.dart';
import '../services/distance_service.dart';
import '../services/local_store.dart';
import '../services/places_service.dart';
import '../services/routes_distance_service.dart';
import '../services/secret_store.dart';
import '../services/jobs.dart';
import '../services/start_point.dart';
import '../services/auto_trip.dart';
import 'jobs_provider.dart';
import 'sync_provider.dart';

export 'auto_trip_provider.dart';
export 'jobs_provider.dart';
export 'sync_provider.dart';

const _uuid = Uuid();

/// Overridden in main() once SharedPreferences has loaded.
final localStoreProvider = Provider<LocalStore>(
  (ref) => throw UnimplementedError('localStoreProvider must be overridden'),
);

/// Google driving distance (cached on the device) once an API key is set;
/// a rough estimate until then.
final distanceServiceProvider = Provider<DistanceService>((ref) {
  final key = ref.watch(apiKeyProvider);
  if (key == null) return const DemoDistanceService();
  final client = http.Client();
  ref.onDispose(client.close);
  return CachedDistanceService(
    RoutesDistanceService(apiKey: key, client: client),
    ref.read(localStoreProvider),
  );
});

final addressMatcherProvider = Provider<AddressMatcher>(
  (ref) => const AddressMatcher(),
);

/// Injectable clock so tests can control "today".
final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Trips detected in the background, waiting to be added. Overridden in
/// main(); null in tests that don't need it.
final autoTripInboxProvider = Provider<AutoTripInbox?>((ref) => null);

/// Overridden in main() once secure storage has been read.
final secretStoreProvider = Provider<SecretStore>(
  (ref) => throw UnimplementedError('secretStoreProvider must be overridden'),
);

// ------------------------------------------------------------- Google key

final apiKeyProvider = NotifierProvider<ApiKeyNotifier, String?>(
  ApiKeyNotifier.new,
);

class ApiKeyNotifier extends Notifier<String?> {
  @override
  String? build() => ref.read(secretStoreProvider).apiKey;

  /// Saves a key the user typed on this device, and syncs it.
  Future<void> set(String? key) async {
    await _store(key);
    await ref.read(settingsProvider.notifier).stamp(SyncedField.apiKey);
  }

  /// Saves a key that arrived from the other device (no re-sync).
  Future<void> setFromSync(String? key) => _store(key);

  Future<void> _store(String? key) async {
    final store = ref.read(secretStoreProvider);
    await store.setApiKey(key);
    state = store.apiKey;
  }
}

/// Google address search, or null until an API key is entered in Settings.
final placesServiceProvider = Provider<PlacesService?>((ref) {
  final key = ref.watch(apiKeyProvider);
  if (key == null) return null;
  final client = http.Client();
  ref.onDispose(client.close);
  return GooglePlacesService(apiKey: key, client: client);
});

// ---------------------------------------------------------------- addresses

final addressesProvider =
    NotifierProvider<AddressesNotifier, List<SavedAddress>>(
      AddressesNotifier.new,
    );

/// A list of named, Google-verified places that syncs between devices:
/// clients, or donation centers.
abstract class SyncedPlacesNotifier extends Notifier<List<SavedAddress>> {
  List<SavedAddress> load(LocalStore store);
  Future<void> save(LocalStore store, List<SavedAddress> list);
  Map<String, DateTime> loadDeletions(LocalStore store);
  Future<void> saveDeletions(LocalStore store, Map<String, DateTime> d);

  LocalStore get _store => ref.read(localStoreProvider);

  @override
  List<SavedAddress> build() => load(_store);

  Future<void> replace(SavedAddress updated) async {
    final stamped = updated.copyWith(updatedAt: _now());
    await _set([for (final a in state) a.id == updated.id ? stamped : a]);
    _changed();
  }

  /// Deletes an entry here and, through sync, on the other device.
  Future<void> remove(String id) async {
    await saveDeletions(_store, {...loadDeletions(_store), id: _now()});
    await _set([
      for (final a in state)
        if (a.id != id) a,
    ]);
    _changed();
  }

  /// Replaces the list with one merged from the other device (no re-sync).
  Future<void> replaceFromSync(
    List<SavedAddress> list,
    Map<String, DateTime> deletions,
  ) async {
    await saveDeletions(_store, deletions);
    await _set(list);
  }

  Future<SavedAddress> _insert(SavedAddress created) async {
    await _set([...state, created]);
    _changed();
    return created;
  }

  DateTime _now() => ref.read(clockProvider)().toUtc();

  void _changed() => ref.read(syncProvider.notifier).localChanged();

  Future<void> _set(List<SavedAddress> next) async {
    state = next;
    await save(_store, next);
  }
}

class AddressesNotifier extends SyncedPlacesNotifier {
  @override
  List<SavedAddress> load(LocalStore store) => store.loadAddresses();
  @override
  Future<void> save(LocalStore store, List<SavedAddress> list) =>
      store.saveAddresses(list);
  @override
  Map<String, DateTime> loadDeletions(LocalStore store) =>
      store.loadClientDeletions();
  @override
  Future<void> saveDeletions(LocalStore store, Map<String, DateTime> d) =>
      store.saveClientDeletions(d);

  /// Saves a client at a Google-verified [place].
  Future<SavedAddress> add({
    required String name,
    required Place place,
    String email = '',
    String phone = '',
  }) => _insert(
    SavedAddress(
      id: _uuid.v4(),
      name: name.trim(),
      address: place.address,
      email: email.trim(),
      phone: phone.trim(),
      placeId: place.placeId,
      lat: place.lat,
      lng: place.lng,
      storedStatus: ClientStatus.newClient,
      updatedAt: _now(),
    ),
  );
}

// --------------------------------------------------------- donation centers

final donationCentersProvider =
    NotifierProvider<DonationCentersNotifier, List<SavedAddress>>(
      DonationCentersNotifier.new,
    );

/// Where donated items are dropped off. Stopping at one during a job keeps
/// the job going; a trip there on its own isn't a job.
class DonationCentersNotifier extends SyncedPlacesNotifier {
  @override
  List<SavedAddress> load(LocalStore store) => store.loadDonationCenters();
  @override
  Future<void> save(LocalStore store, List<SavedAddress> list) =>
      store.saveDonationCenters(list);
  @override
  Map<String, DateTime> loadDeletions(LocalStore store) =>
      store.loadDonationDeletions();
  @override
  Future<void> saveDeletions(LocalStore store, Map<String, DateTime> d) =>
      store.saveDonationDeletions(d);

  Future<SavedAddress> add({required String name, required Place place}) =>
      _insert(
        SavedAddress(
          id: _uuid.v4(),
          name: name.trim(),
          address: place.address,
          placeId: place.placeId,
          lat: place.lat,
          lng: place.lng,
          updatedAt: _now(),
        ),
      );
}

// ----------------------------------------------------------------- settings

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.read(localStoreProvider).loadSettings();

  Future<void> setHome(Place home) =>
      _change(SyncedField.home, state.copyWith(home: home));

  Future<void> setNavApp(NavApp navApp) =>
      _change(SyncedField.navApp, state.copyWith(navApp: navApp));

  Future<void> setRatePerMile(double? rate) => _change(
    SyncedField.ratePerMile,
    rate == null
        ? state.copyWith(clearRatePerMile: true)
        : state.copyWith(ratePerMile: rate),
  );

  Future<void> setBookingUrl(String? url) => _change(
    SyncedField.bookingUrl,
    url == null
        ? state.copyWith(clearBookingUrl: true)
        : state.copyWith(bookingUrl: url),
  );

  Future<void> setPolicyDocName(String name) =>
      _change(SyncedField.policyDocName, state.copyWith(policyDocName: name));

  /// Marks [field] as just changed on this device (for settings kept
  /// elsewhere, like the API key) and syncs.
  Future<void> stamp(String field) => _change(field, state);

  /// Records a newly created spreadsheet. Called from inside a sync, which
  /// uploads it to the other device itself.
  Future<void> setSpreadsheetId(String id) => _save(
    AppSettings(
      home: state.home,
      navApp: state.navApp,
      ratePerMile: state.ratePerMile,
      spreadsheetId: id,
      bookingUrl: state.bookingUrl,
      policyDocName: state.policyDocName,
      changedAt: state.changedAt,
    ).stamped(SyncedField.spreadsheetId, ref.read(clockProvider)()),
  );

  /// Replaces settings with ones merged from the other device (no re-sync).
  Future<void> replaceFromSync(AppSettings merged) => _save(merged);

  Future<void> _change(String field, AppSettings next) async {
    await _save(next.stamped(field, ref.read(clockProvider)()));
    ref.read(syncProvider.notifier).localChanged();
  }

  Future<void> _save(AppSettings next) async {
    state = next;
    await ref.read(localStoreProvider).saveSettings(next);
  }
}

// -------------------------------------------------------------------- trips

final tripsProvider = NotifierProvider<TripsNotifier, List<Trip>>(
  TripsNotifier.new,
);

/// A trip that can't be logged, with a message to show the user.
class TripException implements Exception {
  const TripException(this.message);
  final String message;

  @override
  String toString() => message;
}

class NoStartPointException extends TripException {
  const NoStartPointException()
    : super(
        'Set your home/office address in Settings so the first trip '
        'of the day has a starting point.',
      );
}

class SameAsStartException extends TripException {
  SameAsStartException(Place place)
    : super(
        'You\'re already at ${place.label}. Pick a different '
        'destination, or tap Change to set where you started.',
      );
}

class TripsNotifier extends Notifier<List<Trip>> {
  @override
  List<Trip> build() => ref.read(localStoreProvider).loadTrips();

  /// Adds trips the phone detected in the background (see
  /// arrival_handler.dart). Measures any that were logged offline.
  /// Returns how many were added.
  Future<int> mergeInbox() async {
    final inbox = ref.read(autoTripInboxProvider);
    if (inbox == null) return 0;
    final entries = await inbox.load();
    if (entries.isEmpty) return 0;

    final known = {for (final t in state) t.id};
    final taken = <String>{};
    final added = <Trip>[];
    for (final e in entries) {
      if (known.contains(e.trip.id)) {
        taken.add(e.trip.id);
        continue;
      }
      var trip = e.trip;
      if (e.needsMiles) {
        final distance = ref.read(distanceServiceProvider);
        try {
          trip = Trip(
            id: trip.id,
            date: trip.date,
            from: trip.from,
            to: trip.to,
            miles: await distance.drivingMiles(trip.from, trip.to),
            estimated: distance.isDemo,
          );
        } catch (_) {
          continue; // Still offline; try again next time.
        }
      }
      added.add(trip);
      taken.add(trip.id);
    }
    if (added.isNotEmpty) {
      await _set(
        [...state, ...added]..sort((a, b) => a.date.compareTo(b.date)),
      );
      _changed();
    }
    await inbox.remove(taken);
    return added.length;
  }

  /// Logs a drive to [to]. Starts from [fromOverride] if given, otherwise
  /// from the last stop today, otherwise from home.
  Future<Trip> logTripTo(Place to, {Place? fromOverride}) async {
    // Include trips detected in the background, so "from" is current.
    await mergeInbox();
    final now = ref.read(clockProvider)();
    final from =
        fromOverride ??
        currentStart(
          trips: state,
          lastStop: ref.read(localStoreProvider).lastStop,
          home: ref.read(settingsProvider).home,
          now: now,
        );
    if (from == null) throw const NoStartPointException();
    if (isSamePlace(from, to)) throw SameAsStartException(to);

    final distance = ref.read(distanceServiceProvider);
    final miles = await distance.drivingMiles(from, to);
    final trip = Trip(
      id: _uuid.v4(),
      date: now,
      from: from,
      to: to,
      miles: miles,
      estimated: distance.isDemo,
    );
    await _set([...state, trip]);
    _changed();
    await ref.read(jobsProvider.notifier).afterManualTrip(trip);
    return trip;
  }

  /// Deletes a trip here, and from the spreadsheet if it was uploaded.
  Future<void> remove(String id) async {
    final trip = state.where((t) => t.id == id).firstOrNull;
    if (trip == null) return;
    if (trip.synced) {
      final store = ref.read(localStoreProvider);
      await store.savePendingDeletes({...store.loadPendingDeletes(), id});
    }
    await _set([
      for (final t in state)
        if (t.id != id) t,
    ]);
    _changed();
  }

  /// Marks trips as written to the spreadsheet.
  Future<void> markSynced(Set<String> ids) => _set([
    for (final t in state) ids.contains(t.id) ? t.copyWith(synced: true) : t,
  ]);

  /// Marks every trip as needing upload (e.g. a new spreadsheet).
  Future<void> markAllUnsynced() =>
      _set([for (final t in state) t.copyWith(synced: false)]);

  void _changed() => ref.read(syncProvider.notifier).localChanged();

  /// Puts a removed trip back (for Undo).
  Future<void> restore(Trip trip) async {
    final store = ref.read(localStoreProvider);
    final pending = store.loadPendingDeletes();
    final Trip restored;
    if (pending.remove(trip.id)) {
      // Its row is still in the sheet; just cancel the delete.
      await store.savePendingDeletes(pending);
      restored = trip.copyWith(synced: true);
    } else {
      // Its row is gone (or never existed); upload it again.
      restored = trip.copyWith(synced: false);
    }
    final next = [...state, restored]..sort((a, b) => a.date.compareTo(b.date));
    await _set(next);
    _changed();
  }

  Future<void> _set(List<Trip> next) async {
    state = next;
    await ref.read(localStoreProvider).saveTrips(next);
  }
}

/// The automatic start point for the next trip.
final nextStartProvider = Provider<Place?>((ref) {
  ref.watch(jobsProvider); // Re-checked when the phone notices a stop.
  return currentStart(
    trips: ref.watch(tripsProvider),
    lastStop: ref.read(localStoreProvider).lastStop,
    home: ref.watch(settingsProvider).home,
    now: ref.read(clockProvider)(),
  );
});

/// Trips logged today, oldest first.
final todaysTripsProvider = Provider<List<Trip>>((ref) {
  final now = ref.read(clockProvider)();
  return ref.watch(tripsProvider).where((t) => isSameDay(t.date, now)).toList()
    ..sort((a, b) => a.date.compareTo(b.date));
});
