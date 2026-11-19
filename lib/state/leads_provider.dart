import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/lead.dart';
import 'money_provider.dart';
import 'providers.dart';

/// The leads from the website's contact form, as last read from the
/// spreadsheet.
class LeadsInfo {
  const LeadsInfo({this.leads = const [], this.linked, this.read = false});

  final List<Lead> leads;

  /// Whether the form is linked to the spreadsheet (null until read).
  final bool? linked;

  /// True once the spreadsheet has been read on this device.
  final bool read;
}

final leadsProvider = NotifierProvider<LeadsNotifier, LeadsInfo>(
  LeadsNotifier.new,
);

class LeadsNotifier extends Notifier<LeadsInfo> {
  @override
  LeadsInfo build() {
    final raw = ref.read(localStoreProvider).leadsRaw;
    if (raw == null) return const LeadsInfo();
    final list = jsonDecode(raw) as List?;
    if (list == null) return const LeadsInfo(linked: false, read: true);
    return LeadsInfo(
      leads: [for (final l in list) Lead.fromJson(l as Map<String, dynamic>)],
      linked: true,
      read: true,
    );
  }

  /// What the spreadsheet holds now: [leads], or null if no form is
  /// linked to it.
  Future<void> replace(List<Lead>? leads) async {
    state = leads == null
        ? const LeadsInfo(linked: false, read: true)
        : LeadsInfo(leads: leads, linked: true, read: true);
    await ref
        .read(localStoreProvider)
        .setLeadsRaw(
          jsonEncode(
            leads == null ? null : [for (final l in leads) l.toJson()],
          ),
        );
  }
}

typedef LeadStates = Map<String, ({LeadState state, DateTime at})>;

final leadStatesProvider = NotifierProvider<LeadStatesNotifier, LeadStates>(
  LeadStatesNotifier.new,
);

/// What's been done with each lead (synced between devices).
class LeadStatesNotifier extends Notifier<LeadStates> {
  @override
  LeadStates build() {
    final raw = ref.read(localStoreProvider).leadStatesRaw;
    if (raw == null) return {};
    return {
      for (final e in (jsonDecode(raw) as Map<String, dynamic>).entries)
        e.key: (
          state: LeadState.fromJson(
            (e.value as Map<String, dynamic>)['state'] as Map<String, dynamic>,
          ),
          at: DateTime.parse((e.value as Map<String, dynamic>)['at'] as String),
        ),
    };
  }

  LeadState of(String leadId) => state[leadId]?.state ?? LeadState.open;

  Future<void> set(String leadId, LeadState next) async {
    await _save({
      ...state,
      leadId: (state: next, at: ref.read(clockProvider)().toUtc()),
    });
    ref.read(syncProvider.notifier).localChanged();
  }

  /// Merged with the other device's (no re-sync).
  Future<void> replaceFromSync(LeadStates merged) => _save(merged);

  Future<void> _save(LeadStates next) async {
    state = next;
    await ref
        .read(localStoreProvider)
        .setLeadStatesRaw(
          jsonEncode({
            for (final e in next.entries)
              e.key: {
                'state': e.value.state.toJson(),
                'at': e.value.at.toIso8601String(),
              },
          }),
        );
  }
}

/// Leads nothing has been done with yet (website form and Dunn Club).
final openLeadsProvider = Provider<List<Lead>>((ref) {
  final states = ref.watch(leadStatesProvider);
  return [
    for (final l in ref.watch(allLeadsProvider))
      if ((states[l.id]?.state.status ?? LeadStatus.open) == LeadStatus.open) l,
  ];
});
