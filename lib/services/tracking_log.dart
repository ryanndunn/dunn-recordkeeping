import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

/// One thing the phone noticed while tracking: arriving at or leaving a
/// place, a stop found during a session, a session starting or ending.
class TrackingEvent {
  const TrackingEvent(this.at, this.message);

  final DateTime at;
  final String message;
}

/// A short on-phone history of what automatic tracking saw and did, so a
/// missed stop can be explained afterwards (Settings → Tracking activity).
/// Written from the background as well as the app; kept to the last
/// [keep] events.
class TrackingLog {
  static const key = 'tracking_log_v1';
  static const keep = 400;
  static const _sep = '|';

  /// Adds [message]. Never throws: the log must not break tracking.
  static Future<void> add(String message, {DateTime? at}) async {
    debugPrint('Dunn Record Keeping: $message');
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final list = [
        ...?prefs.getStringList(key),
        '${(at ?? DateTime.now()).toIso8601String()}$_sep$message',
      ];
      await prefs.setStringList(
        key,
        list.length > keep ? list.sublist(list.length - keep) : list,
      );
    } catch (_) {}
  }

  /// Newest first.
  static List<TrackingEvent> read(SharedPreferences prefs) => [
    for (final line in (prefs.getStringList(key) ?? const []).reversed)
      ?_parse(line),
  ];

  static Future<void> clear(SharedPreferences prefs) => prefs.remove(key);

  static TrackingEvent? _parse(String line) {
    final i = line.indexOf(_sep);
    if (i < 0) return null;
    final at = DateTime.tryParse(line.substring(0, i));
    return at == null ? null : TrackingEvent(at, line.substring(i + 1));
  }
}
