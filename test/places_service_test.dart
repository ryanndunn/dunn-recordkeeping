import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mileage_log/models/place.dart';
import 'package:mileage_log/services/places_service.dart';

void main() {
  test(
    'autocomplete sends key, session and location bias; parses results',
    () async {
      late http.Request sent;
      final client = MockClient((request) async {
        sent = request;
        return http.Response(
          jsonEncode({
            'suggestions': [
              {
                'placePrediction': {
                  'place': 'places/abc',
                  'placeId': 'abc',
                  'text': {
                    'text':
                        'Springfield Clinic, 123 Main St, Springfield, IL, USA',
                  },
                  'structuredFormat': {
                    'mainText': {'text': 'Springfield Clinic'},
                    'secondaryText': {
                      'text': '123 Main St, Springfield, IL, USA',
                    },
                  },
                },
              },
              {
                'queryPrediction': {
                  'text': {'text': 'clinics near me'},
                },
              },
            ],
          }),
          200,
        );
      });
      final service = GooglePlacesService(apiKey: 'test-key', client: client);

      final results = await service.autocomplete(
        'spring',
        sessionToken: 'session-1',
        near: const Place(label: 'Home', address: 'x', lat: 39.8, lng: -89.6),
      );

      expect(sent.method, 'POST');
      expect(
        sent.url.toString(),
        'https://places.googleapis.com/v1/places:autocomplete',
      );
      expect(sent.headers['X-Goog-Api-Key'], 'test-key');
      final body = jsonDecode(sent.body) as Map<String, dynamic>;
      expect(body['input'], 'spring');
      expect(body['sessionToken'], 'session-1');
      expect(body['locationBias']['circle']['center'], {
        'latitude': 39.8,
        'longitude': -89.6,
      });
      expect(body['locationBias']['circle']['radius'], 50000.0);

      // Query predictions are dropped; only real places are offered.
      expect(results, hasLength(1));
      expect(results.single.placeId, 'abc');
      expect(results.single.mainText, 'Springfield Clinic');
      expect(results.single.secondaryText, '123 Main St, Springfield, IL, USA');
    },
  );

  test(
    'details requests the field mask and returns a verified Place',
    () async {
      late http.Request sent;
      final client = MockClient((request) async {
        sent = request;
        return http.Response(
          jsonEncode({
            'id': 'abc',
            'displayName': {'text': 'Springfield Clinic', 'languageCode': 'en'},
            'formattedAddress': '123 Main St, Springfield, IL 62701, USA',
            'location': {'latitude': 39.80, 'longitude': -89.65},
          }),
          200,
        );
      });
      final service = GooglePlacesService(apiKey: 'test-key', client: client);

      final place = await service.details('abc', sessionToken: 'session-1');

      expect(sent.method, 'GET');
      expect(sent.url.path, '/v1/places/abc');
      expect(sent.url.queryParameters['sessionToken'], 'session-1');
      expect(
        sent.headers['X-Goog-FieldMask'],
        'id,displayName,formattedAddress,location',
      );
      expect(place.label, 'Springfield Clinic');
      expect(place.address, '123 Main St, Springfield, IL 62701, USA');
      expect(place.placeId, 'abc');
      expect((place.lat, place.lng), (39.80, -89.65));
      expect(place.isVerified, isTrue);
    },
  );

  test('a 403 becomes a readable message', () async {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'error': {'code': 403, 'message': 'PERMISSION_DENIED'},
        }),
        403,
      ),
    );
    final service = GooglePlacesService(apiKey: 'k', client: client);
    expect(
      () => service.autocomplete('x', sessionToken: 's'),
      throwsA(
        isA<PlacesException>().having(
          (e) => e.message,
          'message',
          contains('Places API (New)'),
        ),
      ),
    );
  });

  test('no network becomes a readable message', () async {
    final client = MockClient((_) async => throw http.ClientException('down'));
    final service = GooglePlacesService(apiKey: 'k', client: client);
    expect(
      () => service.details('abc', sessionToken: 's'),
      throwsA(
        isA<PlacesException>().having(
          (e) => e.message,
          'message',
          contains('internet'),
        ),
      ),
    );
  });
}
