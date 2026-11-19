import 'package:googleapis/calendar/v3.dart' as gcal;
import 'package:http/http.dart' as http;

/// One of the user's Google calendars.
class CalendarInfo {
  const CalendarInfo({
    required this.id,
    required this.name,
    required this.color,
    this.selected = true,
  });

  final String id;
  final String name;

  /// ARGB, from the calendar's color in Google Calendar.
  final int color;

  /// Shown in Google Calendar's own list (checked).
  final bool selected;
}

/// An event on one of the user's calendars.
class CalendarEvent {
  const CalendarEvent({
    required this.id,
    required this.calendarId,
    required this.title,
    required this.start,
    required this.end,
    this.allDay = false,
    this.location = '',
    this.link,
  });

  final String id;
  final String calendarId;
  final String title;

  /// Local times. For all-day events, midnight of the first day and of the
  /// day after the last.
  final DateTime start;
  final DateTime end;
  final bool allDay;
  final String location;

  /// The event in Google Calendar.
  final Uri? link;
}

/// Reads the user's calendars and their events.
abstract class CalendarSource {
  Future<List<CalendarInfo>> calendars();

  /// Events on [calendarIds] overlapping [from]–[to], single occurrences
  /// (repeating events expanded).
  Future<List<CalendarEvent>> events(
    List<String> calendarIds,
    DateTime from,
    DateTime to,
  );
}

int _parseColor(String? hex) {
  final h = (hex ?? '').replaceAll('#', '');
  final v = int.tryParse(h, radix: 16);
  return v == null || h.length != 6 ? 0xFF039BE5 : 0xFF000000 | v;
}

class GoogleCalendarSource implements CalendarSource {
  GoogleCalendarSource(http.Client client) : _api = gcal.CalendarApi(client);

  final gcal.CalendarApi _api;

  @override
  Future<List<CalendarInfo>> calendars() async {
    final list = await _api.calendarList.list(minAccessRole: 'reader');
    return [
      for (final c in list.items ?? const <gcal.CalendarListEntry>[])
        if (c.id != null && c.hidden != true)
          CalendarInfo(
            id: c.id!,
            name: c.summaryOverride ?? c.summary ?? c.id!,
            color: _parseColor(c.backgroundColor),
            selected: c.selected ?? false,
          ),
    ];
  }

  @override
  Future<List<CalendarEvent>> events(
    List<String> calendarIds,
    DateTime from,
    DateTime to,
  ) async {
    final results = await Future.wait([
      for (final id in calendarIds) _eventsOf(id, from, to),
    ]);
    return [for (final r in results) ...r];
  }

  Future<List<CalendarEvent>> _eventsOf(
    String calendarId,
    DateTime from,
    DateTime to,
  ) async {
    final out = <CalendarEvent>[];
    String? page;
    do {
      final list = await _api.events.list(
        calendarId,
        timeMin: from.toUtc(),
        timeMax: to.toUtc(),
        singleEvents: true,
        orderBy: 'startTime',
        maxResults: 250,
        pageToken: page,
      );
      for (final e in list.items ?? const <gcal.Event>[]) {
        if (e.status == 'cancelled') continue;
        final event = _event(calendarId, e);
        if (event != null) out.add(event);
      }
      page = list.nextPageToken;
    } while (page != null && out.length < 1000);
    return out;
  }

  static CalendarEvent? _event(String calendarId, gcal.Event e) {
    final s = e.start;
    final en = e.end;
    if (s == null || en == null) return null;
    final allDay = s.date != null;
    final start = allDay ? s.date! : s.dateTime?.toLocal();
    final end = allDay ? en.date! : en.dateTime?.toLocal();
    if (start == null || end == null) return null;
    return CalendarEvent(
      id: e.id ?? '${start.millisecondsSinceEpoch}',
      calendarId: calendarId,
      title: (e.summary ?? '').trim().isEmpty ? '(No title)' : e.summary!,
      start: allDay ? DateTime(start.year, start.month, start.day) : start,
      end: allDay ? DateTime(end.year, end.month, end.day) : end,
      allDay: allDay,
      location: e.location ?? '',
      link: e.htmlLink == null ? null : Uri.tryParse(e.htmlLink!),
    );
  }
}

/// Where timed items go side by side: for each item (by index), its column
/// and how many columns its overlapping group uses.
List<({int column, int columns})> layoutOverlaps(
  List<({DateTime start, DateTime end})> items,
) {
  final order = [for (var i = 0; i < items.length; i++) i]
    ..sort((a, b) {
      final s = items[a].start.compareTo(items[b].start);
      return s != 0 ? s : items[b].end.compareTo(items[a].end);
    });
  final result = List.filled(items.length, (column: 0, columns: 1));
  var group = <int>[];
  var columnEnds = <DateTime>[];
  DateTime? groupEnd;

  void closeGroup() {
    for (final i in group) {
      result[i] = (column: result[i].column, columns: columnEnds.length);
    }
    group = [];
    columnEnds = [];
    groupEnd = null;
  }

  for (final i in order) {
    final item = items[i];
    if (groupEnd != null && !item.start.isBefore(groupEnd!)) closeGroup();
    var col = columnEnds.indexWhere((end) => !item.start.isBefore(end));
    if (col == -1) {
      col = columnEnds.length;
      columnEnds.add(item.end);
    } else {
      columnEnds[col] = item.end;
    }
    result[i] = (column: col, columns: 1);
    group.add(i);
    if (groupEnd == null || item.end.isAfter(groupEnd!)) groupEnd = item.end;
  }
  closeGroup();
  return result;
}
