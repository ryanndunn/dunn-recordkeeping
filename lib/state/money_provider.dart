import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/lead.dart';
import '../models/money.dart';
import '../services/client_jobs.dart';
import '../services/ledger.dart';
import '../services/local_store.dart';
import '../services/settings_sync.dart';
import '../services/stripe.dart';
import 'leads_provider.dart';
import 'stripe_provider.dart';
import 'providers.dart';

/// Records by ID, each with when it last changed. A null value is a
/// deletion, kept so it reaches the other device.
typedef Records = Map<String, ({Map<String, dynamic>? value, DateTime at})>;

/// Records under [prefix] in [doc].
Records recordsFromDoc(SyncDoc doc, String prefix) => {
  for (final e in doc.entries)
    if (e.key.startsWith(prefix))
      e.key.substring(prefix.length): (
        value: e.value.value as Map<String, dynamic>?,
        at: e.value.at,
      ),
};

/// A list of records that syncs between devices entry by entry (newest
/// change wins), like clients.
abstract class SyncedRecordsNotifier extends Notifier<Records> {
  /// Key prefix in the sync file, e.g. "payment:".
  String get prefix;

  /// Where they're kept on this device.
  String get storeKey;

  @override
  Records build() {
    final raw = ref.read(localStoreProvider).recordsRaw(storeKey);
    if (raw == null) return {};
    return {
      for (final e in (jsonDecode(raw) as Map<String, dynamic>).entries)
        e.key: (
          value:
              (e.value as Map<String, dynamic>)['v'] as Map<String, dynamic>?,
          at: DateTime.parse((e.value as Map<String, dynamic>)['at'] as String),
        ),
    };
  }

  Future<void> put(String id, Map<String, dynamic> value) => _change(id, value);

  Future<void> remove(String id) => _change(id, null);

  Future<void> _change(String id, Map<String, dynamic>? value) async {
    await _save({
      ...state,
      id: (value: value, at: ref.read(clockProvider)().toUtc()),
    });
    ref.read(syncProvider.notifier).localChanged();
  }

  /// This device's records, for the sync file.
  SyncDoc toDoc() => {
    for (final e in state.entries)
      '$prefix${e.key}': SyncField(e.value.value, e.value.at.toUtc()),
  };

  /// Merged with the other device's (no re-sync).
  Future<void> mergeFromSync(SyncDoc merged) => _save(
    recordsFromDoc(
      mergeDocs(toDoc(), entriesWithPrefix(merged, prefix)),
      prefix,
    ),
  );

  Future<void> _save(Records next) async {
    state = next;
    await ref
        .read(localStoreProvider)
        .setRecordsRaw(
          storeKey,
          jsonEncode({
            for (final e in next.entries)
              e.key: {'v': e.value.value, 'at': e.value.at.toIso8601String()},
          }),
        );
  }
}

class ManualPaymentsNotifier extends SyncedRecordsNotifier {
  @override
  String get prefix => 'payment:';
  @override
  String get storeKey => LocalStore.manualPaymentsKey;

  Future<void> save(ManualPayment p) => put(p.id, p.toJson());
}

class ExpensesNotifier extends SyncedRecordsNotifier {
  @override
  String get prefix => 'expense:';
  @override
  String get storeKey => LocalStore.expensesKey;

  Future<void> save(Expense e) => put(e.id, e.toJson());
}

class ClubDecisionsNotifier extends SyncedRecordsNotifier {
  @override
  String get prefix => 'clubreg:';
  @override
  String get storeKey => LocalStore.clubDecisionsKey;

  Future<void> decide(String registrationId, ClubDecision d) =>
      put(registrationId, d.toJson());
}

final manualPaymentRecordsProvider =
    NotifierProvider<ManualPaymentsNotifier, Records>(
      ManualPaymentsNotifier.new,
    );
final expenseRecordsProvider = NotifierProvider<ExpensesNotifier, Records>(
  ExpensesNotifier.new,
);
final clubDecisionRecordsProvider =
    NotifierProvider<ClubDecisionsNotifier, Records>(ClubDecisionsNotifier.new);

/// Everything above, for syncing.
/// What each Stripe payment was for.
class StripeDecisionsNotifier extends SyncedRecordsNotifier {
  @override
  String get prefix => 'stripe:';
  @override
  String get storeKey => LocalStore.stripeDecisionsKey;
}

final stripeDecisionRecordsProvider =
    NotifierProvider<StripeDecisionsNotifier, Records>(
      StripeDecisionsNotifier.new,
    );

final stripeDecisionsProvider = Provider<Map<String, StripeDecision>>(
  (ref) => {
    for (final e in ref.watch(stripeDecisionRecordsProvider).entries)
      if (e.value.value != null) e.key: StripeDecision.fromJson(e.value.value!),
  },
);

final syncedRecordProviders = [
  manualPaymentRecordsProvider,
  expenseRecordsProvider,
  clubDecisionRecordsProvider,
  stripeDecisionRecordsProvider,
];

final manualPaymentsProvider = Provider<List<ManualPayment>>(
  (ref) => [
    for (final e in ref.watch(manualPaymentRecordsProvider).entries)
      if (e.value.value case final Map<String, dynamic> v)
        ManualPayment.fromJson(e.key, v),
  ],
);

/// Expenses, newest first.
final expensesProvider = Provider<List<Expense>>(
  (ref) => [
    for (final e in ref.watch(expenseRecordsProvider).entries)
      if (e.value.value case final Map<String, dynamic> v)
        Expense.fromJson(e.key, v),
  ]..sort((a, b) => b.date.compareTo(a.date)),
);

final clubDecisionsProvider = Provider<Map<String, ClubDecision>>(
  (ref) => {
    for (final e in ref.watch(clubDecisionRecordsProvider).entries)
      if (e.value.value case final Map<String, dynamic> v)
        e.key: ClubDecision.fromJson(v),
  },
);

// ------------------------------------------------------ Dunn Club sign-ups

final clubRegistrationsProvider =
    NotifierProvider<ClubRegistrationsNotifier, List<ClubRegistration>>(
      ClubRegistrationsNotifier.new,
    );

/// Sign-ups from the Dunn Club form, as last read from the spreadsheet.
class ClubRegistrationsNotifier extends Notifier<List<ClubRegistration>> {
  static const _key = LocalStore.clubRegistrationsKey;

  @override
  List<ClubRegistration> build() {
    final raw = ref.read(localStoreProvider).recordsRaw(_key);
    if (raw == null) return const [];
    return [
      for (final r in jsonDecode(raw) as List)
        ClubRegistration.fromJson(r as Map<String, dynamic>),
    ];
  }

  Future<void> replace(List<ClubRegistration> regs) async {
    state = regs;
    await ref
        .read(localStoreProvider)
        .setRecordsRaw(_key, jsonEncode([for (final r in regs) r.toJson()]));
  }
}

/// Sign-ups not yet marked paid or not paid (after someone's free first).
final clubToConfirmProvider = Provider<List<ClubRegistration>>((ref) {
  final regs = ref.watch(clubRegistrationsProvider);
  final decisions = ref.watch(clubDecisionsProvider);
  return [
    for (final r in regs)
      if (clubStatusOf(r, regs, decisions) == ClubStatus.toConfirm) r,
  ];
});

// ---------------------------------------------------------------- ledger

/// Every payment received, newest first.
final ledgerProvider = Provider<List<LedgerPayment>>(
  (ref) => allPayments(
    clients: ref.watch(addressesProvider),
    manual: ref.watch(manualPaymentsProvider),
    registrations: ref.watch(clubRegistrationsProvider),
    clubDecisions: ref.watch(clubDecisionsProvider),
    stripe: ref.watch(stripeProvider).payments,
    stripeDecisions: ref.watch(stripeDecisionsProvider),
  ),
);

/// Every client's sessions with their billing (to bill, billed, paid).
final allSessionsProvider = Provider<List<SessionRow>>(
  (ref) => allSessions(
    clients: ref.watch(addressesProvider),
    jobs: ref.watch(allJobSummariesProvider),
    trips: ref.watch(tripsProvider),
    now: ref.read(clockProvider)(),
  ),
);

/// Every business expense: entered by hand, plus Stripe's fees by month.
final allExpensesProvider = Provider<List<Expense>>(
  (ref) => [
    ...ref.watch(expensesProvider),
    ...stripeFeeExpenses(ref.watch(stripeProvider).payments),
  ],
);

/// Leads from the website form and from Dunn Club sign-ups.
final allLeadsProvider = Provider<List<Lead>>((ref) {
  final leads = [
    ...ref.watch(leadsProvider).leads,
    ...clubLeads(
      ref.watch(clubRegistrationsProvider),
      ref.watch(addressesProvider),
    ),
  ];
  leads.sort((a, b) {
    final ta = a.submittedAt;
    final tb = b.submittedAt;
    if (ta == null || tb == null) return 0;
    return tb.compareTo(ta);
  });
  return leads;
});
