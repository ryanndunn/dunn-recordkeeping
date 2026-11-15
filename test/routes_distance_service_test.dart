import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mileage_log/models/place.dart';
import 'package:mileage_log/services/distance_service.dart';
import 'package:mileage_log/services/routes_distance_service.dart';

void main() {
  const home = Place(
    label: 'Home',
    address: '1 Home Rd',
    placeId: 'home-id',
    lat: 1,
    lng: 2,
  );
  const clinic = Place(label: 'Clinic', address: '123 Main St', lat: 3, lng: 4);
  const typed = Place(label: 'Old', address: '5 Typed St, Springfield');

  RoutesDistanceService serviceReturning(
    http.Response response, [
    void Function(http.Request)? onRequest,
  ]) => RoutesDistanceService(
    apiKey: 'test-key',
    client: MockClient((request) async {
      onRequest?.call(request);
      return response;
    }),
  );

  test(
    'sends a traffic-free, distance-only request and converts to miles',
    () async {
      late http.Request sent;
      final service = serviceReturning(
        http.Response(
          jsonEncode({
            'routes': [
              {'distanceMeters': 16093},
            ],
          }),
          200,
        ),
        (r) => sent = r,
      );

      final miles = await service.drivingMiles(home, clinic);

      expect(sent.method, 'POST');
      expect(
        sent.url.toString(),
        'https://routes.googleapis.com/directions/v2:computeRoutes',
      );
      expect(sent.headers['X-Goog-Api-Key'], 'test-key');
      expect(sent.headers['X-Goog-FieldMask'], 'routes.distanceMeters');
      final body = jsonDecode(sent.body) as Map<String, dynamic>;
      expect(body['travelMode'], 'DRIVE');
      expect(body['routingPreference'], 'TRAFFIC_UNAWARE');
      // Place ID preferred, then coordinates.
      expect(body['origin'], {'placeId': 'home-id'});
      expect(body['destination'], {
        'location': {
          'latLng': {'latitude': 3, 'longitude': 4},
        },
      });
      expect(miles, 10.0);
    },
  );

  test('falls back to the address text when nothing better is known', () {
    expect(RoutesDistanceService.waypoint(typed), {
      'address': '5 Typed St, Springfield',
    });
  });

  test('a route with no distance field is 0 miles', () async {
    final service = serviceReturning(
      http.Response(
        jsonEncode({
          'routes': [{}],
        }),
        200,
      ),
    );
    expect(await service.drivingMiles(home, clinic), 0);
  });

  test('no route found gives a clear error', () async {
    final service = serviceReturning(http.Response('{}', 200));
    expect(
      () => service.drivingMiles(home, clinic),
      throwsA(
        isA<DistanceException>().having(
          (e) => e.message,
          'message',
          contains('no driving route'),
        ),
      ),
    );
  });

  test('a 403 points at the API setup', () async {
    final service = serviceReturning(
      http.Response(
        jsonEncode({
          'error': {'code': 403, 'message': 'PERMISSION_DENIED'},
        }),
        403,
      ),
    );
    expect(
      () => service.drivingMiles(home, clinic),
      throwsA(
        isA<DistanceException>().having(
          (e) => e.message,
          'message',
          contains('Routes API'),
        ),
      ),
    );
  });

  test('no network gives a clear error', () async {
    final service = RoutesDistanceService(
      apiKey: 'k',
      client: MockClient((_) async => throw http.ClientException('down')),
    );
    expect(
      () => service.drivingMiles(home, clinic),
      throwsA(
        isA<DistanceException>().having(
          (e) => e.message,
          'message',
          contains('internet'),
        ),
      ),
    );
  });
}
