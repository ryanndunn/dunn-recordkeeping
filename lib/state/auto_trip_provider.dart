import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:native_geofence/native_geofence.dart';
import 'package:permission_handler/permission_handler.dart';

import '../background/arrival_handler.dart';
import '../models/place.dart';
import '../services/auto_trip.dart';
import 'providers.dart';

/// Talks to Android's geofencing and permissions. Swappable in tests.
abstract class GeofencePlatform {
  Future<bool> hasBackgroundLocation();

  /// Walks through the location ("Allow all the time"), notification and
  /// battery prompts. Returns whether background location was granted.
  Future<bool> requestPermissions();

  /// Replaces all registered geofences with [fences].
  Future<void> setFences(Map<String, Place> fences);

  Future<void> clearFences();
}

class AndroidGeofencePlatform implements GeofencePlatform {
  bool _initialized = false;

  Future<void> _init() async {
    if (_initialized) return;
    await NativeGeofenceManager.instance.initialize();
    _initialized = true;
  }

  @override
  Future<bool> hasBackgroundLocation() => Permission.locationAlways.isGranted;

  @override
  Future<bool> requestPermissions() async {
    if (!await Permission.locationWhenInUse.request().isGranted) return false;
    // Android shows "Allow all the time" on a separate settings screen.
    final always = await Permission.locationAlways.request().isGranted;
    await Permission.notification.request();
    // Keeps Android (and Samsung's battery manager) from delaying alerts.
    await Permission.ignoreBatteryOptimizations.request();
    return always;
  }

  @override
  Future<void> setFences(Map<String, Place> fences) async {
    await _init();
    await NativeGeofenceManager.instance.removeAllGeofences();
    for (final e in fences.entries) {
      await NativeGeofenceManager.instance.createGeofence(
        Geofence(
          id: e.key,
          location: Location(latitude: e.value.lat!, longitude: e.value.lng!),
          radiusMeters: arrivalRadiusMeters,
          triggers: {GeofenceEvent.dwell},
          iosSettings: const IosGeofenceSettings(initialTrigger: false),
          androidSettings: const AndroidGeofenceSettings(
            initialTriggers: {},
            loiteringDelay: arrivalStayTime,
            // Android's "never expire" value.
            expiration: Duration(milliseconds: -1),
            notificationResponsiveness: Duration(minutes: 2),
          ),
        ),
        onArrival,
      );
    }
  }

  @override
  Future<void> clearFences() async {
    await _init();
    await NativeGeofenceManager.instance.removeAllGeofences();
  }
}

final geofencePlatformProvider = Provider<GeofencePlatform?>((ref) {
  if (kIsWeb || !Platform.isAndroid) return null;
  return AndroidGeofencePlatform();
});

class AutoTripState {
  const AutoTripState({
    required this.supported,
    this.enabled = false,
    this.permissionOk = false,
    this.watching = 0,
    this.skipped = 0,
    this.message,
  });

  /// False on the Mac: only the phone can sense arrivals.
  final bool supported;
  final bool enabled;

  /// "Allow all the time" location access.
  final bool permissionOk;

  /// How many places are being watched.
  final int watching;

  /// Saved places that can't be watched (picked before Google search, so
  /// no map position).
  final int skipped;
  final String? message;

  AutoTripState copyWith({
    bool? enabled,
    bool? permissionOk,
    int? watching,
    int? skipped,
    String? message,
  }) => AutoTripState(
    supported: supported,
    enabled: enabled ?? this.enabled,
    permissionOk: permissionOk ?? this.permissionOk,
    watching: watching ?? this.watching,
    skipped: skipped ?? this.skipped,
    message: message,
  );
}

final autoTripProvider = NotifierProvider<AutoTripNotifier, AutoTripState>(
  AutoTripNotifier.new,
);

/// Automatic trip logging: arriving and staying at a saved address or
/// home logs the trip, without opening the app.
class AutoTripNotifier extends Notifier<AutoTripState> {
  @override
  AutoTripState build() {
    final platform = ref.read(geofencePlatformProvider);
    if (platform == null) return const AutoTripState(supported: false);
    // Re-register whenever the watched places change.
    ref.listen(addressesProvider, (_, _) => _refreshFences());
    ref.listen(
      settingsProvider.select((s) => s.home),
      (_, _) => _refreshFences(),
    );
    return AutoTripState(
      supported: true,
      enabled: ref.read(localStoreProvider).autoTripsEnabled,
    );
  }

  GeofencePlatform? get _platform => ref.read(geofencePlatformProvider);

  /// The places to watch: home and every saved address with a position.
  ({Map<String, Place> fences, int skipped}) _desiredFences() {
    final fences = <String, Place>{};
    var skipped = 0;
    final home = ref.read(settingsProvider).home;
    if (home != null) {
      if (home.hasCoordinates) {
        fences[homeFenceId] = home;
      } else {
        skipped++;
      }
    }
    for (final a in ref.read(addressesProvider)) {
      final place = a.toPlace();
      if (place.hasCoordinates) {
        fences[addressFenceId(a.id)] = place;
      } else {
        skipped++;
      }
    }
    return (fences: fences, skipped: skipped);
  }

  /// At startup and when returning to the app: check permission (the user
  /// may have changed it in Android settings) and re-register places.
  Future<void> refresh() async {
    final platform = _platform;
    if (platform == null) return;
    final ok = await platform.hasBackgroundLocation();
    state = state.copyWith(permissionOk: ok);
    await _refreshFences();
  }

  Future<void> enable() async {
    final platform = _platform;
    if (platform == null) return;
    final ok = await platform.requestPermissions();
    if (!ok) {
      state = state.copyWith(
        permissionOk: false,
        message:
            'Location must be set to "Allow all the time" for trips to be '
            'logged while the app is closed.',
      );
      return;
    }
    await ref.read(localStoreProvider).setAutoTripsEnabled(true);
    state = state.copyWith(enabled: true, permissionOk: true);
    await _refreshFences();
  }

  Future<void> disable() async {
    await ref.read(localStoreProvider).setAutoTripsEnabled(false);
    state = state.copyWith(enabled: false, watching: 0);
    try {
      await _platform?.clearFences();
    } catch (e) {
      debugPrint('Dunn Record Keeping: could not clear geofences: $e');
    }
  }

  Future<void> _refreshFences() async {
    final platform = _platform;
    if (platform == null || !state.enabled) return;
    final desired = _desiredFences();
    if (!state.permissionOk) {
      state = state.copyWith(watching: 0, skipped: desired.skipped);
      return;
    }
    try {
      await platform.setFences(desired.fences);
      state = state.copyWith(
        watching: desired.fences.length,
        skipped: desired.skipped,
      );
    } catch (e) {
      state = state.copyWith(
        watching: 0,
        skipped: desired.skipped,
        message: 'Couldn\'t start watching your places: $e',
      );
    }
  }
}
