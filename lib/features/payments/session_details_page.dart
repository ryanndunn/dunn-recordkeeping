import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/billing.dart';
import '../../models/trip.dart';
import '../../services/client_jobs.dart';
import '../../services/club.dart' show longDay;
import '../../services/jobs.dart' show formatClock, formatHours;
import '../../state/money_provider.dart';
import '../../state/providers.dart';
import '../../widgets/page_body.dart';
import '../../widgets/refresh_all_button.dart';
import '../clients/client_page.dart';
import '../clients/client_status.dart';
import 'payments_screen.dart' show money;
import 'send_bill_dialog.dart';

/// Everything about one session: when it was booked and recorded, time at
/// each client, the drives, and its billing.
class SessionDetailsPage extends ConsumerWidget {
  const SessionDetailsPage({super.key, required this.row});

  /// The session as it was when opened; the page follows later changes.
  final SessionRow row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = row.session.billingKeys.first;
    final r =
        ref
            .watch(allSessionsProvider)
            .where(
              (x) =>
                  x.client.id == row.client.id &&
                  x.session.billingKeys.first == key,
            )
            .firstOrNull ??
        row;
    final theme = Theme.of(context);
    final s = r.session;
    final job = s.job;
    final b = r.billing;
    final now = ref.read(clockProvider)();

    // The drives during it: this device's trips, or (recorded on the
    // other device) just where it went.
    final end = s.end ?? (job != null && job.isActive ? now : s.start);
    // Through the drive away from the last client.
    final last = job?.lastActivity;
    final drivesUntil = last != null && last.isAfter(end) ? last : end;
    final drives =
        job == null
              ? <Trip>[]
              : [
                  for (final t in ref.watch(tripsProvider))
                    if (!t.date.isBefore(job.start) &&
                        !t.date.isAfter(drivesUntil))
                      t,
                ]
          ..sort((a, b) => a.date.compareTo(b.date));
    final stops = job == null
        ? const []
        : ref
                  .watch(allJobSummariesProvider)
                  .where((j) => j.job.id == job.id)
                  .firstOrNull
                  ?.stops ??
              const [];

    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(0, 20, 0, 4),
      child: Text(text, style: theme.textTheme.titleMedium),
    );
    Widget fact(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
    String span(DateTime a, DateTime? b) => b == null
        ? '${formatClock(a)} – now'
        : '${formatClock(a)} – ${formatClock(b)}';

    final booked = s.scheduled;
    final state = switch (s.state) {
      ClientJobState.upcoming => 'Upcoming',
      ClientJobState.inProgress => 'In progress',
      ClientJobState.completed => 'Done',
    };
    final colors = billingColors(b.status, theme.colorScheme);
    final link = b.link;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Session details'),
        actions: const [RefreshAllButton()],
      ),
      body: PageListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          InkWell(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ClientPage(clientId: r.client.id),
              ),
            ),
            child: Text(
              r.client.name,
              style: theme.textTheme.headlineSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          Text(
            '${longDay(s.start)}, ${s.start.year} · $state',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: colors.bg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  b.status.label,
                  style: theme.textTheme.labelLarge?.copyWith(color: colors.fg),
                ),
              ),
              if (r.amount != null)
                Text(money(r.amount!), style: theme.textTheme.titleMedium),
            ],
          ),

          heading('Time'),
          if (booked != null) fact('Booked', span(booked.start, booked.end)),
          if (booked != null && booked.notes.isNotEmpty)
            fact('Booking notes', booked.notes),
          if (job != null) ...[
            fact('Recorded', span(job.start, s.end)),
            if (s.withClient != null)
              fact('With ${r.client.name}', formatHours(s.withClient!)),
          ] else if (!s.timeTracked)
            fact('Recorded', 'Trips only (before sessions were timed)')
          else if (booked == null || s.state != ClientJobState.upcoming)
            fact('Recorded', 'Nothing recorded by the phone'),
          if (s.time != null) fact('Billed time', formatHours(s.time!)),

          if (job != null && job.visits.isNotEmpty) ...[
            heading('Stops at clients'),
            for (final v in job.visits)
              fact(
                v.client,
                '${span(v.arrived, v.left)} · '
                '${formatHours(v.length(job.end ?? now))}',
              ),
          ],
          if (s.otherClients.isNotEmpty)
            fact('Also visited', s.otherClients.join(', ')),
          if (s.places.isNotEmpty) fact('Their addresses', s.places.join(', ')),

          heading('Driving'),
          fact(
            'Miles',
            '${s.driveMiles.toStringAsFixed(1)} mi, with the drive there '
                'and back',
          ),
          if (s.otherClients.isNotEmpty)
            fact('Between clients', '${s.miles.toStringAsFixed(1)} mi'),
          if (drives.isNotEmpty)
            for (final t in drives)
              fact(
                formatClock(t.date),
                '${t.from.label} → ${t.to.label} · '
                '${t.miles.toStringAsFixed(1)} mi'
                '${t.estimated ? ' (estimate)' : ''}',
              )
          else if (stops.isNotEmpty)
            fact('Stops', [for (final p in stops) p.label].join(' → ')),

          heading('Billing'),
          fact('Status', b.status.label),
          fact(
            'Amount',
            r.amount == null
                ? 'Not set'
                : '${money(r.amount!)}'
                      '${b.amount == null ? ' at ${money(r.client.hourlyRate)}/hr' : ''}',
          ),
          if (b.method != null) fact('Paid by', b.method!.label),
          if (b.paidOn != null) fact('Paid on', formatShortDate(b.paidOn!)),
          if (b.stripeId != null) fact('Stripe', 'Paid through Stripe'),
          if (link != null)
            fact(
              'Payment link',
              '${money(link.amount)} · sent ${formatShortDate(link.createdOn)}'
                  '\n${link.url}',
            ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => editSessionBilling(
                  context,
                  ref,
                  clientId: r.client.id,
                  session: s,
                ),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Edit billing'),
              ),
              if (b.status != BillingStatus.paid)
                FilledButton.icon(
                  onPressed: () => showSendBillDialog(
                    context,
                    clientId: r.client.id,
                    session: s,
                  ),
                  icon: const Icon(Icons.send_outlined),
                  label: Text(
                    b.status == BillingStatus.billed
                        ? 'Resend bill'
                        : 'Send bill',
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
