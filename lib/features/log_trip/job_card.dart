import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/job.dart';
import '../../services/jobs.dart';
import '../../services/start_point.dart';
import '../../state/providers.dart';

/// Today's job time: the running job (with End job), and the jobs done
/// today.
class JobCard extends ConsumerWidget {
  const JobCard({super.key});

  Future<void> _end(BuildContext context, WidgetRef ref, Job job) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('End this session now?'),
        content: Text(
          'Started ${formatClock(job.start)}. Use this if the phone missed '
          'where the session ended. It ends now if you\'re still with a '
          'client, otherwise when you left the last one. Trips already '
          'logged are kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('End session'),
          ),
        ],
      ),
    );
    if (ok == true) await ref.read(jobsProvider.notifier).endNow();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.read(clockProvider)();
    final jobs = ref.watch(jobsProvider);
    final running = activeJob(jobs, now);
    final doneToday = [
      for (final j in jobs)
        if (!j.isActive && isSameDay(j.start, now)) j,
    ];
    final total = doneToday.fold(Duration.zero, (sum, j) => sum + j.duration);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final Widget top;
    if (running != null) {
      final soFar = now.difference(running.start);
      top = ListTile(
        leading: Icon(Icons.work, color: scheme.primary),
        title: Text('In a session since ${formatClock(running.start)}'),
        subtitle: Text(
          [
            '${formatHours(soFar)} so far',
            if (running.clients.isNotEmpty) running.clients.join(', '),
            if (running.startEstimated) 'start time estimated',
          ].join(' · '),
        ),
        trailing: OutlinedButton(
          onPressed: () => _end(context, ref, running),
          child: const Text('End session'),
        ),
      );
    } else {
      top = const ListTile(
        leading: Icon(Icons.work_outline),
        title: Text('Not in a session'),
        subtitle: Text(
          'A session is time with clients: from arriving at the first '
          'client until leaving the last, with the drives between them. '
          'Mileage is logged as always.',
        ),
        isThreeLine: true,
      );
    }

    return Card(
      color: running != null ? scheme.primaryContainer : null,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          top,
          if (doneToday.isNotEmpty) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Today: ${formatHours(total)} on '
                    '${doneToday.length == 1 ? 'a session' : '${doneToday.length} sessions'}',
                    style: theme.textTheme.titleSmall,
                  ),
                  for (final j in doneToday)
                    Text(
                      '${formatClock(j.start)} – ${formatClock(j.end!)} · '
                      '${formatHours(j.duration)}'
                      '${j.clients.isEmpty ? '' : ' · ${j.clients.join(', ')}'}',
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
