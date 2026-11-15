import '../models/place.dart';
import 'address_matcher.dart';

/// A drive that couldn't be measured, with a message for the user.
class DistanceException implements Exception {
  const DistanceException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Works out driving miles between two places.
abstract class DistanceService {
  Future<double> drivingMiles(Place from, Place to);

  /// True when the numbers are placeholders rather than real driving
  /// distances. The UI shows a warning while this is true.
  bool get isDemo;
}

/// Estimate used while no Google API key is set.
///
/// With coordinates it uses straight-line distance × 1.3 (a typical road
/// factor). Without them it returns a stable made-up number from the two
/// addresses, so the same trip always gets the same figure.
class DemoDistanceService implements DistanceService {
  const DemoDistanceService();

  static const _metersPerMile = 1609.344;

  @override
  bool get isDemo => true;

  @override
  Future<double> drivingMiles(Place from, Place to) async {
    if (from.hasCoordinates && to.hasCoordinates) {
      final meters = AddressMatcher.distanceMeters(
        from.lat!,
        from.lng!,
        to.lat!,
        to.lng!,
      );
      return _round(meters * 1.3 / _metersPerMile);
    }
    final a = AddressMatcher.normalize(from.address);
    final b = AddressMatcher.normalize(to.address);
    if (a == b) return 0;
    // Order-independent so A→B and B→A match, like a real route roughly would.
    final key = a.compareTo(b) < 0 ? '$a|$b' : '$b|$a';
    var hash = 0;
    for (final unit in key.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return _round(2 + (hash % 280) / 10); // 2.0 – 29.9 miles
  }

  static double _round(double miles) => (miles * 10).round() / 10;
}
