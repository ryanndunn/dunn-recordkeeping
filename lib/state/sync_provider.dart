import 'dart:convert';
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/oauth_config.dart';
import '../models/lead.dart';
import '../services/google_account.dart';
import '../services/google_account_android.dart';
import '../services/google_account_desktop.dart';
import '../services/mileage_sheet.dart';
import '../services/jobs.dart' show jobMiles, summarizeJob;
import '../services/ledger.dart';
import '../services/local_store.dart';
import '../services/policy_forms.dart';
import '../services/settings_sync.dart';
import 'calendar_provider.dart';
import 'leads_provider.dart';
import 'money_provider.dart';
import 'policy_forms_provider.dart';
import 'stripe_provider.dart';
import 'providers.dart';

/// Google sign-in for this platform, or null when this build has no
/// client IDs (or the platform isn't Android/macOS, e.g. web preview).
final googleAccountServiceProvider = Provider<GoogleAccountService?>((ref) {
  if (kIsWeb) return null;
  if (Platform.isAndroid && OAuthConfig.androidConfigured) {
    return AndroidGoogleAccountService(
      serverClientId: OAuthConfig.androidServerClientId,
      rememberedEmail: () => ref.read(localStoreProvider).googleEmail,
    );
  }
  if (Platform.isMacOS && OAuthConfig.desktopConfigured) {
    return DesktopGoogleAccountService(
      clientId: OAuthConfig.desktopClientId,
      clientSecret: OAuthConfig.desktopClientSecret,
      secrets: ref.read(secretStoreProvider),
    );
  }
  return null;
});

/// Where synced settings are kept for a signed-in account.
final settingsRemoteFactoryProvider =
    Provider<SettingsRemote Function(GoogleSession)>(
      (ref) =>
          (session) => DriveSettingsRemote(session.client),
    );

/// The mileage spreadsheet for a signed-in account.
final mileageSheetFactoryProvider =
    Provider<MileageSheet Function(GoogleSession)>(
      (ref) =>
          (session) => GoogleMileageSheet(session.client),
    );

enum SyncPhase {
  /// Sign-in isn't set up in this build.
  unavailable,
  signedOut,
  working,
  ready,
  error,
}

class SyncState {
  const SyncState(
    this.phase, {
    this.email,
    this.lastSynced,
    this.message,
    this.expired = false,
  });

  final SyncPhase phase;
  final String? email;
  final DateTime? lastSynced;
  final String? message;

  /// Google no longer accepts this device's sign-in (it expired or was
  /// revoked): nothing syncs until you sign in again.
  final bool expired;

  bool get signedIn => email != null;
}

/// Google's answer when a saved sign-in can't be used any more (e.g. a
/// week after signing in, while the app's Google project is in testing).
bool isExpiredSignIn(Object e) {
  final text = '$e';
  return text.contains('invalid_grant') || text.contains('expired or revoked');
}

final syncProvider = NotifierProvider<SyncNotifier, SyncState>(
  SyncNotifier.new,
);

/// Signs in to Google and keeps settings (including the API key) and clients the same
/// on every device signed in to the same account.
class SyncNotifier extends Notifier<SyncState> {
  GoogleSession? _session;
  SettingsRemote? _remote;
  Future<void>? _running;
  bool _again = false;
  Timer? _debounce;

  @override
  SyncState build() {
    ref.onDispose(() => _debounce?.cancel());
    return ref.read(googleAccountServiceProvider) == null
        ? const SyncState(SyncPhase.unavailable)
        : const SyncState(SyncPhase.signedOut);
  }

  GoogleAccountService? get _account => ref.read(googleAccountServiceProvider);

  bool _restoring = false;

  /// At startup (and whenever this device should be signed in but isn't):
  /// sign back in without asking if possible, then sync. If that doesn't
  /// work for an account used here before, say so, rather than quietly
  /// not syncing.
  Future<void> restore() async {
    final account = _account;
    if (account == null || _session != null || _restoring) return;
    _restoring = true;
    try {
      GoogleSession? session;
      try {
        // Android may need to show a prompt, which it can't while the
        // phone is locked; don't wait on it forever.
        session = await account.restore().timeout(const Duration(seconds: 45));
      } catch (e) {
        debugPrint('Dunn Record Keeping: signing back in failed: $e');
      }
      if (session == null) {
        final remembered = ref.read(localStoreProvider).googleEmail;
        if (remembered != null) {
          state = SyncState(
            SyncPhase.error,
            email: remembered,
            lastSynced: state.lastSynced,
            expired: true,
            message:
                'This device isn\'t signed in to Google any more, so nothing '
                'is syncing. Sign in again.',
          );
        }
        return;
      }
      await _connect(session);
    } finally {
      _restoring = false;
    }
  }

  Future<void> signIn() async {
    final account = _account;
    if (account == null) return;
    state = const SyncState(SyncPhase.working, message: 'Signing in…');
    try {
      await _connect(await account.signIn());
    } on GoogleAccountException catch (e) {
      state = SyncState(
        e.cancelled ? SyncPhase.signedOut : SyncPhase.error,
        message: e.message,
      );
    }
  }

  Future<void> signOut() async {
    _debounce?.cancel();
    _session = null;
    _remote = null;
    try {
      await _account?.signOut();
    } catch (_) {
      // Signed out locally either way.
    }
    await ref.read(localStoreProvider).setGoogleEmail(null);
    state = const SyncState(SyncPhase.signedOut);
  }

  /// Signs out, makes this device forget the old account (its
  /// spreadsheet, form responses, signed docs and calendars) and, unless
  /// [keepData], erases clients, trips, sessions, payments and expenses
  /// here. Then opens sign-in to pick the new account, which gets its own
  /// spreadsheet. Nothing in the old account's Drive is touched.
  Future<void> switchAccount({required bool keepData}) async {
    await signOut();
    await _forgetAccount(keepData: keepData);
    await signIn();
  }

  Future<void> _forgetAccount({required bool keepData}) async {
    await ref.read(localStoreProvider).forgetAccount(keepData: keepData);
    // The Stripe connection belongs with the account (a test account would
    // use a Stripe test key).
    await ref.read(stripeKeyProvider.notifier).forget();
    for (final p in [
      stripeKeyProvider,
      stripeProvider,
      settingsProvider,
      addressesProvider,
      tripsProvider,
      jobsProvider,
      otherDeviceJobsProvider,
      leadsProvider,
      leadStatesProvider,
      clubRegistrationsProvider,
      policySignaturesProvider,
      signatureDecisionsProvider,
      calendarProvider,
      ...syncedRecordProviders,
    ]) {
      ref.invalidate(p);
    }
    if (keepData) {
      // Upload everything again, to the new account's spreadsheet.
      await ref.read(tripsProvider.notifier).markAllUnsynced();
      await ref.read(jobsProvider.notifier).markAllUnsynced();
    }
  }

  /// A synced setting changed on this device: push it shortly.
  void localChanged() {
    if (_remote == null) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), () => syncNow());
  }

  /// Pull newer settings from the other device and push ours. Not
  /// signed in, but was before: tries signing back in first.
  Future<void> syncNow() {
    if (_remote == null) {
      return ref.read(localStoreProvider).googleEmail == null
          ? Future.value()
          : restore();
    }
    if (_running != null) {
      _again = true;
      return _running!;
    }
    return _running = _syncLoop().whenComplete(() => _running = null);
  }

  Future<void> _connect(GoogleSession session) async {
    _session = session;
    _remote = ref.read(settingsRemoteFactoryProvider)(session);
    state = SyncState(SyncPhase.working, email: session.email);
    try {
      session.email ??= await _remote!.accountEmail();
    } catch (_) {
      // Email is for display and background uploads; not required.
    }
    final store = ref.read(localStoreProvider);
    final email = session.email;
    // Signed out and back in with a different account: don't write to the
    // old account's spreadsheet (it can't open it). Keep the data; it
    // moves to the new account.
    final previous = store.dataAccount;
    if (email != null &&
        previous != null &&
        previous.toLowerCase() != email.toLowerCase()) {
      await _forgetAccount(keepData: true);
    }
    if (email != null) await store.setDataAccount(email);
    await store.setGoogleEmail(email);
    await syncNow();
  }

  Future<void> _syncLoop() async {
    do {
      _again = false;
      await _syncOnce();
    } while (_again && _remote != null);
  }

  Future<void> _syncOnce() async {
    final remote = _remote;
    final email = _session?.email;
    if (remote == null) return;
    state = SyncState(
      SyncPhase.working,
      email: email,
      lastSynced: state.lastSynced,
    );
    try {
      final settings = ref.read(settingsProvider);
      final apiKey = ref.read(apiKeyProvider);
      final local = _localDoc();
      final theirs = await remote.read();
      final merged = dedupeClients(mergeDocs(local, theirs ?? const {}));

      if (!docsEqual(merged, local)) {
        // The Stripe key, if entered (or removed) on the other device.
        final stripeKey = merged[stripeKeyField];
        final keyAt = ref.read(stripeKeyProvider.notifier).changedAt;
        if (stripeKey != null &&
            (keyAt == null || stripeKey.at.isAfter(keyAt))) {
          await ref
              .read(stripeKeyProvider.notifier)
              .setFromSync(stripeKey.value as String?, stripeKey.at);
        }
        final applied = applyDoc(merged, settings, apiKey);
        await ref
            .read(settingsProvider.notifier)
            .replaceFromSync(applied.settings);
        if (applied.apiKeyChanged) {
          await ref.read(apiKeyProvider.notifier).setFromSync(applied.apiKey);
        }
        // Merge again with the current lists, in case a client (or
        // donation center) was added or edited here while the file was
        // downloading.
        final clients = clientsFromDoc(
          mergeDocs(_localClientDoc(), clientEntries(merged)),
        );
        await ref
            .read(addressesProvider.notifier)
            .replaceFromSync(clients.clients, clients.deletions);
        final centers = placesFromDoc(
          mergeDocs(
            _localDonationDoc(),
            entriesWithPrefix(merged, donationPrefix),
          ),
          donationPrefix,
        );
        await ref
            .read(donationCentersProvider.notifier)
            .replaceFromSync(centers.clients, centers.deletions);
        // Jobs the other device recorded, for client pages.
        await ref
            .read(otherDeviceJobsProvider.notifier)
            .replace(otherDeviceJobs(merged, _localJobIds()));
        // Policy form responses matched on the other device.
        await ref
            .read(signatureDecisionsProvider.notifier)
            .replaceFromSync(
              signatureDecisionsFromDoc(
                mergeDocs(
                  signatureDecisionDoc(ref.read(signatureDecisionsProvider)),
                  entriesWithPrefix(merged, signaturePrefix),
                ),
              ),
            );
        // Payments, expenses and Dunn Club decisions from the other device.
        for (final p in syncedRecordProviders) {
          await ref.read(p.notifier).mergeFromSync(merged);
        }
        // Leads made clients or dismissed on the other device.
        await ref
            .read(leadStatesProvider.notifier)
            .replaceFromSync(
              leadStatesFromDoc(
                mergeDocs(
                  leadDocFromLocal(ref.read(leadStatesProvider)),
                  entriesWithPrefix(merged, leadPrefix),
                ),
              ),
            );
      }

      // New Stripe payments (if connected; at most every few minutes),
      // before the spreadsheet is written so its Payments tab has them.
      // Errors are shown in Settings.
      await ref.read(stripeProvider.notifier).refresh();

      // Spreadsheet: create it if neither device has, then upload trips.
      // A failure here is reported but doesn't stop settings syncing.
      String? sheetError;
      try {
        await _syncTrips();
      } on SheetException catch (e) {
        sheetError = e.message;
      }
      // New leads, Dunn Club sign-ups and signed policies from the forms
      // linked to the spreadsheet.
      try {
        await _syncForms();
      } catch (_) {
        // Shown as before; tried again next sync.
      }

      // Push settings (including a just-created spreadsheet's ID) and
      // clients.
      // This device's own jobs always go as they are here (only it
      // changes them, e.g. miles measured once back online).
      final toWrite = {
        ...dedupeClients(mergeDocs(_localDoc(), theirs ?? const {})),
        ..._localJobDoc(),
      };
      if (theirs == null || !docsEqual(toWrite, theirs)) {
        await remote.write(toWrite);
      }
      state = SyncState(
        sheetError == null ? SyncPhase.ready : SyncPhase.error,
        email: email,
        lastSynced: sheetError == null
            ? ref.read(clockProvider)()
            : state.lastSynced,
        message: sheetError == null
            ? null
            : 'Trips not uploaded yet: $sheetError',
      );
    } catch (e) {
      debugPrint('Dunn Record Keeping: sync failed: $e');
      final expired = isExpiredSignIn(e);
      state = SyncState(
        SyncPhase.error,
        email: email,
        lastSynced: state.lastSynced,
        expired: expired,
        message: expired
            ? 'Google sign-in on this device has expired, so nothing is '
                  'syncing. Sign in again.'
            : 'Couldn\'t sync settings: $e',
      );
    }
  }

  /// Everything this device syncs: settings, API keys, clients and
  /// donation centers.
  SyncDoc _localDoc() => {
    if (ref.read(stripeKeyProvider.notifier).changedAt case final at?)
      stripeKeyField: SyncField(ref.read(stripeKeyProvider), at),
    ...docFromLocal(ref.read(settingsProvider), ref.read(apiKeyProvider)),
    ..._localClientDoc(),
    ..._localDonationDoc(),
    ...leadDocFromLocal(ref.read(leadStatesProvider)),
    ...signatureDecisionDoc(ref.read(signatureDecisionsProvider)),
    for (final p in syncedRecordProviders) ...ref.read(p.notifier).toDoc(),
    ...ref.read(otherDeviceJobsProvider),
    ..._localJobDoc(),
  };

  Set<String> _localJobIds() => {for (final j in ref.read(jobsProvider)) j.id};

  SyncDoc _localJobDoc() {
    final trips = ref.read(tripsProvider);
    final now = ref.read(clockProvider)();
    return jobDocFromLocal([
      for (final j in ref.read(jobsProvider)) summarizeJob(j, trips, now),
    ]);
  }

  SyncDoc _localDonationDoc() => placesDocFromLocal(
    donationPrefix,
    ref.read(donationCentersProvider),
    ref.read(localStoreProvider).loadDonationDeletions(),
  );

  SyncDoc _localClientDoc() => clientDocFromLocal(
    ref.read(addressesProvider),
    ref.read(localStoreProvider).loadClientDeletions(),
  );

  Future<void> _syncForms() async {
    final session = _session;
    final id = ref.read(settingsProvider).spreadsheetId;
    if (session == null || id == null) return;
    final sheet = ref.read(mileageSheetFactoryProvider)(session);
    final tabs = await sheet.readFormTabs(id);
    // Policies forms ask for a typed signature; the website contact form
    // asks for a phone number; any other linked form is the Dunn Club
    // sign-up.
    final kinds = {
      for (final e in tabs.entries)
        if (e.value.isNotEmpty) e.key: formKindOf(e.value.first),
    };
    Iterable<List<List<String>>> of(FormKind kind) => [
      for (final e in kinds.entries)
        if (e.value == kind) tabs[e.key]!,
    ];
    final contact = of(FormKind.contact);
    final club = of(FormKind.club);
    await ref
        .read(leadsProvider.notifier)
        .replace(
          tabs.isEmpty
              ? null
              : [for (final rows in contact) ...parseFormResponses(rows)],
        );
    await ref.read(clubRegistrationsProvider.notifier).replace([
      for (final rows in club) ...parseClubResponses(rows),
    ]);
    await ref.read(policySignaturesProvider.notifier).replace([
      for (final e in kinds.entries)
        if (e.value == FormKind.policy)
          ...parsePolicyResponses(e.key, tabs[e.key]!),
    ]);
  }

  /// Keeps the spreadsheet's Payments and Expenses tabs matching the app
  /// (rewritten only when something changed).
  Future<void> _syncLedger(MileageSheet sheet, String id) async {
    final store = ref.read(localStoreProvider);
    if (store.recordsRaw(_recordsSheetKey) != id) {
      await sheet.upgradeToRecords(id);
      await store.setRecordsRaw(_recordsSheetKey, id);
      await store.setRecordsRaw(_ledgerWrittenKey, '');
    }
    final payments = paymentRows(ref.read(ledgerProvider));
    final expenses = expenseRows(ref.read(allExpensesProvider));
    final written = '$id|${jsonEncode([payments, expenses]).hashCode}';
    if (store.recordsRaw(_ledgerWrittenKey) == written) return;
    await sheet.writeLedger(id, payments: payments, expenses: expenses);
    await store.setRecordsRaw(_ledgerWrittenKey, written);
  }

  static const _recordsSheetKey = LocalStore.recordsSheetKey;
  static const _ledgerWrittenKey = LocalStore.ledgerWrittenKey;

  Future<void> _syncTrips({bool retried = false}) async {
    final session = _session;
    if (session == null) return;
    final sheet = ref.read(mileageSheetFactoryProvider)(session);
    final settings = ref.read(settingsProvider.notifier);
    final trips = ref.read(tripsProvider.notifier);
    final store = ref.read(localStoreProvider);

    final String id;
    final existing = ref.read(settingsProvider).spreadsheetId;
    if (existing != null) {
      id = existing;
    } else {
      id = await sheet.create();
      await settings.setSpreadsheetId(id);
      await store.setStyledSheetId(id);
    }

    try {
      // Spreadsheets made by older versions: fix white-on-white trip rows.
      if (store.styledSheetId != id) {
        await sheet.restyle(id);
        await store.setStyledSheetId(id);
      }
      final deletes = store.loadPendingDeletes();
      if (deletes.isNotEmpty) {
        await sheet.deleteTrips(id, deletes);
        // Keep any deletes that were added while this one ran.
        await store.savePendingDeletes(
          store.loadPendingDeletes().difference(deletes),
        );
      }
      final waiting = [
        for (final t in ref.read(tripsProvider))
          if (!t.synced) t,
      ];
      if (waiting.isNotEmpty) {
        await sheet.addTrips(id, waiting);
        await trips.markSynced({for (final t in waiting) t.id});
      }
      // Finished jobs, with the miles driven during each.
      final jobs = ref.read(jobsProvider.notifier);
      await jobs.refresh();
      final done = [
        for (final j in ref.read(jobsProvider))
          if (!j.isActive && !j.synced) j,
      ];
      if (done.isNotEmpty) {
        final all = ref.read(tripsProvider);
        await sheet.addJobs(id, [
          for (final j in done) (job: j, miles: jobMiles(j, all)),
        ]);
        await jobs.markSynced({for (final j in done) j.id});
      }
      // Payments and expenses, after mileage so a problem here can't hold
      // trips back.
      await _syncLedger(sheet, id);
    } on SheetException catch (e) {
      if (!e.missing || retried) rethrow;
      // The spreadsheet was deleted: start a new one with this device's
      // trips. (The other device adds its own when it next syncs.)
      final fresh = await sheet.create();
      await settings.setSpreadsheetId(fresh);
      await store.setStyledSheetId(fresh);
      await store.savePendingDeletes(const {});
      await trips.markAllUnsynced();
      await ref.read(jobsProvider.notifier).markAllUnsynced();
      await _syncTrips(retried: true);
    }
  }
}
