import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/place.dart';

/// One row in the address dropdown, straight from Google.
class PlaceSuggestion {
  const PlaceSuggestion({
    required this.placeId,
    required this.mainText,
    required this.secondaryText,
    required this.fullText,
  });

  final String placeId;

  /// e.g. "Springfield Clinic" or "123 Main St".
  final String mainText;

  /// e.g. "Springfield, IL, USA". May be empty.
  final String secondaryText;

  final String fullText;
}

class PlacesException implements Exception {
  const PlacesException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Looks up real addresses so every saved place and trip destination is one
/// Google Maps knows about.
abstract class PlacesService {
  Future<List<PlaceSuggestion>> autocomplete(
    String input, {
    required String sessionToken,
    Place? near,
  });

  /// Full address, place ID and coordinates for a picked suggestion. Ends
  /// the autocomplete billing session.
  Future<Place> details(String placeId, {required String sessionToken});
}

/// Google Places API (New), called over REST.
class GooglePlacesService implements PlacesService {
  GooglePlacesService({required this.apiKey, required this.client});

  final String apiKey;
  final http.Client client;

  static const _base = 'https://places.googleapis.com/v1';

  /// Bias results to within this distance of [near] (Google's maximum).
  static const biasRadiusMeters = 50000.0;

  @override
  Future<List<PlaceSuggestion>> autocomplete(
    String input, {
    required String sessionToken,
    Place? near,
  }) async {
    final body = {
      'input': input,
      'sessionToken': sessionToken,
      if (near != null && near.hasCoordinates)
        'locationBias': {
          'circle': {
            'center': {'latitude': near.lat, 'longitude': near.lng},
            'radius': biasRadiusMeters,
          },
        },
    };
    final response = await _send(
      () => client.post(
        Uri.parse('$_base/places:autocomplete'),
        headers: {'Content-Type': 'application/json', 'X-Goog-Api-Key': apiKey},
        body: jsonEncode(body),
      ),
    );

    final suggestions = (response['suggestions'] as List?) ?? const [];
    return [
      for (final s in suggestions.cast<Map<String, dynamic>>())
        if (s['placePrediction'] case final Map<String, dynamic> p)
          PlaceSuggestion(
            placeId: p['placeId'] as String,
            mainText:
                _text(p['structuredFormat']?['mainText']) ??
                _text(p['text']) ??
                '',
            secondaryText: _text(p['structuredFormat']?['secondaryText']) ?? '',
            fullText: _text(p['text']) ?? '',
          ),
    ];
  }

  @override
  Future<Place> details(String placeId, {required String sessionToken}) async {
    final uri = Uri.parse('$_base/places/${Uri.encodeComponent(placeId)}')
        .replace(queryParameters: {'sessionToken': sessionToken});
    final json = await _send(
      () => client.get(
        uri,
        headers: {
          'X-Goog-Api-Key': apiKey,
          'X-Goog-FieldMask': 'id,displayName,formattedAddress,location',
        },
      ),
    );

    final address = json['formattedAddress'] as String?;
    if (address == null) {
      throw const PlacesException('Google returned no address for that place.');
    }
    final location = json['location'] as Map<String, dynamic>?;
    return Place(
      label: _text(json['displayName']) ?? address.split(',').first,
      address: address,
      placeId: json['id'] as String? ?? placeId,
      lat: (location?['latitude'] as num?)?.toDouble(),
      lng: (location?['longitude'] as num?)?.toDouble(),
    );
  }

  static String? _text(Object? node) =>
      node is Map<String, dynamic> ? node['text'] as String? : null;

  Future<Map<String, dynamic>> _send(
    Future<http.Response> Function() request,
  ) async {
    final http.Response response;
    try {
      response = await request();
    } catch (_) {
      throw const PlacesException(
        'Can\'t reach Google. Check your internet connection.',
      );
    }
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw PlacesException(
        'Unexpected reply from Google '
        '(HTTP ${response.statusCode}).',
      );
    }
    if (response.statusCode == 200) return json;

    final error = json['error'] as Map<String, dynamic>?;
    final googleMessage = error?['message'] as String? ?? '';
    final message = switch (response.statusCode) {
      400 when googleMessage.contains('API key') =>
        'Google rejected the API key. Check it in Settings.',
      403 =>
        'This API key isn\'t allowed to use Places API (New). '
            'See docs/GOOGLE_CLOUD_SETUP.md step 2 and 5.',
      429 => 'Too many address lookups right now. Try again in a minute.',
      _ =>
        'Google address search failed (HTTP ${response.statusCode}). '
            '$googleMessage',
    };
    throw PlacesException(message.trim());
  }
}
