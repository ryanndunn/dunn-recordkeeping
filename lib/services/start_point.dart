import '../models/place.dart';
import '../models/trip.dart';

/// Where the next trip starts: the destination of the most recent trip
/// logged today, otherwise home/office. Returns null if there are no trips
/// today and no home address is set. On equal times the trip later in
/// [trips] (logged more recently) wins.
Place? resolveStartPoint({
  required List<Trip> trips,
  required Place? home,
  required DateTime now,
}) {
  Trip? latestToday;
  for (final t in trips) {
    if (!isSameDay(t.date, now)) continue;
    if (latestToday == null || !t.date.isBefore(latestToday.date)) {
      latestToday = t;
    }
  }
  return latestToday?.to ?? home;
}

bool isSameDay(DateTime a, DateTime b) {
  final la = a.toLocal();
  final lb = b.toLocal();
  return la.year == lb.year && la.month == lb.month && la.day == lb.day;
}
