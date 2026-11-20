import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../models/saved_address.dart';
import '../services/policy_forms.dart';
import 'providers.dart';

final policySignaturesProvider =
    NotifierProvider<PolicySignaturesNotifier, List<PolicySignature>>(
      PolicySignaturesNotifier.new,
    );

/// Responses to the policies forms, as last read from the business
/// records spreadsheet. New ones are matched to a client by email or
/// name; a client whose forms are all in is marked signed.
class PolicySignaturesNotifier extends Notifier<List<PolicySignature>> {
  @override
  List<PolicySignature> build() {
    final raw = ref.read(localStoreProvider).policySignaturesRaw;
    if (raw == null) return const [];
    return [
      for (final s in jsonDecode(raw) as List)
        PolicySignature.fromJson(s as Map<String, dynamic>),
    ];
  }

  /// What the spreadsheet's policies forms hold now.
  Future<void> replace(List<PolicySignature> signatures) async {
    state = signatures;
    await ref
        .read(localStoreProvider)
        .setPolicySignaturesRaw(
          jsonEncode([for (final s in signatures) s.toJson()]),
        );
    await _matchNew();
  }

  /// Signatures not decided yet: matched by email or name if possible.
  Future<void> _matchNew() async {
    final decisions = ref.read(signatureDecisionsProvider.notifier);
    for (final sig in state) {
      if (decisions.of(sig.id) != null) continue;
      final hit = matchSignature(sig, ref.read(addressesProvider));
      if (hit == null) continue;
      await assign(
        sig,
        hit.client.id,
        contactId: hit.contactId,
        automatic: true,
      );
    }
  }

  /// [sig] was signed by [clientId] themself, or by their contact
  /// [contactId]. With [newContact], the signer is added to the client's
  /// contacts first (e.g. the person paying). Once the client's forms are
  /// all in, their policies are signed, at the rate the form agreed to.
  Future<void> assign(
    PolicySignature sig,
    String clientId, {
    String? contactId,
    bool newContact = false,
    bool automatic = false,
  }) async {
    final clients = ref.read(addressesProvider.notifier);
    var client = ref
        .read(addressesProvider)
        .where((c) => c.id == clientId)
        .firstOrNull;
    if (client != null && newContact) {
      final contact = ClientContact(
        id: const Uuid().v4(),
        name: sig.signedName,
        email: sig.email,
        label: sig.includesPayment ? 'Pays' : '',
        signsPolicies: true,
      );
      contactId = contact.id;
      client = client.copyWith(contacts: [...client.contacts, contact]);
      await clients.replace(client);
    }
    await ref
        .read(signatureDecisionsProvider.notifier)
        .set(
          sig.id,
          SignatureDecision(
            clientId: clientId,
            contactId: contactId,
            automatic: automatic,
          ),
        );
    await recheck(clientId);
  }

  /// Marks [clientId] signed if all their forms are in and they aren't
  /// already (after a signature, or after changing who needs to sign).
  /// Never marks anyone not signed.
  Future<void> recheck(String clientId) async {
    final client = ref
        .read(addressesProvider)
        .where((c) => c.id == clientId)
        .firstOrNull;
    if (client == null || client.policiesSignedOn != null) return;
    final progress = policyProgressOf(
      client,
      state,
      ref.read(signatureDecisionsProvider.notifier).decisions,
    );
    if (!progress.complete) return;
    await ref
        .read(addressesProvider.notifier)
        .replace(
          signedWith(client, progress.completedAt!, rate: progress.rate),
        );
  }

  /// [sig] isn't any client's.
  Future<void> ignore(PolicySignature sig) => ref
      .read(signatureDecisionsProvider.notifier)
      .set(sig.id, SignatureDecision.ignored);
}

typedef SignatureDecisions =
    Map<String, ({SignatureDecision decision, DateTime at})>;

final signatureDecisionsProvider =
    NotifierProvider<SignatureDecisionsNotifier, SignatureDecisions>(
      SignatureDecisionsNotifier.new,
    );

/// Whose each policy signature is (or that it's nobody's), synced between
/// devices so each response is only handled once.
class SignatureDecisionsNotifier extends Notifier<SignatureDecisions> {
  @override
  SignatureDecisions build() {
    final raw = ref.read(localStoreProvider).signatureDecisionsRaw;
    if (raw == null) return {};
    return {
      for (final e in (jsonDecode(raw) as Map<String, dynamic>).entries)
        e.key: (
          decision: SignatureDecision.fromJson(
            (e.value as Map<String, dynamic>)['decision']
                as Map<String, dynamic>,
          ),
          at: DateTime.parse((e.value as Map<String, dynamic>)['at'] as String),
        ),
    };
  }

  SignatureDecision? of(String id) => state[id]?.decision;

  Map<String, SignatureDecision> get decisions => {
    for (final e in state.entries) e.key: e.value.decision,
  };

  Future<void> set(String id, SignatureDecision decision) async {
    await _save({
      ...state,
      id: (decision: decision, at: ref.read(clockProvider)().toUtc()),
    });
    ref.read(syncProvider.notifier).localChanged();
  }

  /// Merged with the other device's (no re-sync).
  Future<void> replaceFromSync(SignatureDecisions merged) => _save(merged);

  Future<void> _save(SignatureDecisions next) async {
    state = next;
    await ref
        .read(localStoreProvider)
        .setSignatureDecisionsRaw(
          jsonEncode({
            for (final e in next.entries)
              e.key: {
                'decision': e.value.decision.toJson(),
                'at': e.value.at.toIso8601String(),
              },
          }),
        );
  }
}

/// Policy signatures still waiting for you to pick the client.
final unmatchedSignaturesProvider = Provider<List<PolicySignature>>((ref) {
  final decisions = ref.watch(signatureDecisionsProvider);
  return [
    for (final s in ref.watch(policySignaturesProvider))
      if (!decisions.containsKey(s.id)) s,
  ];
});

/// Where [clientId]'s policy forms stand.
final policyProgressProvider = Provider.family<PolicyProgress, String>((
  ref,
  clientId,
) {
  final client = ref
      .watch(addressesProvider)
      .where((c) => c.id == clientId)
      .firstOrNull;
  if (client == null) return const PolicyProgress([]);
  final decisions = ref.watch(signatureDecisionsProvider);
  return policyProgressOf(client, ref.watch(policySignaturesProvider), {
    for (final e in decisions.entries) e.key: e.value.decision,
  });
});
