import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/billing.dart';
import '../services/client_jobs.dart';
import '../services/people_match.dart';
import '../services/stripe.dart';
import 'money_provider.dart';
import 'providers.dart';

/// Talks to Stripe with a key (overridden in tests).
final stripeSourceFactoryProvider = Provider<StripeSource Function(String)>(
  (ref) =>
      (key) => StripeApi(key),
);

// -------------------------------------------------------------------- key

final stripeKeyProvider = NotifierProvider<StripeKeyNotifier, String?>(
  StripeKeyNotifier.new,
);

/// The Stripe restricted key, kept in the keychain / keystore and synced
/// to the other device (newest entry wins).
class StripeKeyNotifier extends Notifier<String?> {
  @override
  String? build() => ref.read(secretStoreProvider).stripeKey;

  /// When it was last entered or removed, on either device.
  DateTime? get changedAt => ref.read(localStoreProvider).stripeKeyChangedAt;

  /// Entered (or removed) on this device: saved and synced.
  Future<void> set(String? key) async {
    await _store(key, ref.read(clockProvider)().toUtc());
    ref.read(syncProvider.notifier).localChanged();
  }

  /// Arrived from the other device (no re-sync).
  Future<void> setFromSync(String? key, DateTime at) => _store(key, at);

  /// Forgotten on this device only (switching Google account).
  Future<void> forget() => _store(null, null);

  Future<void> _store(String? key, DateTime? at) async {
    final secrets = ref.read(secretStoreProvider);
    await secrets.setStripeKey(key);
    await ref.read(localStoreProvider).setStripeKeyChangedAt(at);
    state = secrets.stripeKey;
  }
}

// --------------------------------------------------------------- payments

class StripeState {
  const StripeState({
    this.payments = const [],
    this.checkedAt,
    this.checking = false,
    this.error,
  });

  /// Paid checkouts since the start of last year, newest first.
  final List<StripePayment> payments;

  /// When Stripe was last read.
  final DateTime? checkedAt;
  final bool checking;
  final String? error;

  StripeState copyWith({
    List<StripePayment>? payments,
    DateTime? checkedAt,
    bool? checking,
    String? error,
    bool clearError = false,
  }) => StripeState(
    payments: payments ?? this.payments,
    checkedAt: checkedAt ?? this.checkedAt,
    checking: checking ?? this.checking,
    error: clearError ? null : (error ?? this.error),
  );
}

final stripeProvider = NotifierProvider<StripeNotifier, StripeState>(
  StripeNotifier.new,
);

/// Payments from Stripe, read on each sync (at most every
/// [refreshEvery]) and matched to clients' sessions.
class StripeNotifier extends Notifier<StripeState> {
  static const refreshEvery = Duration(minutes: 10);

  @override
  StripeState build() {
    final raw = ref.read(localStoreProvider).stripePaymentsRaw;
    if (raw == null) return const StripeState();
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return StripeState(
      payments: [
        for (final p in json['payments'] as List)
          StripePayment.fromJson(p as Map<String, dynamic>),
      ],
      checkedAt: DateTime.tryParse(json['checkedAt'] as String? ?? ''),
    );
  }

  /// From January 1 of last year (this year's and last year's taxes).
  DateTime _since() => DateTime(ref.read(clockProvider)().year - 1);

  /// Tries [key]; if Stripe accepts it, keeps it (and syncs it) and loads
  /// the payments. Returns what went wrong, or null.
  Future<String?> connect(String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) return 'Paste the key first.';
    if (trimmed.startsWith('sk_')) {
      return 'That\'s a secret key, which can do anything in your Stripe '
          'account. Make a restricted key instead (it starts with rk_).';
    }
    state = state.copyWith(checking: true, clearError: true);
    try {
      final payments = await ref
          .read(stripeSourceFactoryProvider)(trimmed)
          .paymentsSince(_since());
      await ref.read(stripeKeyProvider.notifier).set(trimmed);
      await _keep(payments);
      return null;
    } on StripeException catch (e) {
      state = state.copyWith(checking: false);
      return e.message;
    }
  }

  /// Stops reading Stripe here and on the other device. Matches already
  /// made stay.
  Future<void> disconnect() async {
    await ref.read(stripeKeyProvider.notifier).set(null);
    await forgetPayments();
  }

  /// Clears what was read (the key is gone).
  Future<void> forgetPayments() async {
    state = const StripeState();
    await ref.read(localStoreProvider).setStripePaymentsRaw(null);
  }

  /// Reads new payments (during each sync, or now with [force]).
  Future<void> refresh({bool force = false}) async {
    final key = ref.read(stripeKeyProvider);
    if (key == null) {
      if (state.payments.isNotEmpty) await forgetPayments();
      return;
    }
    final last = state.checkedAt;
    final now = ref.read(clockProvider)();
    if (state.checking) return;
    if (!force && last != null && now.difference(last) < refreshEvery) {
      return;
    }
    state = state.copyWith(checking: true, clearError: true);
    try {
      final payments = await ref
          .read(stripeSourceFactoryProvider)(key)
          .paymentsSince(_since());
      await _keep(payments);
    } on StripeException catch (e) {
      state = state.copyWith(
        checking: false,
        error: e.badKey
            ? 'Stripe didn\'t accept the key: ${e.message}'
            : e.message,
      );
    }
  }

  Future<void> _keep(List<StripePayment> payments) async {
    final at = ref.read(clockProvider)();
    state = StripeState(payments: payments, checkedAt: at);
    await ref
        .read(localStoreProvider)
        .setStripePaymentsRaw(
          jsonEncode({
            'checkedAt': at.toIso8601String(),
            'payments': [for (final p in payments) p.toJson()],
          }),
        );
    await _matchNew();
  }

  /// [clientId]'s sessions, as on their page.
  List<ClientJobEntry> sessionsOf(String clientId) {
    final client = ref
        .read(addressesProvider)
        .where((c) => c.id == clientId)
        .firstOrNull;
    if (client == null) return const [];
    return clientJobs(
      client: client,
      jobs: ref.read(allJobSummariesProvider),
      trips: ref.read(tripsProvider),
      now: ref.read(clockProvider)(),
    );
  }

  /// Payments not decided yet: matched to a session when the payer is a
  /// client (or their contact) and one session clearly fits.
  Future<void> _matchNew() async {
    final decisions = ref.read(stripeDecisionsProvider);
    for (final p in state.payments) {
      if (decisions.containsKey(p.id) || p.fullyRefunded) continue;
      final clients = ref.read(addressesProvider);
      // Already on a session (e.g. matched before switching accounts).
      final owner = clients
          .where((c) => c.billing.values.any((b) => b.stripeId == p.id))
          .firstOrNull;
      if (owner != null) {
        final key = owner.billing.entries
            .firstWhere((e) => e.value.stripeId == p.id)
            .key;
        await _decide(
          p.id,
          StripeDecision(clientId: owner.id, sessionKey: key, automatic: true),
        );
        continue;
      }
      // Paid through a link the app made: exactly its session.
      final fromLink = linkedSession(p, clients, (c) => sessionsOf(c.id));
      if (fromLink != null) {
        await link(p, fromLink.client.id, fromLink.session, automatic: true);
        continue;
      }
      final who = matchPerson(email: p.email, name: p.name, clients: clients);
      if (who == null) continue;
      final session = pickSession(p, who.client, sessionsOf(who.client.id));
      if (session == null) continue;
      await link(p, who.client.id, session, automatic: true);
    }
  }

  /// [payment] paid for [session] of [clientId]'s: that session is marked
  /// paid (with Stripe's amount, date and method). A session it paid
  /// before goes back to "Need to bill".
  Future<void> link(
    StripePayment payment,
    String clientId,
    ClientJobEntry session, {
    bool automatic = false,
  }) async {
    await _unlink(payment.id);
    final client = ref
        .read(addressesProvider)
        .where((c) => c.id == clientId)
        .firstOrNull;
    if (client == null) return;
    await ref
        .read(addressesProvider.notifier)
        .replace(paidByStripe(client, session, payment));
    await _decide(
      payment.id,
      StripeDecision(
        clientId: clientId,
        sessionKey: session.billingKeys.first,
        automatic: automatic,
      ),
    );
  }

  /// Makes a one-time payment link for [amount] dollars for [session] of
  /// [clientId]'s, and saves it on the session (now "Billed"). Returns
  /// what went wrong, or null.
  Future<String?> createLink(
    String clientId,
    ClientJobEntry session, {
    required double amount,
    required String name,
  }) async {
    final key = ref.read(stripeKeyProvider);
    if (key == null) return 'Connect Stripe in Settings first.';
    if (amount < 0.5) return 'Stripe needs at least \$0.50.';
    final ({String id, String url}) made;
    try {
      made = await ref
          .read(stripeSourceFactoryProvider)(key)
          .createPaymentLink(
            amount: amount,
            name: name,
            clientId: clientId,
            sessionKey: session.billingKeys.first,
          );
    } on StripeException catch (e) {
      return e.badKey
          ? '${e.message}\n\nThe Stripe key needs Write access to Payment '
                'Links (and Products and Prices) to make links. In Stripe, '
                'edit the restricted key (or make a new one), then use '
                'Settings → Stripe → Change key.'
          : e.message;
    }
    final client = ref
        .read(addressesProvider)
        .where((c) => c.id == clientId)
        .firstOrNull;
    if (client == null) return null;
    final now = ref.read(clockProvider)();
    await ref
        .read(addressesProvider.notifier)
        .replace(
          withBilling(
            client,
            session,
            SessionBilling(
              status: BillingStatus.billed,
              link: SessionPaymentLink(
                id: made.id,
                url: made.url,
                amount: amount,
                createdOn: DateTime(now.year, now.month, now.day),
              ),
            ),
          ),
        );
    return null;
  }

  /// Turns off [session]'s payment link so it can't be paid, and removes
  /// it from the session (back to "Need to bill"). Returns what went
  /// wrong, or null.
  Future<String?> turnOffLink(String clientId, ClientJobEntry session) async {
    final client = ref
        .read(addressesProvider)
        .where((c) => c.id == clientId)
        .firstOrNull;
    if (client == null) return null;
    final billing = billingFor(client, session);
    final link = billing.link;
    if (link == null) return null;
    final key = ref.read(stripeKeyProvider);
    if (key == null) return 'Connect Stripe in Settings first.';
    try {
      await ref
          .read(stripeSourceFactoryProvider)(key)
          .deactivatePaymentLink(link.id);
    } on StripeException catch (e) {
      return e.message;
    }
    await ref
        .read(addressesProvider.notifier)
        .replace(
          withBilling(
            client,
            session,
            billing.status == BillingStatus.billed
                ? SessionBilling.unbilled
                : billing.withoutLink(),
          ),
        );
    return null;
  }

  /// [payment] isn't for a session (other income, from [clientId] if
  /// given).
  Future<void> notForSession(StripePayment payment, {String? clientId}) async {
    await _unlink(payment.id);
    await _decide(payment.id, StripeDecision(clientId: clientId));
  }

  Future<void> _unlink(String paymentId) async {
    final clients = ref.read(addressesProvider.notifier);
    for (final c in ref.read(addressesProvider)) {
      if (c.billing.values.any((b) => b.stripeId == paymentId)) {
        await clients.replace(withoutStripe(c, paymentId));
      }
    }
  }

  Future<void> _decide(String paymentId, StripeDecision d) => ref
      .read(stripeDecisionRecordsProvider.notifier)
      .put(paymentId, d.toJson());
}

/// Stripe payments still waiting for you to say what they were for.
final unmatchedStripeProvider = Provider<List<StripePayment>>((ref) {
  final decisions = ref.watch(stripeDecisionsProvider);
  return [
    for (final p in ref.watch(stripeProvider).payments)
      if (!p.fullyRefunded && !decisions.containsKey(p.id)) p,
  ];
});
