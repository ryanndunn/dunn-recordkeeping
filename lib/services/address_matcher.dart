import 'dart:math' as math;

import '../models/saved_address.dart';

/// What the user typed or picked, to be checked against the saved list.
class AddressQuery {
  const AddressQuery({required this.text, this.placeId, this.lat, this.lng});

  final String text;
  final String? placeId;
  final double? lat;
  final double? lng;
}

/// Decides whether an entered address is one of the user's saved addresses.
///
/// Checks, in order: same Google place ID, same name, same address once
/// normalized, a typed street line that fits exactly one saved address, and
/// coordinates within [maxDistanceMeters].
class AddressMatcher {
  const AddressMatcher({this.maxDistanceMeters = 75});

  final double maxDistanceMeters;

  SavedAddress? match(AddressQuery query, List<SavedAddress> saved) {
    if (saved.isEmpty) return null;

    if (query.placeId != null) {
      for (final a in saved) {
        if (a.placeId != null && a.placeId == query.placeId) return a;
      }
    }

    final q = normalize(query.text);
    if (q.isNotEmpty) {
      for (final a in saved) {
        if (normalize(a.name) == q) return a;
      }
      for (final a in saved) {
        if (normalize(a.address) == q) return a;
      }

      // "123 Main St" typed, "123 Main St, Springfield, IL 62701" saved.
      // Only counts if it starts with a house number and fits exactly one.
      if (RegExp(r'^\d+\s+\S+').hasMatch(q)) {
        final prefixMatches = saved
            .where((a) => _startsWithWords(normalize(a.address), q))
            .toList();
        if (prefixMatches.length == 1) return prefixMatches.single;
      }
    }

    if (query.lat != null && query.lng != null) {
      SavedAddress? best;
      var bestDistance = double.infinity;
      for (final a in saved) {
        if (a.lat == null || a.lng == null) continue;
        final d = distanceMeters(query.lat!, query.lng!, a.lat!, a.lng!);
        if (d <= maxDistanceMeters && d < bestDistance) {
          best = a;
          bestDistance = d;
        }
      }
      if (best != null) return best;
    }

    return null;
  }

  /// Saved addresses to suggest while the user types, best first.
  List<SavedAddress> suggestions(String text, List<SavedAddress> saved) {
    final q = normalize(text);
    if (q.isEmpty) {
      final all = [...saved]
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return all;
    }
    int rank(SavedAddress a) {
      final name = normalize(a.name);
      final address = normalize(a.address);
      if (name.startsWith(q)) return 0;
      if (name.contains(q)) return 1;
      if (address.startsWith(q)) return 2;
      if (address.contains(q)) return 3;
      return -1;
    }

    final ranked =
        [
          for (final a in saved)
            if (rank(a) >= 0) (rank(a), a),
        ]..sort((x, y) {
          final byRank = x.$1.compareTo(y.$1);
          return byRank != 0
              ? byRank
              : x.$2.name.toLowerCase().compareTo(y.$2.name.toLowerCase());
        });
    return [for (final r in ranked) r.$2];
  }

  static bool _startsWithWords(String full, String prefix) =>
      full == prefix || full.startsWith('$prefix ');

  static const _abbreviations = {
    'street': 'st',
    'avenue': 'ave',
    'av': 'ave',
    'road': 'rd',
    'drive': 'dr',
    'boulevard': 'blvd',
    'lane': 'ln',
    'court': 'ct',
    'circle': 'cir',
    'place': 'pl',
    'parkway': 'pkwy',
    'highway': 'hwy',
    'terrace': 'ter',
    'trail': 'trl',
    'square': 'sq',
    'suite': 'ste',
    'apartment': 'apt',
    'building': 'bldg',
    'north': 'n',
    'south': 's',
    'east': 'e',
    'west': 'w',
    'northeast': 'ne',
    'northwest': 'nw',
    'southeast': 'se',
    'southwest': 'sw',
  };

  /// Lowercases, drops punctuation and country suffixes, and shortens common
  /// street words so "123 Main Street, Suite 4" equals "123 main st ste 4".
  static String normalize(String input) {
    var s = input.toLowerCase().trim();
    s = s.replaceAll(
      RegExp(r'(,\s*|\s+)(usa|us|united states( of america)?)$'),
      '',
    );
    s = s.replaceAll('#', ' ste ');
    s = s.replaceAll(RegExp(r"[^\w\s]"), ' ');
    final words = s
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .map((w) => _abbreviations[w] ?? w);
    return words.join(' ');
  }

  /// Great-circle distance between two lat/lng points, in meters.
  static double distanceMeters(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) {
    const earthRadius = 6371000.0;
    double rad(double deg) => deg * math.pi / 180;
    final dLat = rad(lat2 - lat1);
    final dLng = rad(lng2 - lng1);
    final h =
        math.pow(math.sin(dLat / 2), 2) +
        math.cos(rad(lat1)) *
            math.cos(rad(lat2)) *
            math.pow(math.sin(dLng / 2), 2);
    return 2 * earthRadius * math.asin(math.sqrt(h));
  }
}
