import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';

import '../../models/saved_address.dart';
import '../../services/availability_link.dart';
import '../../services/google_calendar.dart';
import '../../services/jobs.dart' show formatClock;
import '../../state/calendar_provider.dart';
import '../../state/providers.dart';
import '../clients/client_page.dart';

const _uuid = Uuid();
const _hourHeight = 48.0;
const _gutter = 48.0;

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// Something on the calendar: a Google event or a booked session.
class _Item {
  const _Item({
    required this.start,
    required this.end,
    required this.title,
    required this.color,
    required this.onTap,
    this.session = false,
  });

  final DateTime start;
  final DateTime end;
  final String title;
  final Color color;
  final VoidCallback onTap;

  /// A client session booked in the app (drawn outlined).
  final bool session;
}

/// Your Google Calendar with clients' booked sessions on it, to fit
/// sessions between personal events. Tap a free spot to book a session
/// there. Consultation availability (Google appointment schedules) is a
/// button away.
class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  late DateTime _anchor = _day(ref.read(clockProvider)());
  final _scroll = ScrollController(initialScrollOffset: 7 * _hourHeight);
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Keeps the "now" line moving.
    _tick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  /// The first day shown: Sunday for a week, else the anchor day.
  DateTime _first(int days) => days == 7
      ? _anchor.subtract(Duration(days: _anchor.weekday % 7))
      : _anchor;

  void _move(int days) =>
      setState(() => _anchor = _anchor.add(Duration(days: days)));

  Future<void> _pickDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _anchor,
      firstDate: DateTime(2000),
      lastDate: DateTime(_anchor.year + 5),
    );
    if (picked != null) setState(() => _anchor = _day(picked));
  }

  String _rangeLabel(DateTime first, int days) {
    final last = first.add(Duration(days: days - 1));
    final m1 = _months[first.month - 1];
    final m2 = _months[last.month - 1];
    if (days == 1) return '${_weekdays[first.weekday - 1]}, $m1 ${first.day}';
    if (first.month == last.month) {
      return '$m1 ${first.day} – ${last.day}, ${last.year}';
    }
    return '$m1 ${first.day} – $m2 ${last.day}, ${last.year}';
  }

  Future<void> _openEvent(CalendarEvent e) async {
    final calendar = ref.read(calendarProvider).calendar(e.calendarId);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final theme = Theme.of(context);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.title, style: theme.textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  e.allDay
                      ? 'All day'
                      : '${formatClock(e.start)} – ${formatClock(e.end)}',
                ),
                if (e.location.isNotEmpty) Text(e.location),
                if (calendar != null)
                  Text(
                    calendar.name,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                if (e.link != null) ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => openClientLink(context, e.link!),
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('Open in Google Calendar'),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  void _openClient(String id) => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => ClientPage(clientId: id)));

  /// A free spot was tapped: book a client there.
  Future<void> _bookAt(DateTime start) async {
    final clients = [
      for (final c in ref.read(addressesProvider))
        if (c.status != ClientStatus.archived) c,
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    if (clients.isEmpty) return;
    final client = await showDialog<SavedAddress>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(
          'Book a session at ${formatClock(start)}, '
          '${_weekdays[start.weekday - 1]} ${start.month}/${start.day}',
        ),
        children: [
          for (final c in clients)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, c),
              child: Text(c.name),
            ),
        ],
      ),
    );
    if (client == null || !mounted) return;
    final result = await showBookingDialog(
      context,
      now: ref.read(clockProvider)(),
      hourlyRate: client.hourlyRate,
      initialStart: start,
      clientName: client.name,
    );
    if (result == null || result.delete || result.start == null) return;
    final latest = ref
        .read(addressesProvider)
        .where((c) => c.id == client.id)
        .firstOrNull;
    if (latest == null) return;
    await ref
        .read(addressesProvider.notifier)
        .replace(
          latest.copyWith(
            scheduled: [
              ...latest.scheduled,
              ScheduledJob(
                id: _uuid.v4(),
                start: result.start!,
                end: result.end,
                notes: result.notes,
              ),
            ]..sort((a, b) => a.start.compareTo(b.start)),
          ),
        );
  }

  Future<void> _chooseCalendars() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => Consumer(
        builder: (context, ref, _) {
          final state = ref.watch(calendarProvider);
          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final c in state.calendars)
                  CheckboxListTile(
                    value: state.isShown(c),
                    onChanged: (v) => ref
                        .read(calendarProvider.notifier)
                        .setShown(c, v ?? false),
                    secondary: CircleAvatar(
                      radius: 8,
                      backgroundColor: Color(c.color),
                    ),
                    title: Text(c.name),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final cal = ref.watch(calendarProvider);
    final clients = ref.watch(addressesProvider);
    final signedIn = ref.watch(syncProvider.select((s) => s.signedIn));
    final canConnect = ref.watch(googleAccountServiceProvider) != null;
    final now = ref.read(clockProvider)();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Calendar'),
        actions: [
          if (cal.connected == true) ...[
            if (cal.calendars.length > 1)
              IconButton(
                tooltip: 'Calendars shown',
                icon: const Icon(Icons.checklist),
                onPressed: _chooseCalendars,
              ),
            IconButton(
              tooltip: 'Refresh',
              icon: cal.loading
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              onPressed: cal.loading
                  ? null
                  : () => ref.read(calendarProvider.notifier).refresh(),
            ),
          ],
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final days = constraints.maxWidth < 600 ? 3 : 7;
          final first = _first(days);
          final end = first.add(Duration(days: days));
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) ref.read(calendarProvider.notifier).show(first, end);
          });

          // Everything on each day shown.
          final timed = List.generate(days, (_) => <_Item>[]);
          final allDay = List.generate(days, (_) => <_Item>[]);
          void place(_Item item, {required bool wholeDay}) {
            for (var i = 0; i < days; i++) {
              final d = first.add(Duration(days: i));
              final next = d.add(const Duration(days: 1));
              if (item.end.isAfter(d) && item.start.isBefore(next)) {
                (wholeDay ? allDay : timed)[i].add(item);
              }
            }
          }

          for (final e in cal.events) {
            final color = Color(
              cal.calendar(e.calendarId)?.color ?? 0xFF039BE5,
            );
            place(
              _Item(
                start: e.start,
                end: e.end,
                title: e.title,
                color: color,
                onTap: () => _openEvent(e),
              ),
              wholeDay: e.allDay || e.end.difference(e.start).inHours >= 24,
            );
          }
          for (final c in clients) {
            for (final s in c.scheduled) {
              place(
                _Item(
                  start: s.start,
                  end: s.end ?? s.start.add(const Duration(hours: 1)),
                  title: c.name,
                  color: scheme.primary,
                  session: true,
                  onTap: () => _openClient(c.id),
                ),
                wholeDay: false,
              );
            }
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Where you are, and consultation availability.
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    IconButton(
                      tooltip: 'Earlier',
                      icon: const Icon(Icons.chevron_left),
                      onPressed: () => _move(-days),
                    ),
                    TextButton(
                      onPressed: _pickDay,
                      child: Text(
                        _rangeLabel(first, days),
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Later',
                      icon: const Icon(Icons.chevron_right),
                      onPressed: () => _move(days),
                    ),
                    OutlinedButton(
                      onPressed: () => setState(() => _anchor = _day(now)),
                      child: const Text('Today'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonalIcon(
                      onPressed: openAvailabilityEditor,
                      icon: const Icon(Icons.edit_calendar_outlined),
                      label: const Text('Consultation Availability'),
                    ),
                  ],
                ),
              ),
              if (canConnect && cal.connected == false)
                _Notice(
                  text: signedIn
                      ? 'Connect Google Calendar to see your personal events '
                            'here, around clients\' sessions. The app can '
                            'only read your calendar, never change it.'
                      : 'Sign in to Google in Settings, then connect Google '
                            'Calendar to see your events here.',
                  action: signedIn
                      ? FilledButton(
                          onPressed: () =>
                              ref.read(calendarProvider.notifier).connect(),
                          child: const Text('Connect'),
                        )
                      : null,
                ),
              if (cal.error != null)
                _Notice(
                  text: cal.error!,
                  error: true,
                  action: TextButton(
                    onPressed: () =>
                        ref.read(calendarProvider.notifier).refresh(),
                    child: const Text('Try again'),
                  ),
                ),
              _DayHeaders(first: first, days: days, today: _day(now)),
              if (allDay.any((d) => d.isNotEmpty)) _AllDayRow(items: allDay),
              const Divider(height: 1),
              Expanded(
                child: SingleChildScrollView(
                  controller: _scroll,
                  child: SizedBox(
                    height: 24 * _hourHeight,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const _HourLabels(),
                        for (var i = 0; i < days; i++)
                          Expanded(
                            child: _DayColumn(
                              day: first.add(Duration(days: i)),
                              items: timed[i],
                              now: now,
                              onEmptyTap: _bookAt,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, this.action, this.error = false});

  final String text;
  final Widget? action;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: error ? scheme.errorContainer : scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  color: error
                      ? scheme.onErrorContainer
                      : scheme.onSecondaryContainer,
                ),
              ),
            ),
            if (action != null) ...[const SizedBox(width: 8), action!],
          ],
        ),
      ),
    );
  }
}

class _DayHeaders extends StatelessWidget {
  const _DayHeaders({
    required this.first,
    required this.days,
    required this.today,
  });

  final DateTime first;
  final int days;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      children: [
        const SizedBox(width: _gutter),
        for (var i = 0; i < days; i++)
          Expanded(
            child: Builder(
              builder: (context) {
                final d = first.add(Duration(days: i));
                final isToday = d == today;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    children: [
                      Text(
                        _weekdays[d.weekday - 1],
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: isToday
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                      Container(
                        width: 32,
                        height: 32,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: isToday ? scheme.primary : null,
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          '${d.day}',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: isToday ? scheme.onPrimary : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _AllDayRow extends StatelessWidget {
  const _AllDayRow({required this.items});

  final List<List<_Item>> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: _gutter,
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'All day',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall,
            ),
          ),
        ),
        for (final day in items)
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final item in day)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(1, 1, 1, 1),
                    child: Material(
                      color: item.color,
                      borderRadius: BorderRadius.circular(4),
                      child: InkWell(
                        onTap: item.onTap,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 2,
                          ),
                          child: Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: _onColor(item.color),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _HourLabels extends StatelessWidget {
  const _HourLabels();

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return SizedBox(
      width: _gutter,
      child: Stack(
        children: [
          for (var h = 1; h < 24; h++)
            Positioned(
              top: h * _hourHeight - 7,
              right: 6,
              child: Text(
                '${h % 12 == 0 ? 12 : h % 12} ${h < 12 ? 'AM' : 'PM'}',
                style: style,
              ),
            ),
        ],
      ),
    );
  }
}

Color _onColor(Color c) =>
    c.computeLuminance() > 0.5 ? Colors.black87 : Colors.white;

/// One day's hours, with its events and sessions placed by time. Tapping
/// an empty spot offers to book a session there (on the half hour).
class _DayColumn extends StatelessWidget {
  const _DayColumn({
    required this.day,
    required this.items,
    required this.now,
    required this.onEmptyTap,
  });

  final DateTime day;
  final List<_Item> items;
  final DateTime now;
  final void Function(DateTime start) onEmptyTap;

  double _y(DateTime t) {
    if (t.isBefore(day)) return 0;
    final next = day.add(const Duration(days: 1));
    if (!t.isBefore(next)) return 24 * _hourHeight;
    return t.difference(day).inMinutes / 60 * _hourHeight;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final layout = layoutOverlaps([
      for (final i in items) (start: i.start, end: i.end),
    ]);
    final isToday = _day(now) == day;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) {
            final minutes = (d.localPosition.dy / _hourHeight * 60).floor();
            final snapped = (minutes ~/ 30) * 30;
            onEmptyTap(day.add(Duration(minutes: snapped)));
          },
          child: Stack(
            children: [
              // Hour lines and the day's left edge.
              for (var h = 0; h < 24; h++)
                Positioned(
                  top: h * _hourHeight,
                  left: 0,
                  right: 0,
                  child: Divider(height: 1, color: scheme.outlineVariant),
                ),
              Positioned(
                top: 0,
                bottom: 0,
                left: 0,
                child: VerticalDivider(width: 1, color: scheme.outlineVariant),
              ),
              for (var i = 0; i < items.length; i++)
                Builder(
                  builder: (context) {
                    final item = items[i];
                    final top = _y(item.start);
                    final height = (_y(item.end) - top).clamp(
                      18.0,
                      24 * _hourHeight,
                    );
                    final colWidth = (width - 4) / layout[i].columns;
                    final fg = item.session
                        ? scheme.onPrimaryContainer
                        : _onColor(item.color);
                    return Positioned(
                      top: top + 1,
                      height: height - 2,
                      left: 2 + layout[i].column * colWidth,
                      width: colWidth - 2,
                      child: Material(
                        color: item.session
                            ? scheme.primaryContainer
                            : item.color,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4),
                          side: item.session
                              ? BorderSide(color: scheme.primary, width: 1.5)
                              : BorderSide.none,
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: item.onTap,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 2,
                            ),
                            child: Text(
                              height < 34
                                  ? item.title
                                  : '${item.title}\n'
                                        '${formatClock(item.start)} – '
                                        '${formatClock(item.end)}',
                              overflow: TextOverflow.fade,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: fg,
                                fontWeight: item.session
                                    ? FontWeight.w600
                                    : null,
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              if (isToday)
                Positioned(
                  top: _y(now) - 1,
                  left: 0,
                  right: 0,
                  child: Container(height: 2, color: scheme.error),
                ),
            ],
          ),
        );
      },
    );
  }
}
