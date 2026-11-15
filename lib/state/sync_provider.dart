import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/oauth_config.dart';
import '../services/google_account.dart';
import '../services/google_account_android.dart';
import '../services/google_account_desktop.dart';
import '../services/settings_sync.dart';
import 'providers.dart';

/// Google sign-in for this platform, or null when this build has no
/// client IDs (or the platform isn't Android/macOS, e.g. web preview).
final googleAccountServiceProvider = Provider<GoogleAccountService?>((ref) {
  if (kIsWeb) return null;
  if (Platform.isAndroid && OAuthConfig.androidConfigured) {
    return AndroidGoogleAccountService(
      serverClientId: OAuthConfig.androidServerClientId,
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

/// Signs in to Google and keeps settings (including the API key) the same
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
      // Email is only for display.
    }
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
      final local = docFromLocal(settings, apiKey);
      final theirs = await remote.read();
      final merged = mergeDocs(local, theirs ?? const {});

      if (!docsEqual(merged, local)) {
        final applied = applyDoc(merged, settings, apiKey);
        await ref
            .read(settingsProvider.notifier)
            .replaceFromSync(applied.settings);
        if (applied.apiKeyChanged) {
          await ref.read(apiKeyProvider.notifier).setFromSync(applied.apiKey);
        }
      }
      if (theirs == null || !docsEqual(merged, theirs)) {
        await remote.write(merged);
      }
      state = SyncState(
        SyncPhase.ready,
        email: email,
        lastSynced: ref.read(clockProvider)(),
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
}
