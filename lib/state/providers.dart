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
import '../services/start_point.dart';

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

  Future<void> set(String? key) async {
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

class AddressesNotifier extends Notifier<List<SavedAddress>> {
  @override
  List<SavedAddress> build() => ref.read(localStoreProvider).loadAddresses();

  /// Saves a Google-verified [place] under [name].
  Future<SavedAddress> add({required String name, required Place place}) async {
    final created = SavedAddress(
      id: _uuid.v4(),
      name: name.trim(),
      address: place.address,
      placeId: place.placeId,
      lat: place.lat,
      lng: place.lng,
    );
    await _set([...state, created]);
    return created;
  }

  Future<void> replace(SavedAddress updated) =>
      _set([for (final a in state) a.id == updated.id ? updated : a]);

  Future<void> remove(String id) => _set([
    for (final a in state)
      if (a.id != id) a,
  ]);

  Future<void> _set(List<SavedAddress> next) async {
    state = next;
    await ref.read(localStoreProvider).saveAddresses(next);
  }
}

// ----------------------------------------------------------------- settings

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.read(localStoreProvider).loadSettings();

  Future<void> setHome(Place home) => _set(state.copyWith(home: home));

  Future<void> setNavApp(NavApp navApp) => _set(state.copyWith(navApp: navApp));

  Future<void> setRatePerMile(double? rate) => _set(
    rate == null
        ? state.copyWith(clearRatePerMile: true)
        : state.copyWith(ratePerMile: rate),
  );

  Future<void> _set(AppSettings next) async {
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

  /// Logs a drive to [to]. Starts from [fromOverride] if given, otherwise
  /// from the last stop today, otherwise from home.
  Future<Trip> logTripTo(Place to, {Place? fromOverride}) async {
    final now = ref.read(clockProvider)();
    final from =
        fromOverride ??
        resolveStartPoint(
          trips: state,
          home: ref.read(settingsProvider).home,
          now: now,
        );
    if (from == null) throw const NoStartPointException();
    if (_samePlace(from, to)) throw SameAsStartException(to);

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
    return trip;
  }

  Future<void> remove(String id) => _set([
    for (final t in state)
      if (t.id != id) t,
  ]);

  static bool _samePlace(Place a, Place b) {
    if (a.placeId != null && a.placeId == b.placeId) return true;
    return AddressMatcher.normalize(a.address) ==
        AddressMatcher.normalize(b.address);
  }

  /// Puts a removed trip back (for Undo).
  Future<void> restore(Trip trip) async {
    final next = [...state, trip]..sort((a, b) => a.date.compareTo(b.date));
    await _set(next);
  }

  Future<void> _set(List<Trip> next) async {
    state = next;
    await ref.read(localStoreProvider).saveTrips(next);
  }
}

/// The automatic start point for the next trip.
final nextStartProvider = Provider<Place?>((ref) {
  return resolveStartPoint(
    trips: ref.watch(tripsProvider),
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
