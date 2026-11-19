import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../services/google_account.dart';
import '../services/policy_docs.dart';
import 'providers.dart';

/// Finds signed docs with a Drive client (overridden in tests).
final signedDocSourceFactoryProvider =
    Provider<SignedDocSource Function(http.Client)>(
      (ref) =>
          (client) => DriveSignedDocSource(client),
    );

/// File names of signed policy docs contain this, unless changed in
/// Settings ("Polic" finds "Policy" and "Policies").
const defaultPolicyDocName = 'Polic';

class SignedDocsState {
  const SignedDocsState({
    this.docs = const [],
    this.connected,
    this.checking = false,
    this.error,
  });

  /// Signed policy PDFs found in Drive, newest first.
  final List<SignedDoc> docs;

  /// Whether this device may read Drive file names (null until checked).
  final bool? connected;
  final bool checking;
  final String? error;

  SignedDocsState copyWith({
    List<SignedDoc>? docs,
    bool? connected,
    bool? checking,
    String? error,
    bool clearError = false,
  }) => SignedDocsState(
    docs: docs ?? this.docs,
    connected: connected ?? this.connected,
    checking: checking ?? this.checking,
    error: clearError ? null : (error ?? this.error),
  );
}

final signedDocsProvider =
    NotifierProvider<SignedDocsNotifier, SignedDocsState>(
      SignedDocsNotifier.new,
    );

/// Signed policy docs in Drive. Each sync looks for new ones and marks
/// the client whose name is in the file name as signed; the rest wait for
/// you to pick the client.
class SignedDocsNotifier extends Notifier<SignedDocsState> {
  @override
  SignedDocsState build() {
    final raw = ref.read(localStoreProvider).signedDocsRaw;
    if (raw == null) return const SignedDocsState();
    return SignedDocsState(
      docs: [
        for (final d in jsonDecode(raw) as List)
          SignedDoc.fromJson(d as Map<String, dynamic>),
      ],
    );
  }

  GoogleAccountService? get _account => ref.read(googleAccountServiceProvider);

  /// Asks Google for read-only access to Drive file names, then checks.
  Future<void> connect() async {
    final account = _account;
    if (account == null) return;
    try {
      final client = await account.grantAccess(policyDocsScope);
      await _check(client);
    } on GoogleAccountException catch (e) {
      if (!e.cancelled) state = state.copyWith(error: e.message);
    }
  }

  /// Looks for new signed docs (during each sync, and from Settings).
  Future<void> check() async {
    final account = _account;
    if (account == null) return;
    final client = await account.access(policyDocsScope);
    if (client == null) {
      state = state.copyWith(connected: false);
      return;
    }
    await _check(client);
  }

  Future<void> _check(http.Client client) async {
    state = state.copyWith(connected: true, checking: true, clearError: true);
    try {
      final name =
          ref.read(settingsProvider).policyDocName ?? defaultPolicyDocName;
      final docs = await ref
          .read(signedDocSourceFactoryProvider)(client)
          .find(name);
      state = state.copyWith(docs: docs, checking: false);
      await ref
          .read(localStoreProvider)
          .setSignedDocsRaw(jsonEncode([for (final d in docs) d.toJson()]));
      await _matchNew();
    } catch (e) {
      state = state.copyWith(
        checking: false,
        error: 'Couldn\'t check Drive for signed policy docs: $e',
      );
    } finally {
      client.close();
    }
  }

  /// Docs not decided yet: matched by name if possible.
  Future<void> _matchNew() async {
    final decisions = ref.read(signedDocDecisionsProvider.notifier);
    for (final doc in state.docs) {
      if (decisions.of(doc.id) != null) continue;
      final client = matchSignedDoc(doc, ref.read(addressesProvider));
      if (client == null) continue;
      await assign(doc, client.id, automatic: true);
    }
  }

  /// [doc] belongs to [clientId]: their policy doc is signed (if it
  /// wasn't already).
  Future<void> assign(
    SignedDoc doc,
    String clientId, {
    bool automatic = false,
  }) async {
    final client = ref
        .read(addressesProvider)
        .where((c) => c.id == clientId)
        .firstOrNull;
    if (client != null && client.policiesSignedOn == null) {
      await ref
          .read(addressesProvider.notifier)
          .replace(signedWith(client, doc));
    }
    await ref
        .read(signedDocDecisionsProvider.notifier)
        .set(
          doc.id,
          SignedDocDecision(clientId: clientId, automatic: automatic),
        );
  }

  /// [doc] isn't a client's policy doc.
  Future<void> ignore(SignedDoc doc) => ref
      .read(signedDocDecisionsProvider.notifier)
      .set(doc.id, SignedDocDecision.ignored);
}

typedef SignedDocDecisions =
    Map<String, ({SignedDocDecision decision, DateTime at})>;

final signedDocDecisionsProvider =
    NotifierProvider<SignedDocDecisionsNotifier, SignedDocDecisions>(
      SignedDocDecisionsNotifier.new,
    );

/// Which client each signed doc belongs to (or that it's not a policy
/// doc), synced between devices so a doc is only handled once.
class SignedDocDecisionsNotifier extends Notifier<SignedDocDecisions> {
  @override
  SignedDocDecisions build() {
    final raw = ref.read(localStoreProvider).signedDocDecisionsRaw;
    if (raw == null) return {};
    return {
      for (final e in (jsonDecode(raw) as Map<String, dynamic>).entries)
        e.key: (
          decision: SignedDocDecision.fromJson(
            (e.value as Map<String, dynamic>)['decision']
                as Map<String, dynamic>,
          ),
          at: DateTime.parse((e.value as Map<String, dynamic>)['at'] as String),
        ),
    };
  }

  SignedDocDecision? of(String docId) => state[docId]?.decision;

  Future<void> set(String docId, SignedDocDecision decision) async {
    await _save({
      ...state,
      docId: (decision: decision, at: ref.read(clockProvider)().toUtc()),
    });
    ref.read(syncProvider.notifier).localChanged();
  }

  /// Merged with the other device's (no re-sync).
  Future<void> replaceFromSync(SignedDocDecisions merged) => _save(merged);

  Future<void> _save(SignedDocDecisions next) async {
    state = next;
    await ref
        .read(localStoreProvider)
        .setSignedDocDecisionsRaw(
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

/// Signed docs still waiting for you to pick the client.
final unmatchedSignedDocsProvider = Provider<List<SignedDoc>>((ref) {
  final decisions = ref.watch(signedDocDecisionsProvider);
  return [
    for (final d in ref.watch(signedDocsProvider).docs)
      if (!decisions.containsKey(d.id)) d,
  ];
});

/// The signed doc matched to [clientId], if any (newest).
SignedDoc? signedDocFor(
  String clientId,
  List<SignedDoc> docs,
  SignedDocDecisions decisions,
) {
  for (final d in docs) {
    if (decisions[d.id]?.decision.clientId == clientId) return d;
  }
  return null;
}
