import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:native_geofence/native_geofence.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../config/oauth_config.dart';
import '../models/trip.dart';
import '../services/auto_trip.dart';
import '../services/cached_distance_service.dart';
import '../services/distance_service.dart';
import '../services/google_account.dart';
import '../services/local_store.dart';
import '../services/mileage_sheet.dart';
import '../services/routes_distance_service.dart';
import '../services/secret_store.dart';

/// Called by Android (in the background, even with the app closed) when
/// the phone has stayed 5 minutes at a saved address or home.
@pragma('vm:entry-point')
Future<void> onArrival(GeofenceCallbackParams params) async {
  if (params.event != GeofenceEvent.dwell) return;
  final arrivedAt = DateTime.now().subtract(arrivalStayTime);
  for (final fence in params.geofences) {
    try {
      await handleArrival(
        fence.id,
        arrivedAt,
      ).timeout(const Duration(seconds: 50));
    } catch (e) {
      debugPrint('Dunn Record Keeping: arrival at ${fence.id} not handled: $e');
    }
  }
}

/// Logs the trip an arrival means (if any): measures it, tries to upload
/// it to the spreadsheet, leaves it for the app to add to its list, and
/// shows a notification.
Future<void> handleArrival(String fenceId, DateTime arrivedAt) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final store = LocalStore(prefs);
  if (!store.autoTripsEnabled) return;

  final inbox = AutoTripInbox(prefs);
  final waiting = await inbox.load();
  final settings = store.loadSettings();
  final decision = decideAutoTrip(
    fenceId: fenceId,
    arrivedAt: arrivedAt,
    home: settings.home,
    saved: store.loadAddresses(),
    trips: [...store.loadTrips(), for (final e in waiting) e.trip],
  );
  if (decision == null) return;

  // Measure the drive.
  final secrets = await SecureSecretStore.load();
  final apiKey = secrets.apiKey;
  final client = http.Client();
  var miles = 0.0;
  var needsMiles = false;
  try {
    miles = apiKey == null
        ? await const DemoDistanceService().drivingMiles(
            decision.from,
            decision.to,
          )
        : await CachedDistanceService(
            RoutesDistanceService(apiKey: apiKey, client: client),
            store,
          ).drivingMiles(decision.from, decision.to);
  } catch (_) {
    needsMiles = true; // Offline: the app measures it later.
  } finally {
    client.close();
  }

  var trip = Trip(
    id: const Uuid().v4(),
    date: arrivedAt,
    from: decision.from,
    to: decision.to,
    miles: miles,
    estimated: apiKey == null,
  );

  // Upload right away if possible; otherwise the app does it later.
  final spreadsheetId = settings.spreadsheetId;
  if (!needsMiles && spreadsheetId != null) {
    try {
      if (await _uploadInBackground(trip, spreadsheetId, store)) {
        trip = trip.copyWith(synced: true);
      }
    } catch (e) {
      debugPrint('Dunn Record Keeping: background upload failed: $e');
    }
  }

  await inbox.add(InboxTrip(trip, needsMiles: needsMiles));
  await _notify(trip, needsMiles: needsMiles);
}

bool _signInReady = false;

/// Gets a Google token without any screen (works only if access was
/// already granted in the app) and adds the row.
Future<bool> _uploadInBackground(
  Trip trip,
  String spreadsheetId,
  LocalStore store,
) async {
  final email = store.googleEmail;
  if (email == null || !OAuthConfig.androidConfigured) return false;
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
  if (tokens == null) return false;
  final client = _BearerClient(tokens.accessToken);
  try {
    await GoogleMileageSheet(client).addTrips(spreadsheetId, [trip]);
    return true;
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

Future<void> _notify(Trip trip, {required bool needsMiles}) async {
  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
  );
  final route = '${trip.from.label} → ${trip.to.label}';
  await plugin.show(
    id: trip.id.hashCode & 0x7fffffff,
    title: 'Trip logged: $route',
    body: needsMiles
        ? 'No connection right now; miles will be added when you\'re back '
              'online.'
        : '${trip.miles.toStringAsFixed(1)} mi'
              '${trip.estimated ? ' (estimate)' : ''}'
              '${trip.synced ? ' · added to your spreadsheet' : ''}',
    notificationDetails: const NotificationDetails(android: _channel),
  );
}
