import '../models/saved_address.dart';

/// How the client list is ordered.
enum ClientSort {
  nameAZ('Name (A–Z)'),
  nameZA('Name (Z–A)'),
  status('Status'),
  nextJob('Next scheduled session'),
  recent('Recently changed');

  const ClientSort(this.label);
  final String label;
}

/// True when [query] appears in the client's name, any of their
/// addresses (or address names), email, phone, or another contact's
/// name, email or phone. Phone numbers match by
/// digits, so "5550142" finds "(309) 555-0142".
bool clientMatches(SavedAddress c, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  final words = q.split(RegExp(r'\s+'));
  final text = [
    c.name,
    c.address,
    c.email,
    c.phone,
    c.addressLabel,
    for (final l in c.locations) ...[l.label, l.address],
    for (final p in c.contacts) ...[p.name, p.email, p.phone],
  ].join(' ').toLowerCase();
  final digits = [
    c.phone,
    for (final p in c.contacts) p.phone,
  ].join(' ').replaceAll(RegExp(r'\D'), '');
  return words.every((w) {
    if (text.contains(w)) return true;
    final d = w.replaceAll(RegExp(r'\D'), '');
    return d.length >= 3 &&
        d.length == w.replaceAll(RegExp(r'[\s().+-]'), '').length &&
        digits.contains(d);
  });
}

/// The next booked job from [now] on, if any.
DateTime? nextScheduledJob(SavedAddress c, DateTime now) {
  DateTime? next;
  for (final s in c.scheduled) {
    if (s.start.isBefore(now)) continue;
    if (next == null || s.start.isBefore(next)) next = s.start;
  }
  return next;
}

/// [clients] in [sort] order (ties by name).
List<SavedAddress> sortClients(
  List<SavedAddress> clients,
  ClientSort sort,
  DateTime now,
) {
  int byName(SavedAddress a, SavedAddress b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase());

  int compare(SavedAddress a, SavedAddress b) {
    switch (sort) {
      case ClientSort.nameAZ:
        return byName(a, b);
      case ClientSort.nameZA:
        return byName(b, a);
      case ClientSort.status:
        final s = a.status.index.compareTo(b.status.index);
        return s != 0 ? s : byName(a, b);
      case ClientSort.nextJob:
        final na = nextScheduledJob(a, now);
        final nb = nextScheduledJob(b, now);
        if (na == null && nb == null) return byName(a, b);
        if (na == null) return 1;
        if (nb == null) return -1;
        final t = na.compareTo(nb);
        return t != 0 ? t : byName(a, b);
      case ClientSort.recent:
        final ua = a.updatedAt;
        final ub = b.updatedAt;
        if (ua == null && ub == null) return byName(a, b);
        if (ua == null) return 1;
        if (ub == null) return -1;
        final t = ub.compareTo(ua);
        return t != 0 ? t : byName(a, b);
    }
  }

  return [...clients]..sort(compare);
}
