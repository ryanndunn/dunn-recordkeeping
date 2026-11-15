import '../models/place.dart';
import 'address_matcher.dart';
import 'distance_service.dart';
import 'local_store.dart';

/// Remembers each measured drive on the device, so the same trip always
/// logs the same miles and repeat trips don't call Google again.
///
/// Keyed by direction (A→B and B→A can differ because of one-way streets).
class CachedDistanceService implements DistanceService {
  CachedDistanceService(this._inner, this._store);

  final DistanceService _inner;
  final LocalStore _store;

  @override
  bool get isDemo => _inner.isDemo;

  @override
  Future<double> drivingMiles(Place from, Place to) async {
    final key = '${placeKey(from)}>${placeKey(to)}';
    final cached = _store.cachedMiles(key);
    if (cached != null) return cached;
    final miles = await _inner.drivingMiles(from, to);
    await _store.cacheMiles(key, miles);
    return miles;
  }

  static String placeKey(Place p) => p.placeId != null
      ? 'id:${p.placeId}'
      : 'addr:${AddressMatcher.normalize(p.address)}';
}
