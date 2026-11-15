import 'package:mileage_log/models/place.dart';
import 'package:mileage_log/services/distance_service.dart';
import 'package:mileage_log/services/places_service.dart';

/// Returns a fixed distance (or fails) and counts calls.
class FakeDistanceService implements DistanceService {
  FakeDistanceService({
    this.miles = 10,
    this.fail = false,
    this.isDemo = false,
  });

  final double miles;
  final bool fail;
  int calls = 0;

  @override
  final bool isDemo;

  @override
  Future<double> drivingMiles(Place from, Place to) async {
    calls++;
    if (fail) {
      throw const DistanceException(
        'Can\'t reach Google to measure the drive.',
      );
    }
    return miles;
  }
}

/// Stand-in for Google Places: searches a fixed list of places.
class FakePlacesService implements PlacesService {
  FakePlacesService(this.places);

  final List<Place> places;
  final List<String> sessionTokensUsed = [];

  @override
  Future<List<PlaceSuggestion>> autocomplete(
    String input, {
    required String sessionToken,
    Place? near,
  }) async {
    sessionTokensUsed.add(sessionToken);
    final q = input.toLowerCase();
    return [
      for (final p in places)
        if (p.label.toLowerCase().contains(q) ||
            p.address.toLowerCase().contains(q))
          PlaceSuggestion(
            placeId: p.placeId!,
            mainText: p.label,
            secondaryText: p.address,
            fullText: '${p.label}, ${p.address}',
          ),
    ];
  }

  @override
  Future<Place> details(String placeId, {required String sessionToken}) async {
    sessionTokensUsed.add(sessionToken);
    return places.firstWhere((p) => p.placeId == placeId);
  }
}
