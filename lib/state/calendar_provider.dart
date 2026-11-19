import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:googleapis/calendar/v3.dart' as gcal;
import 'package:http/http.dart' as http;

import '../services/google_account.dart';
import '../services/google_calendar.dart';
import 'providers.dart';

/// Reads calendars with a client that has [calendarScope] (overridden in
/// tests).
final calendarSourceFactoryProvider =
    Provider<CalendarSource Function(http.Client)>(
      (ref) =>
          (client) => GoogleCalendarSource(client),
    );

class CalendarState {
  const CalendarState({
    this.connected,
    this.calendars = const [],
    this.shown,
    this.events = const [],
    this.from,
    this.to,
    this.loading = false,
    this.error,
  });

  /// Whether this device may read Google Calendar (null until checked).
  final bool? connected;
  final List<CalendarInfo> calendars;

  /// Calendar IDs shown, or null for the ones checked in Google Calendar.
  final Set<String>? shown;

  /// Events of the shown calendars between [from] and [to].
  final List<CalendarEvent> events;
  final DateTime? from;
  final DateTime? to;
  final bool loading;
  final String? error;

  bool isShown(CalendarInfo c) => shown?.contains(c.id) ?? c.selected;

  CalendarInfo? calendar(String id) =>
      calendars.where((c) => c.id == id).firstOrNull;

  CalendarState copyWith({
    bool? connected,
    List<CalendarInfo>? calendars,
    Set<String>? shown,
    List<CalendarEvent>? events,
    DateTime? from,
    DateTime? to,
    bool? loading,
    String? error,
    bool clearError = false,
  }) => CalendarState(
    connected: connected ?? this.connected,
    calendars: calendars ?? this.calendars,
    shown: shown ?? this.shown,
    events: events ?? this.events,
    from: from ?? this.from,
    to: to ?? this.to,
    loading: loading ?? this.loading,
    error: clearError ? null : (error ?? this.error),
  );
}

final calendarProvider = NotifierProvider<CalendarNotifier, CalendarState>(
  CalendarNotifier.new,
);

/// Google Calendar events for the Calendar tab. Each device connects on
/// its own (read only); nothing here syncs.
class CalendarNotifier extends Notifier<CalendarState> {
  http.Client? _client;

  /// The days last asked for (to reload after connecting or refreshing).
  DateTime? _wantFrom;
  DateTime? _wantTo;

  @override
  CalendarState build() {
    ref.onDispose(() => _client?.close());
    final raw = ref.read(localStoreProvider).calendarsShownRaw;
    return CalendarState(
      shown: raw == null
          ? null
          : {for (final id in jsonDecode(raw) as List) '$id'},
    );
  }

  GoogleAccountService? get _account => ref.read(googleAccountServiceProvider);

  /// Asks Google for read-only calendar access, then loads.
  Future<void> connect() async {
    final account = _account;
    if (account == null) return;
    try {
      _client = await account.grantAccess(calendarScope);
      state = state.copyWith(connected: true, clearError: true);
      await refresh();
    } on GoogleAccountException catch (e) {
      if (!e.cancelled) state = state.copyWith(error: e.message);
    }
  }

  /// Makes sure events from [from] to [to] are loaded (a few weeks around
  /// them, so moving between weeks is instant).
  Future<void> show(DateTime from, DateTime to) async {
    _wantFrom = from;
    _wantTo = to;
    // Not connected, busy, or failed: wait for Connect or Refresh.
    if (state.connected == false || state.loading || state.error != null) {
      return;
    }
    final f = state.from;
    final t = state.to;
    if (f != null && t != null && !from.isBefore(f) && !to.isAfter(t)) {
      return;
    }
    await _load(
      from: from.subtract(const Duration(days: 14)),
      to: to.add(const Duration(days: 28)),
    );
  }

  /// Loads again (e.g. after changing Google Calendar, or an error).
  Future<void> refresh() {
    state = state.copyWith(clearError: true);
    final from = _wantFrom ?? state.from;
    final to = _wantTo ?? state.to;
    if (from == null || to == null) return Future.value();
    return _load(
      from: from.subtract(const Duration(days: 14)),
      to: to.add(const Duration(days: 28)),
      force: true,
    );
  }

  Future<void> setShown(CalendarInfo calendar, bool shown) async {
    final ids = {
      for (final c in state.calendars)
        if (c.id == calendar.id ? shown : state.isShown(c)) c.id,
    };
    state = state.copyWith(shown: ids);
    await ref
        .read(localStoreProvider)
        .setCalendarsShownRaw(jsonEncode([...ids]));
    await _load(force: true);
  }

  Future<void> _load({DateTime? from, DateTime? to, bool force = false}) async {
    from ??= state.from;
    to ??= state.to;
    if (from == null || to == null) return;
    final account = _account;
    if (account == null) return;
    state = state.copyWith(loading: true);
    _client ??= await account.access(calendarScope);
    final client = _client;
    if (client == null) {
      state = state.copyWith(connected: false, loading: false);
      return;
    }
    state = state.copyWith(connected: true, loading: true, clearError: true);
    try {
      final source = ref.read(calendarSourceFactoryProvider)(client);
      final calendars = state.calendars.isEmpty || force
          ? await source.calendars()
          : state.calendars;
      final shown = state.copyWith(calendars: calendars);
      final ids = [
        for (final c in calendars)
          if (shown.isShown(c)) c.id,
      ];
      final events = await source.events(ids, from, to);
      state = shown.copyWith(
        events: events,
        from: from,
        to: to,
        loading: false,
      );
    } on gcal.DetailedApiRequestError catch (e) {
      state = state.copyWith(
        loading: false,
        error: e.status == 403 && '${e.message}'.contains('API')
            ? 'Google Calendar isn\'t turned on for this app yet. In Google '
                  'Cloud, open APIs & Services → Library, find "Google '
                  'Calendar API" and choose Enable. Then refresh.'
            : 'Couldn\'t load Google Calendar: ${e.message}',
      );
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: 'Couldn\'t load Google Calendar: $e',
      );
    }
  }
}
