import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/oauth_config.dart';
import '../services/google_account.dart';
import '../services/google_account_android.dart';
import '../services/google_account_desktop.dart';
import '../services/mileage_sheet.dart';
import '../services/settings_sync.dart';
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
        // Merge again with the current list, in case a client was added
        // or edited here while the file was downloading.
        final now = clientsFromDoc(
          mergeDocs(_localClientDoc(), clientEntries(merged)),
        );
        await ref
            .read(addressesProvider.notifier)
            .replaceFromSync(now.clients, now.deletions);
      }

      // Spreadsheet: create it if neither device has, then upload trips.
      // A failure here is reported but doesn't stop settings syncing.
      String? sheetError;
      try {
        await _syncTrips();
      } on SheetException catch (e) {
        sheetError = e.message;
      }

      // Push settings (including a just-created spreadsheet's ID) and
      // clients.
      final toWrite = dedupeClients(mergeDocs(_localDoc(), theirs ?? const {}));
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

  /// Everything this device syncs: settings, API key and clients.
  SyncDoc _localDoc() => {
    ...docFromLocal(ref.read(settingsProvider), ref.read(apiKeyProvider)),
    ..._localClientDoc(),
  };

  SyncDoc _localClientDoc() => clientDocFromLocal(
    ref.read(addressesProvider),
    ref.read(localStoreProvider).loadClientDeletions(),
  );

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
      id = await sheet.create(
        ratePerMile: ref.read(settingsProvider).ratePerMile,
      );
      await settings.setSpreadsheetId(id);
    }

    try {
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
    } on SheetException catch (e) {
      if (!e.missing || retried) rethrow;
      // The spreadsheet was deleted: start a new one with this device's
      // trips. (The other device adds its own when it next syncs.)
      final fresh = await sheet.create(
        ratePerMile: ref.read(settingsProvider).ratePerMile,
      );
      await settings.setSpreadsheetId(fresh);
      await store.savePendingDeletes(const {});
      await trips.markAllUnsynced();
      await _syncTrips(retried: true);
    }
  }
}
