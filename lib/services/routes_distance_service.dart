import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/place.dart';
import 'distance_service.dart';

/// Real driving distance from Google Routes API (computeRoutes).
///
/// Asks for distance only, without live traffic, which keeps every call in
/// Google's "Compute Routes Essentials" tier (10,000 free per month).
class RoutesDistanceService implements DistanceService {
  RoutesDistanceService({required this.apiKey, required this.client});

  final String apiKey;
  final http.Client client;

  static const _url =
      'https://routes.googleapis.com/directions/v2:computeRoutes';
  static const _metersPerMile = 1609.344;

  @override
  bool get isDemo => false;

  @override
  Future<double> drivingMiles(Place from, Place to) async {
    final http.Response response;
    try {
      response = await client.post(
        Uri.parse(_url),
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': apiKey,
          'X-Goog-FieldMask': 'routes.distanceMeters',
        },
        body: jsonEncode({
          'origin': waypoint(from),
          'destination': waypoint(to),
          'travelMode': 'DRIVE',
          'routingPreference': 'TRAFFIC_UNAWARE',
        }),
      );
    } catch (_) {
      throw const DistanceException(
        'Can\'t reach Google to measure the drive. Check your internet '
        'connection and try again.',
      );
    }

    final Map<String, dynamic> json;
    try {
      json = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw DistanceException(
        'Unexpected reply from Google (HTTP ${response.statusCode}).',
      );
    }

    if (response.statusCode != 200) {
      final googleMessage =
          (json['error'] as Map<String, dynamic>?)?['message'] as String? ?? '';
      throw DistanceException(switch (response.statusCode) {
        400 when googleMessage.contains('API key') =>
          'Google rejected the API key. Check it in Settings.',
        403 =>
          'This API key isn\'t allowed to use the Routes API. '
              'See docs/GOOGLE_CLOUD_SETUP.md steps 2 and 5.',
        429 => 'Too many distance lookups right now. Try again in a minute.',
        _ =>
          'Google couldn\'t measure the drive (HTTP '
                  '${response.statusCode}). $googleMessage'
              .trim(),
      });
    }

    final routes = (json['routes'] as List?) ?? const [];
    if (routes.isEmpty) {
      throw DistanceException(
        'Google found no driving route from '
        '${from.label} to ${to.label}.',
      );
    }
    // Zero is left out of Google's JSON, so a missing distance means 0 m.
    final meters =
        ((routes.first as Map<String, dynamic>)['distanceMeters'] as num?) ?? 0;
    return (meters / _metersPerMile * 10).round() / 10;
  }

  /// Most precise description available: Google place ID, then
  /// coordinates, then the address text.
  static Map<String, dynamic> waypoint(Place p) {
    if (p.placeId != null) return {'placeId': p.placeId};
    if (p.hasCoordinates) {
      return {
        'location': {
          'latLng': {'latitude': p.lat, 'longitude': p.lng},
        },
      };
    }
    return {'address': p.address};
  }
}
