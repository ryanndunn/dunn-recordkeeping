import 'dart:convert';
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/oauth_config.dart';
import '../models/lead.dart';
import '../services/google_account.dart';
import '../services/google_account_android.dart';
import '../services/google_account_desktop.dart';
import '../services/mileage_sheet.dart';
import '../services/jobs.dart' show jobMiles, summarizeJob;
import '../services/ledger.dart';
import '../services/settings_sync.dart';
import 'leads_provider.dart';
import 'money_provider.dart';
import 'policy_docs_provider.dart';
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
  const SyncState(this.phase, {this.email, this.lastSynced, this.message});

  final SyncPhase phase;
  final String? email;
  final DateTime? lastSynced;
  final String? message;

  bool get signedIn => email != null;
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

  /// At startup: sign back in silently if possible, then sync.
  Future<void> restore() async {
    final account = _account;
    if (account == null || _session != null) return;
    final session = await account.restore();
    if (session == null) return;
    await _connect(session);
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

  /// A synced setting changed on this device: push it shortly.
  void localChanged() {
    if (_remote == null) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), () => syncNow());
  }

  /// Pull newer settings from the other device and push ours.
  Future<void> syncNow() {
    if (_remote == null) return Future.value();
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
    await ref.read(localStoreProvider).setGoogleEmail(session.email);
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
        // Signed policy docs matched on the other device.
        await ref
            .read(signedDocDecisionsProvider.notifier)
            .replaceFromSync(
              signedDocDecisionsFromDoc(
                mergeDocs(
                  signedDocDecisionDoc(ref.read(signedDocDecisionsProvider)),
                  entriesWithPrefix(merged, signedDocPrefix),
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

      // Spreadsheet: create it if neither device has, then upload trips.
      // A failure here is reported but doesn't stop settings syncing.
      String? sheetError;
      try {
        await _syncTrips();
      } on SheetException catch (e) {
        sheetError = e.message;
      }
      // New leads from the website's form (if it's linked to the sheet).
      try {
        await _syncLeads();
      } catch (_) {
        // Shown as before; tried again next sync.
      }
      // Newly signed policy docs (if Drive access was given).
      await ref.read(signedDocsProvider.notifier).check();

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
      state = SyncState(
        SyncPhase.error,
        email: email,
        lastSynced: state.lastSynced,
        message: 'Couldn\'t sync settings: $e',
      );
    }
  }

  /// Everything this device syncs: settings, API key, clients and
  /// donation centers.
  SyncDoc _localDoc() => {
    ...docFromLocal(ref.read(settingsProvider), ref.read(apiKeyProvider)),
    ..._localClientDoc(),
    ..._localDonationDoc(),
    ...leadDocFromLocal(ref.read(leadStatesProvider)),
    ...signedDocDecisionDoc(ref.read(signedDocDecisionsProvider)),
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

  Future<void> _syncLeads() async {
    final session = _session;
    final id = ref.read(settingsProvider).spreadsheetId;
    if (session == null || id == null) return;
    final sheet = ref.read(mileageSheetFactoryProvider)(session);
    final tabs = await sheet.readFormTabs(id);
    // The website contact form asks for a phone number; any other linked
    // form is the Dunn Club sign-up.
    final contact = tabs.values.where(
      (rows) => rows.isNotEmpty && isContactFormHeader(rows.first),
    );
    final club = tabs.values.where(
      (rows) => rows.isNotEmpty && !isContactFormHeader(rows.first),
    );
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
    final expenses = expenseRows(ref.read(expensesProvider));
    final written = '$id|${jsonEncode([payments, expenses]).hashCode}';
    if (store.recordsRaw(_ledgerWrittenKey) == written) return;
    await sheet.writeLedger(id, payments: payments, expenses: expenses);
    await store.setRecordsRaw(_ledgerWrittenKey, written);
  }

  static const _recordsSheetKey = 'records_sheet_v1';
  static const _ledgerWrittenKey = 'ledger_written_v1';

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
