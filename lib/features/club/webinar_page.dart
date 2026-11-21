import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';

import '../../models/club_member.dart';
import '../../models/money.dart';
import '../../models/webinar.dart';
import '../../services/club.dart';
import '../../state/club_provider.dart';
import '../../state/providers.dart';
import '../../widgets/page_body.dart';
import '../../widgets/refresh_all_button.dart';
import '../clients/client_page.dart' show openClientLink;
import '../clients/client_status.dart';
import '../payments/payments_screen.dart' show money;
import 'club_dialogs.dart';

const _uuid = Uuid();

/// Adds a webinar (asks when, what and where). A future date makes it an
/// upcoming webinar, ready to invite members to.
Future<void> addWebinar(BuildContext context, WidgetRef ref) async {
  final w = await showDialog<Webinar>(
    context: context,
    builder: (_) => const _WebinarDialog(),
  );
  if (w != null) await ref.read(webinarRecordsProvider.notifier).save(w);
}

/// One webinar: who paid, who comes free and who hasn't paid, the money,
/// and the emails (the invite to the mailing list, the join link to
/// those who paid).
class WebinarPage extends ConsumerWidget {
  const WebinarPage({super.key, required this.id});

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = ref.watch(webinarSummariesProvider);
    final summary = [
      ...all.upcoming,
      ...all.past,
    ].where((s) => s.webinar.id == id).firstOrNull;
    if (summary == null) {
      return Scaffold(
        appBar: AppBar(actions: const [RefreshAllButton()]),
        body: const Padding(
          padding: EdgeInsets.all(24),
          child: Text('This webinar was deleted.'),
        ),
      );
    }
    final theme = Theme.of(context);
    final s = summary;
    final w = s.webinar;
    final upcoming = w.isUpcoming(ref.read(clockProvider)());
    final notifier = ref.read(webinarRecordsProvider.notifier);

    Future<void> edit() async {
      final changed = await showDialog<Webinar>(
        context: context,
        builder: (_) => _WebinarDialog(existing: w),
      );
      if (changed != null) await notifier.save(changed);
    }

    Future<void> delete() async {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Delete this webinar?'),
          content: Text(
            s.paid.isEmpty
                ? 'Who paid or came free for it is forgotten.'
                : 'Its ${s.paid.length} payments (${money(s.money)}) '
                      'stay in Billing.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      await notifier.remove(w.id);
      if (context.mounted) Navigator.of(context).pop();
    }

    void mark(ClubMember m) => showSeatDialog(
      context,
      webinar: w,
      member: m,
      firstMeeting: s.firstTimers.contains(m.id),
    );

    Widget section(String title, List<ClubMember> members, {String? help}) =>
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$title (${members.length})',
                style: theme.textTheme.titleMedium,
              ),
              if (help != null) Text(help, style: theme.textTheme.bodySmall),
              for (final m in members)
                _SeatTile(
                  member: m,
                  seat: s.seats[m.id],
                  firstMeeting: s.firstTimers.contains(m.id),
                  upcoming: upcoming,
                  onTap: () => mark(m),
                ),
            ],
          ),
        );

    final needLink = s.needLink;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Webinar'),
        actions: [
          IconButton(
            tooltip: 'Edit',
            icon: const Icon(Icons.edit_outlined),
            onPressed: edit,
          ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline),
            onPressed: delete,
          ),
          const RefreshAllButton(),
        ],
      ),
      body: PageListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text(
            '${longDay(w.start)}, ${w.start.year}',
            style: theme.textTheme.headlineSmall,
          ),
          Text(clockTime(w.start), style: theme.textTheme.titleMedium),
          if (w.topic.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(w.topic, style: theme.textTheme.bodyLarge),
          ],
          if (w.link.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () {
                  final uri = Uri.tryParse(w.link);
                  if (uri != null) openClientLink(context, uri);
                },
                icon: const Icon(Icons.videocam_outlined),
                label: Text(w.link, overflow: TextOverflow.ellipsis),
              ),
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 24,
            runSpacing: 8,
            children: [
              _Stat('Paid', '${s.paid.length}'),
              _Stat('Free', '${s.free.length}'),
              _Stat(
                upcoming ? 'Not paid' : 'Didn\'t come',
                '${s.notPaid.length}',
              ),
              _Stat('Brought in', money(s.money)),
            ],
          ),
          if (upcoming) ...[
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _sendInvite(context, ref, w),
                  icon: const Icon(Icons.forward_to_inbox),
                  label: Text(
                    w.emailedAt == null ? 'Email the invite' : 'Invite again',
                  ),
                ),
                FilledButton.icon(
                  onPressed: s.attending.isEmpty
                      ? null
                      : () => _sendLink(context, ref, s),
                  icon: const Icon(Icons.link),
                  label: Text(
                    needLink.isEmpty
                        ? 'Send join link'
                        : 'Send join link (${needLink.length})',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              [
                w.emailedAt == null
                    ? 'The invite goes to the mailing list.'
                    : 'Invite drafted ${formatShortDate(w.emailedAt!)}.',
                'The join link goes only to those who paid or come free.',
              ].join(' '),
              style: theme.textTheme.bodySmall,
            ),
          ],
          section('Paid', s.paid),
          if (s.free.isNotEmpty || upcoming)
            section(
              'Free',
              s.free,
              help: 'First meeting, or let in without paying.',
            ),
          section(
            upcoming ? 'Not paid' : 'Didn\'t come or pay',
            s.notPaid,
            help: upcoming
                ? 'Tap someone when they pay. Anyone marked "first meeting" '
                      'comes free.'
                : null,
          ),
        ],
      ),
    );
  }
}

Future<void> _sendInvite(BuildContext context, WidgetRef ref, Webinar w) {
  final draft = inviteEmail(w);
  return showDialog<void>(
    context: context,
    builder: (_) => _EmailDialog(
      title: 'Email the invite',
      subject: draft.subject,
      body: draft.body,
      recipients: (leaveOut) => [
        for (final m in ref.read(clubMembersProvider))
          if (m.mailingList && (!leaveOut || m.client == null)) m,
      ],
      who: 'on the mailing list',
      optionLabel: 'Leave out members who are clients',
      onSent: (_) => ref
          .read(webinarRecordsProvider.notifier)
          .save(w.copyWith(emailedAt: ref.read(clockProvider)())),
    ),
  );
}

Future<void> _sendLink(BuildContext context, WidgetRef ref, WebinarSummary s) {
  final draft = joinLinkEmail(s.webinar);
  return showDialog<void>(
    context: context,
    builder: (_) => _EmailDialog(
      title: 'Send the join link',
      subject: draft.subject,
      body: draft.body,
      recipients: (again) => again ? s.attending : s.needLink,
      who: 'who paid or come free',
      optionLabel: s.attending.length > s.needLink.length
          ? 'Also those already sent it '
                '(${s.attending.length - s.needLink.length})'
          : null,
      onSent: (sentTo) async {
        final seats = ref.read(clubSeatRecordsProvider.notifier);
        final at = ref.read(clockProvider)();
        for (final m in sentTo) {
          final seat = s.seats[m.id];
          if (seat != null) {
            await seats.decide(s.webinar.id, m.id, seat.withLinkSent(at));
          }
        }
      },
    ),
  );
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: theme.textTheme.titleLarge),
        Text(label, style: theme.textTheme.bodySmall),
      ],
    );
  }
}

class _SeatTile extends StatelessWidget {
  const _SeatTile({
    required this.member,
    required this.seat,
    required this.firstMeeting,
    required this.upcoming,
    required this.onTap,
  });

  final ClubMember member;
  final ClubDecision? seat;
  final bool firstMeeting;
  final bool upcoming;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = member;
    final d = seat;
    final attending = d != null && d.attending;
    final sent = d?.linkSentAt;
    final details = [
      if (m.name.isNotEmpty) m.email,
      if (d != null && d.status == ClubStatus.paid)
        '${money(d.amount ?? clubPrice)}'
            '${d.method == null ? '' : ' by ${d.method!.label}'}',
      if (attending && upcoming)
        sent == null ? 'Link not sent' : 'Link sent ${formatShortDate(sent)}',
      if (!attending && firstMeeting) 'First meeting (free)',
    ];
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        switch (d?.status) {
          ClubStatus.paid => Icons.check_circle,
          ClubStatus.free => Icons.card_giftcard,
          _ => Icons.radio_button_unchecked,
        },
        color: attending
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant,
      ),
      title: Text(m.displayName),
      subtitle: details.isEmpty ? null : Text(details.join(' · ')),
      trailing: attending
          ? null
          : TextButton(onPressed: onTap, child: const Text('Mark paid')),
      onTap: onTap,
    );
  }
}

/// Add or change a webinar: date, time, topic and join link.
class _WebinarDialog extends StatefulWidget {
  const _WebinarDialog({this.existing});
  final Webinar? existing;

  @override
  State<_WebinarDialog> createState() => _WebinarDialogState();
}

class _WebinarDialogState extends State<_WebinarDialog> {
  late DateTime? _day = widget.existing?.start;
  late TimeOfDay? _time = widget.existing == null
      ? const TimeOfDay(hour: 20, minute: 0)
      : TimeOfDay.fromDateTime(widget.existing!.start);
  late final _topic = TextEditingController(text: widget.existing?.topic);
  late final _link = TextEditingController(text: widget.existing?.link);

  @override
  void dispose() {
    _topic.dispose();
    _link.dispose();
    super.dispose();
  }

  /// The last Thursday of [month]'s month: when meetings usually are.
  static DateTime _lastThursday(DateTime month) {
    var d = DateTime(month.year, month.month + 1, 0);
    while (d.weekday != DateTime.thursday) {
      d = d.subtract(const Duration(days: 1));
    }
    return d;
  }

  Future<void> _pickDay() async {
    final now = DateTime.now();
    var suggested = _lastThursday(now);
    if (suggested.isBefore(DateTime(now.year, now.month, now.day))) {
      suggested = _lastThursday(DateTime(now.year, now.month + 1));
    }
    final d = await showDatePicker(
      context: context,
      initialDate: _day ?? suggested,
      firstDate: DateTime(now.year - 3),
      lastDate: DateTime(now.year + 3),
    );
    if (d != null) setState(() => _day = d);
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(
      context: context,
      initialTime: _time ?? const TimeOfDay(hour: 20, minute: 0),
    );
    if (t != null) setState(() => _time = t);
  }

  void _save() {
    final d = _day!;
    final t = _time!;
    final start = DateTime(d.year, d.month, d.day, t.hour, t.minute);
    final old = widget.existing;
    Navigator.of(context).pop(
      old == null
          ? Webinar(
              id: _uuid.v4(),
              start: start,
              topic: _topic.text.trim(),
              link: _link.text.trim(),
            )
          : old.copyWith(
              start: start,
              topic: _topic.text.trim(),
              link: _link.text.trim(),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final day = _day;
    final time = _time;
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Text(widget.existing == null ? 'Add webinar' : 'Edit webinar'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickDay,
                      icon: const Icon(Icons.event),
                      label: Text(day == null ? 'Date' : formatShortDate(day)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickTime,
                      icon: const Icon(Icons.schedule),
                      label: Text(time == null ? 'Time' : time.format(context)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _topic,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Topic (optional)',
                  hintText: 'e.g. Holiday decorations',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _link,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Google Meet link',
                  hintText: 'Sent to those who pay',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: day == null || time == null ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Drafts an email to members (blind copied) in the device's email app,
/// to read over and send.
class _EmailDialog extends ConsumerStatefulWidget {
  const _EmailDialog({
    required this.title,
    required this.subject,
    required this.body,
    required this.recipients,
    required this.who,
    required this.onSent,
    this.optionLabel,
  });

  final String title;
  final String subject;
  final String body;

  /// Who it goes to, with the option ticked or not.
  final List<ClubMember> Function(bool option) recipients;

  /// e.g. "on the mailing list".
  final String who;
  final String? optionLabel;
  final Future<void> Function(List<ClubMember> sentTo) onSent;

  @override
  ConsumerState<_EmailDialog> createState() => _EmailDialogState();
}

class _EmailDialogState extends ConsumerState<_EmailDialog> {
  late final _subject = TextEditingController(text: widget.subject);
  late final _body = TextEditingController(text: widget.body);
  bool _option = false;

  @override
  void dispose() {
    _subject.dispose();
    _body.dispose();
    super.dispose();
  }

  List<ClubMember> get _to => widget.recipients(_option);

  Future<void> _copyEmails() async {
    final to = _to;
    await Clipboard.setData(
      ClipboardData(text: [for (final m in to) m.email].join(', ')),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${to.length} email addresses copied. Paste them into Bcc.',
        ),
      ),
    );
  }

  Future<void> _open() async {
    final to = _to;
    await openClientLink(
      context,
      membersMailto(
        [for (final m in to) m.email],
        subject: _subject.text,
        body: _body.text,
      ),
    );
    await widget.onSent(to);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final to = _to;
    final names = [for (final m in to) m.displayName];
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Text(widget.title),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'To ${to.length} ${to.length == 1 ? 'member' : 'members'} '
                '${widget.who}, blind copied so they don\'t see each '
                'other\'s addresses.',
              ),
              if (names.isNotEmpty && names.length <= 12)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    names.join(', '),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (widget.optionLabel != null)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _option,
                  onChanged: (v) => setState(() => _option = v ?? false),
                  title: Text(widget.optionLabel!),
                ),
              const SizedBox(height: 8),
              TextField(
                controller: _subject,
                decoration: const InputDecoration(labelText: 'Subject'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _body,
                minLines: 6,
                maxLines: 14,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Message',
                  alignLabelWithHint: true,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: to.isEmpty ? null : _copyEmails,
          child: const Text('Copy addresses'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: to.isEmpty ? null : _open,
          icon: const Icon(Icons.open_in_new),
          label: const Text('Open in email'),
        ),
      ],
    );
  }
}
