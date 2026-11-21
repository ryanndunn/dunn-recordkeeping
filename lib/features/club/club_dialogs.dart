import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';

import '../../models/club_member.dart';
import '../../models/money.dart';
import '../../models/webinar.dart';
import '../../services/club.dart';
import '../../state/club_provider.dart';
import '../../state/providers.dart';
import '../../widgets/client_dialog.dart' show looksLikeEmail;
import '../../widgets/payment_fields.dart';
import '../clients/client_status.dart';
import '../payments/payments_screen.dart' show money;

const _uuid = Uuid();

/// Adds a member by hand (someone who didn't fill out the form), or edits
/// one. Returns false if cancelled.
Future<void> showMemberDialog(BuildContext context, {ClubMember? member}) =>
    showDialog<void>(
      context: context,
      builder: (_) => _MemberDialog(member: member),
    );

class _MemberDialog extends ConsumerStatefulWidget {
  const _MemberDialog({this.member});
  final ClubMember? member;

  @override
  ConsumerState<_MemberDialog> createState() => _MemberDialogState();
}

class _MemberDialogState extends ConsumerState<_MemberDialog> {
  late final _name = TextEditingController(text: widget.member?.name);
  late final _email = TextEditingController(text: widget.member?.email);
  late final _phone = TextEditingController(text: widget.member?.phone);
  late final _notes = TextEditingController(text: widget.member?.notes);
  late DateTime? _joined = widget.member?.joined ?? _today();
  late bool _mailingList = widget.member?.mailingList ?? true;
  String? _error;

  DateTime _today() {
    final n = ref.read(clockProvider)();
    return DateTime(n.year, n.month, n.day);
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final email = _email.text.trim().toLowerCase();
    if (!looksLikeEmail(email)) {
      setState(() => _error = 'Enter their email address.');
      return;
    }
    final old = widget.member;
    final taken = ref
        .read(clubMembersProvider)
        .any((m) => m.id != old?.id && m.email.toLowerCase() == email);
    if (taken) {
      setState(() => _error = 'Someone with that email is already a member.');
      return;
    }
    final member = ClubMember(
      id: old?.id ?? _uuid.v4(),
      email: email,
      name: _name.text.trim(),
      phone: _phone.text.trim(),
      joined: _joined,
      mailingList: _mailingList,
      areas: old?.areas ?? '',
      topics: old?.topics ?? '',
      notes: _notes.text.trim(),
      fromForm: old?.fromForm ?? false,
    );
    await ref.read(memberRecordsProvider.notifier).save(member);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _remove() async {
    final m = widget.member!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${m.displayName}?'),
        content: const Text(
          'They\'re taken off the members list and the mailing list. '
          'Payments they made stay in Billing.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(memberRecordsProvider.notifier).remove(m.id);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _pickJoined() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _joined ?? _today(),
      firstDate: DateTime(2015),
      lastDate: _today(),
    );
    if (d != null) setState(() => _joined = d);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = widget.member;
    final joined = _joined;
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Text(m == null ? 'Add member' : m.displayName),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (m != null && m.fromForm)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    'From the interest form.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              if (m != null && m.areas.isNotEmpty)
                _Answer('Areas they struggle with', m.areas),
              if (m != null && m.topics.isNotEmpty)
                _Answer('Topics they\'re interested in', m.topics),
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  labelText: 'Email',
                  errorText: _error,
                ),
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Phone (optional)',
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text('Joined'),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: _pickJoined,
                    icon: const Icon(Icons.event, size: 18),
                    label: Text(
                      joined == null ? 'Pick a date' : formatShortDate(joined),
                    ),
                  ),
                ],
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _mailingList,
                onChanged: (v) => setState(() => _mailingList = v ?? true),
                title: const Text('On the mailing list'),
                subtitle: const Text('Gets the monthly invite'),
              ),
              TextField(
                controller: _notes,
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Notes'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (m != null)
          TextButton(onPressed: _remove, child: const Text('Remove')),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: Text(m == null ? 'Add' : 'Save')),
      ],
    );
  }
}

class _Answer extends StatelessWidget {
  const _Answer(this.question, this.answer);
  final String question;
  final String answer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(question, style: theme.textTheme.labelMedium),
          Text(answer),
        ],
      ),
    );
  }
}

/// Adds existing members from a pasted list (one per line: an email,
/// with their name if known).
Future<void> showImportMembersDialog(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _ImportDialog());

class _ImportDialog extends ConsumerStatefulWidget {
  const _ImportDialog();

  @override
  ConsumerState<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends ConsumerState<_ImportDialog> {
  final _text = TextEditingController();
  bool _mailingList = true;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  ({List<({String name, String email})> add, int already}) get _parsed {
    final existing = {
      for (final m in ref.read(clubMembersProvider)) m.email.toLowerCase(),
    };
    final all = parseMemberList(_text.text);
    return (
      add: [
        for (final p in all)
          if (!existing.contains(p.email)) p,
      ],
      already: all.where((p) => existing.contains(p.email)).length,
    );
  }

  Future<void> _import() async {
    final notifier = ref.read(memberRecordsProvider.notifier);
    final n = ref.read(clockProvider)();
    final added = _parsed.add;
    for (final p in added) {
      await notifier.save(
        ClubMember(
          id: _uuid.v4(),
          email: p.email,
          name: p.name,
          joined: DateTime(n.year, n.month, n.day),
          mailingList: _mailingList,
        ),
      );
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          added.length == 1
              ? 'Added 1 member'
              : 'Added ${added.length} members',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = _parsed;
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: const Text('Add members from a list'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Paste one member per line: their email, with their name if '
                'you have it. Copying the To line of an email, or a column '
                'from a spreadsheet, works too.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _text,
                minLines: 6,
                maxLines: 12,
                decoration: const InputDecoration(
                  hintText:
                      'Jane Smith <jane@example.com>\n'
                      'Sam Lee, sam@example.com\n'
                      'pat@example.com',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _mailingList,
                onChanged: (v) => setState(() => _mailingList = v ?? true),
                title: const Text('Put them on the mailing list'),
              ),
              Text(
                [
                  '${p.add.length} new ${p.add.length == 1 ? 'member' : 'members'}',
                  if (p.already > 0)
                    '${p.already} already ${p.already == 1 ? 'a member' : 'members'}',
                ].join(' · '),
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
          onPressed: p.add.isEmpty ? null : _import,
          child: Text('Add ${p.add.length}'),
        ),
      ],
    );
  }
}

/// Marks what [member] did for [webinar]: paid (how, when, how much),
/// came free, or not paid.
Future<void> showSeatDialog(
  BuildContext context, {
  required Webinar webinar,
  required ClubMember member,
  bool firstMeeting = false,
}) => showDialog<void>(
  context: context,
  builder: (_) =>
      _SeatDialog(webinar: webinar, member: member, firstMeeting: firstMeeting),
);

class _SeatDialog extends ConsumerStatefulWidget {
  const _SeatDialog({
    required this.webinar,
    required this.member,
    required this.firstMeeting,
  });
  final Webinar webinar;
  final ClubMember member;
  final bool firstMeeting;

  @override
  ConsumerState<_SeatDialog> createState() => _SeatDialogState();
}

class _SeatDialogState extends ConsumerState<_SeatDialog> {
  late final ClubDecision? _existing = ref.read(
    clubSeatsProvider,
  )[seatKey(widget.webinar.id, widget.member.id)];
  late ClubStatus _status =
      _existing?.status ??
      (widget.firstMeeting ? ClubStatus.free : ClubStatus.paid);
  late PaymentDetails _paid = (
    method: _existing?.method,
    date: _existing?.paidOn ?? _today(),
    amount: _existing?.amount ?? clubPrice,
  );

  DateTime _today() {
    final n = ref.read(clockProvider)();
    return DateTime(n.year, n.month, n.day);
  }

  bool get _ready =>
      _status != ClubStatus.paid ||
      (_paid.method != null && _paid.amount != null);

  Future<void> _save() async {
    final d = _paid.date;
    final sent = _existing?.linkSentAt;
    await ref
        .read(clubSeatRecordsProvider.notifier)
        .decide(
          widget.webinar.id,
          widget.member.id,
          _status == ClubStatus.paid
              ? ClubDecision(
                  ClubStatus.paid,
                  method: _paid.method,
                  paidOn: DateTime(d.year, d.month, d.day),
                  amount: _paid.amount,
                  linkSentAt: sent,
                )
              : ClubDecision(_status, linkSentAt: sent),
        );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.member;
    final w = widget.webinar;
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Text(m.displayName),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Webinar ${longDay(w.start)}'
                '${widget.firstMeeting ? '\nTheir first meeting, so it\'s '
                          'free.' : ''}',
              ),
              const SizedBox(height: 12),
              SegmentedButton<ClubStatus>(
                segments: [
                  ButtonSegment(
                    value: ClubStatus.paid,
                    label: Text('Paid ${money(clubPrice)}'),
                  ),
                  const ButtonSegment(
                    value: ClubStatus.free,
                    label: Text('Free'),
                  ),
                  const ButtonSegment(
                    value: ClubStatus.unpaid,
                    label: Text('Not paid'),
                  ),
                ],
                selected: {_status},
                showSelectedIcon: false,
                onSelectionChanged: (v) => setState(() => _status = v.first),
              ),
              if (_status == ClubStatus.paid) ...[
                const SizedBox(height: 16),
                PaymentFields(
                  initial: _paid,
                  onChanged: (p) => setState(() => _paid = p),
                ),
              ],
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
          onPressed: _ready ? _save : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
