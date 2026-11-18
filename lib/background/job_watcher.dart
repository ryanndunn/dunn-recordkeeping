import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/place.dart';
import '../models/saved_address.dart';
import '../services/jobs.dart';
import '../services/local_store.dart';
import '../services/places_service.dart';
import '../services/secret_store.dart';
import '../services/stop_detector.dart';
import 'arrival_handler.dart';

/// While a job is running, the phone watches its location (with an
/// "On a job" notification showing) so it notices stops anywhere: a gas
/// station keeps the job going; a store, restaurant or any other unsaved
/// place ends it. Saved places (clients, donation centers, home) are left
/// to their geofences, so a stop is never logged twice.

const _channelId = 'job_watch';
const _notificationId = 7301;

bool get _supported => !kIsWeb && Platform.isAndroid;

/// Sets the service up. Called once at app start.
Future<void> configureJobWatcher() async {
  if (!_supported) return;
  await FlutterLocalNotificationsPlugin()
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.createNotificationChannel(
        const AndroidNotificationChannel(
          _channelId,
          'In a session',
          description: 'Shown while the app watches for stops during a session',
          importance: Importance.low,
        ),
      );
  await FlutterBackgroundService().configure(
    androidConfiguration: AndroidConfiguration(
      onStart: jobWatcherMain,
      autoStart: false,
      autoStartOnBoot: false,
      isForegroundMode: true,
      notificationChannelId: _channelId,
      initialNotificationTitle: 'In a session',
      initialNotificationContent: 'Watching for stops to log mileage',
      foregroundServiceNotificationId: _notificationId,
      foregroundServiceTypes: [AndroidForegroundType.location],
    ),
    iosConfiguration: IosConfiguration(autoStart: false),
  );
}

const _startAtKey = 'job_watch_start_v1';

/// Starts watching (if not already), treating [startedAt] as the stop
/// the phone is at now.
Future<void> startJobWatcher(Place startedAt) async {
  if (!_supported) return;
  try {
    final prefs = await SharedPreferences.getInstance();
    if (startedAt.hasCoordinates) {
      await prefs.setString(_startAtKey, '${startedAt.lat},${startedAt.lng}');
    }
    final service = FlutterBackgroundService();
    if (!await service.isRunning()) await service.startService();
  } catch (e) {
    debugPrint('Dunn Record Keeping: could not start watching: $e');
  }
}

Future<void> stopJobWatcher() async {
  if (!_supported) return;
  try {
    final service = FlutterBackgroundService();
    if (await service.isRunning()) service.invoke('stop');
  } catch (e) {
    debugPrint('Dunn Record Keeping: could not stop watching: $e');
  }
}

/// When the app opens: watch if a job is running, stop if not (e.g. the
/// job was ended by hand, or the service was stopped by the phone).
Future<void> syncJobWatcher(LocalStore store) async {
  if (!_supported || !store.autoTripsEnabled) return;
  final now = DateTime.now();
  final running = activeJob(store.loadJobs(), now);
  if (running == null) {
    await stopJobWatcher();
  } else {
    final at = store.lastStop?.place;
    await startJobWatcher(at ?? const Place(label: '', address: ''));
  }
}

/// The service itself (runs in its own background isolate).
@pragma('vm:entry-point')
Future<void> jobWatcherMain(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  StreamSubscription<Position>? positions;
  Future<void> stop() async {
    await positions?.cancel();
    await service.stopSelf();
  }

  service.on('stop').listen((_) => stop());

  final prefs = await SharedPreferences.getInstance();
  final detector = StopDetector();
  final start = prefs.getString(_startAtKey)?.split(',');
  if (start != null && start.length == 2) {
    final lat = double.tryParse(start[0]);
    final lng = double.tryParse(start[1]);
    if (lat != null && lng != null) detector.startStoppedAt(lat, lng);
  }

  var busy = false;
  positions =
      Geolocator.getPositionStream(
        locationSettings: AndroidSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 0,
          intervalDuration: const Duration(seconds: 20),
        ),
      ).listen((p) async {
        if (busy) return;
        busy = true;
        try {
          await prefs.reload();
          final store = LocalStore(prefs);
          final running = activeJob(store.loadJobs(), DateTime.now());
          if (running == null || !store.autoTripsEnabled) {
            await stop();
            return;
          }
          if (service is AndroidServiceInstance) {
            await service.setForegroundNotificationInfo(
              title: 'In a session since ${formatClock(running.start)}',
              content: 'Watching for stops to log mileage',
            );
          }
          final found = detector.add(p.latitude, p.longitude, p.timestamp);
          if (found != null) await _onStop(store, found);
        } catch (e) {
          debugPrint('Dunn Record Keeping: stop not handled: $e');
        } finally {
          busy = false;
        }
      });
}

/// A stop the watcher found. Saved places are handled by their
/// geofences; anything else is named with Google (gas station or not).
Future<void> _onStop(LocalStore store, DetectedStop stop) async {
  final here = Place(
    label: 'Stop',
    address: '${stop.lat.toStringAsFixed(5)}, ${stop.lng.toStringAsFixed(5)}',
    lat: stop.lat,
    lng: stop.lng,
  );
  final known = classifyKnownPlace(
    here,
    home: store.loadSettings().home,
    clientStops: clientStops(store.loadAddresses()),
    donationCenters: store.loadDonationCenters(),
  );
  if (known.kind != StopKind.other) return;

  final named = await nameStop(here);
  await handleStop(named.kind, named.place, stop.arrivedAt);
}

/// Asks Google what's at [here]: a gas station keeps the job going;
/// anything else is named after the nearest place. Without an API key or
/// a connection, the stop keeps its coordinates as its address.
Future<({StopKind kind, Place place})> nameStop(Place here) async {
  final key = (await SecureSecretStore.load()).apiKey;
  if (key == null) return (kind: StopKind.other, place: here);
  final client = http.Client();
  try {
    final found = await GooglePlacesService(
      apiKey: key,
      client: client,
    ).nearby(here.lat!, here.lng!);
    return classifyNearby(here, found);
  } catch (_) {
    return (kind: StopKind.other, place: here);
  } finally {
    client.close();
  }
}
