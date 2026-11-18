import 'address_matcher.dart';
import 'auto_trip.dart' show arrivalStayTime;

/// A place the phone stayed at.
class DetectedStop {
  const DetectedStop(this.lat, this.lng, this.arrivedAt);

  final double lat;
  final double lng;
  final DateTime arrivedAt;
}

/// Turns a stream of phone positions into stops: staying within
/// [radiusMeters] for [stayTime] is a stop. After a stop, the phone must
/// move [leaveMeters] away before another stop can be found.
class StopDetector {
  StopDetector({
    this.radiusMeters = 120,
    this.leaveMeters = 250,
    this.stayTime = arrivalStayTime,
  });

  final double radiusMeters;
  final double leaveMeters;
  final Duration stayTime;

  ({double lat, double lng, DateTime since})? _anchor;
  ({double lat, double lng})? _stoppedAt;

  /// Starts out already stopped here (e.g. the client where the job
  /// began), so that place isn't reported again.
  void startStoppedAt(double lat, double lng) {
    _stoppedAt = (lat: lat, lng: lng);
    _anchor = null;
  }

  /// Feeds one position. Returns a stop once the phone has stayed put
  /// long enough.
  DetectedStop? add(double lat, double lng, DateTime at) {
    final stopped = _stoppedAt;
    if (stopped != null) {
      if (_distance(lat, lng, stopped.lat, stopped.lng) < leaveMeters) {
        return null; // Still at the last stop.
      }
      _stoppedAt = null;
      _anchor = (lat: lat, lng: lng, since: at);
      return null;
    }

    final anchor = _anchor;
    if (anchor == null ||
        _distance(lat, lng, anchor.lat, anchor.lng) > radiusMeters) {
      _anchor = (lat: lat, lng: lng, since: at); // Moving.
      return null;
    }
    if (at.difference(anchor.since) >= stayTime) {
      _stoppedAt = (lat: anchor.lat, lng: anchor.lng);
      _anchor = null;
      return DetectedStop(anchor.lat, anchor.lng, anchor.since);
    }
    return null;
  }

  static double _distance(double aLat, double aLng, double bLat, double bLng) =>
      AddressMatcher.distanceMeters(aLat, aLng, bLat, bLng);
}
