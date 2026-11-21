import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../services/jobs.dart' show formatClock;
import '../../services/tracking_log.dart';
import '../../state/providers.dart';
import '../../widgets/page_body.dart';
import '../../widgets/refresh_all_button.dart';
import '../clients/client_status.dart' show formatShortDate;

/// What automatic tracking saw and did, newest first: arrivals, departures,
/// stops found during a session, and sessions starting and ending.
class TrackingActivityPage extends ConsumerStatefulWidget {
  const TrackingActivityPage({super.key});

  @override
  ConsumerState<TrackingActivityPage> createState() =>
      _TrackingActivityPageState();
}

class _TrackingActivityPageState extends ConsumerState<TrackingActivityPage> {
  List<TrackingEvent> _events = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = ref.read(localStoreProvider);
    await store.reload();
    if (mounted) setState(() => _events = store.loadTrackingLog());
  }

  String _line(TrackingEvent e) =>
      '${formatShortDate(e.at)} ${formatClock(e.at)}  ${e.message}';

  Future<void> _copy() async {
    await Clipboard.setData(
      ClipboardData(text: [for (final e in _events) _line(e)].join('\n')),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Tracking activity copied')));
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear tracking activity?'),
        content: const Text(
          'This only clears this list. Trips and sessions are not changed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(localStoreProvider).clearTrackingLog();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final children = <Widget>[];
    DateTime? day;
    for (final e in _events) {
      final d = DateTime(e.at.year, e.at.month, e.at.day);
      if (d != day) {
        day = d;
        children.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              formatShortDate(d),
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        );
      }
      children.add(
        ListTile(
          dense: true,
          leading: SizedBox(
            width: 64,
            child: Text(formatClock(e.at), style: theme.textTheme.bodySmall),
          ),
          title: Text(e.message),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tracking activity'),
        actions: [
          IconButton(
            tooltip: 'Copy all',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: _events.isEmpty ? null : _copy,
          ),
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _events.isEmpty ? null : _clear,
          ),
          RefreshAllButton(onDone: _load),
        ],
      ),
      body: _events.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Nothing yet. Arrivals, departures and stops the phone '
                'notices while logging trips automatically show here.',
              ),
            )
          : PageListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: children,
            ),
    );
  }
}
