import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:native_geofence/native_geofence.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../config/oauth_config.dart';
import '../models/job.dart';
import '../models/place.dart';
import '../models/saved_address.dart';
import '../models/trip.dart';
import '../services/auto_trip.dart';
import '../services/jobs.dart';
import 'job_watcher.dart';
import '../services/cached_distance_service.dart';
import '../services/distance_service.dart';
import '../services/google_account.dart';
import '../services/local_store.dart';
import '../services/mileage_sheet.dart';
import '../services/routes_distance_service.dart';
import '../services/secret_store.dart';

/// Called by Android (in the background, even with the app closed) when
/// the phone has stayed 5 minutes at a saved place (client, donation
/// center or home), or has just left one.
@pragma('vm:entry-point')
Future<void> onArrival(GeofenceCallbackParams params) async {
  final now = DateTime.now();
  for (final fence in params.geofences) {
    try {
      if (params.event == GeofenceEvent.exit) {
        await _recordDeparture(fence.id, now);
      } else if (params.event == GeofenceEvent.dwell) {
        await handleFenceArrival(
          fence.id,
          now.subtract(arrivalStayTime),
        ).timeout(const Duration(seconds: 50));
      }
    } catch (e) {
      debugPrint(
        'Dunn Record Keeping: ${params.event} at ${fence.id} not '
        'handled: $e',
      );
    }
  }
}

/// Remembers when the phone left a saved place: the start of a job's
/// clock if the next stop is a client.
Future<void> _recordDeparture(String fenceId, DateTime at) async {
  final store = await _openStore();
  if (!store.autoTripsEnabled) return;
  final where = _placeForFence(store, fenceId);
  if (where != null) await store.setLastDeparture(PlaceVisit(where.place, at));
}

({StopKind kind, Place place})? _placeForFence(LocalStore store, String id) =>
    placeForFence(
      id,
      home: store.loadSettings().home,
      clientStops: clientStops(store.loadAddresses()),
      donationCenters: store.loadDonationCenters(),
    );

Future<LocalStore> _openStore() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  return LocalStore(prefs);
}

/// A stay at a saved place.
Future<void> handleFenceArrival(String fenceId, DateTime arrivedAt) async {
  final store = await _openStore();
  if (!store.autoTripsEnabled) return;
  final where = _placeForFence(store, fenceId);
  if (where == null) return;
  await handleStop(where.kind, where.place, arrivedAt);
}

/// Applies the job rules to a stop (see [recordStop]): logs the drive if
/// it's part of a job, tries to upload it to the spreadsheet, starts or
/// stops watching for stops, and shows a notification.
Future<void> handleStop(StopKind kind, Place place, DateTime arrivedAt) async {
  final prefs = await SharedPreferences.getInstance();
  final store = LocalStore(prefs);
  final inbox = AutoTripInbox(prefs);
  final secrets = await SecureSecretStore.load();
  final apiKey = secrets.apiKey;
  final client = http.Client();
  final StopOutcome outcome;
  try {
    outcome = await recordStop(
      store: store,
      inbox: inbox,
      distance: apiKey == null
          ? const DemoDistanceService()
          : CachedDistanceService(
              RoutesDistanceService(apiKey: apiKey, client: client),
              store,
            ),
      kind: kind,
      place: place,
      arrivedAt: arrivedAt,
      newId: const Uuid().v4,
    );
  } finally {
    client.close();
  }

  if (outcome.startedJob != null) {
    await startJobWatcher(place);
  } else if (outcome.endedJob != null) {
    await stopJobWatcher();
  }

  final logged = outcome.trip;
  if (logged == null) return;
  var trip = logged;

  // Upload right away if possible; otherwise the app does it later.
  final spreadsheetId = store.loadSettings().spreadsheetId;
  var jobUploaded = false;
  if (!outcome.needsMiles && spreadsheetId != null) {
    try {
      final ended = outcome.endedJob;
      final uploaded = await _uploadInBackground(
        spreadsheetId,
        store,
        trip: trip,
        job: ended,
        jobMiles: ended == null
            ? 0
            : jobMiles(ended, [
                ...store.loadTrips(),
                for (final e in await inbox.load()) e.trip,
              ]),
      );
      if (uploaded.trip) {
        trip = trip.copyWith(synced: true);
        await inbox.replace(InboxTrip(trip));
      }
      if (uploaded.job && ended != null) {
        {
          await store.saveJobs([
            for (final j in store.loadJobs())
              j.id == ended.id ? j.copyWith(synced: true) : j,
          ]);
          jobUploaded = true;
        }
      }
    } catch (e) {
      debugPrint('Dunn Record Keeping: background upload failed: $e');
    }
  }

  await _notify(
    trip,
    needsMiles: outcome.needsMiles,
    started: outcome.startedJob,
    ended: outcome.endedJob,
    jobUploaded: jobUploaded,
  );
}

bool _signInReady = false;

/// Gets a Google token without any screen (works only if access was
/// already granted in the app) and adds the trip row (and the job row,
/// if a job just ended). Says which made it.
Future<({bool trip, bool job})> _uploadInBackground(
  String spreadsheetId,
  LocalStore store, {
  required Trip trip,
  Job? job,
  double jobMiles = 0,
}) async {
  final email = store.googleEmail;
  const none = (trip: false, job: false);
  if (email == null || !OAuthConfig.androidConfigured) return none;
  if (!_signInReady) {
    await GoogleSignIn.instance.initialize(
      serverClientId: OAuthConfig.androidServerClientId,
    );
    _signInReady = true;
  }
  final tokens = await GoogleSignInPlatform.instance
      .clientAuthorizationTokensForScopes(
        ClientAuthorizationTokensForScopesParameters(
          request: AuthorizationRequestDetails(
            scopes: googleScopes,
            userId: null,
            email: email,
            promptIfUnauthorized: false,
          ),
        ),
      );
  if (tokens == null) return none;
  final client = _BearerClient(tokens.accessToken);
  try {
    final sheet = GoogleMileageSheet(client);
    await sheet.addTrips(spreadsheetId, [trip]);
    if (job == null) return (trip: true, job: false);
    try {
      // Fails if the app hasn't added the Jobs tab yet; it uploads the
      // job itself next time it syncs.
      await sheet.addJobs(spreadsheetId, [(job: job, miles: jobMiles)]);
      return (trip: true, job: true);
    } catch (_) {
      return (trip: true, job: false);
    }
  } finally {
    client.close();
  }
}

class _BearerClient extends http.BaseClient {
  _BearerClient(this._token);
  final String _token;
  final _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['Authorization'] = 'Bearer $_token';
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

const _channel = AndroidNotificationDetails(
  'auto_trips',
  'Automatic trips',
  channelDescription: 'Shown when a trip is logged automatically',
  importance: Importance.defaultImportance,
);

Future<void> _notify(
  Trip trip, {
  required bool needsMiles,
  Job? started,
  Job? ended,
  bool jobUploaded = false,
}) async {
  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
  );
  final route = '${trip.from.label} → ${trip.to.label}';
  final miles = needsMiles
      ? 'Miles will be added when you\'re back online.'
      : '${trip.miles.toStringAsFixed(1)} mi'
            '${trip.estimated ? ' (estimate)' : ''}'
            '${trip.synced ? ' · added to your spreadsheet' : ''}';
  final job = started != null
      ? 'Job started ${formatClock(started.start)}. Watching for stops.'
      : ended != null
      ? 'Job ended: ${formatHours(ended.duration)} on the job'
            '${jobUploaded ? ' · added to your spreadsheet' : ''}.'
      : null;
  await plugin.show(
    id: trip.id.hashCode & 0x7fffffff,
    title: 'Trip logged: $route',
    body: job == null ? miles : '$miles\n$job',
    notificationDetails: const NotificationDetails(android: _channel),
  );
}
