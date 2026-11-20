import 'dart:async';
import 'dart:convert';

import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'google_account.dart';
import 'secret_store.dart';

/// macOS: signs in through the web browser (Google's installed-app flow
/// with a localhost redirect and PKCE), then keeps the refreshable sign-in
/// in the login Keychain.
///
/// Used instead of Google's sign-in package because that one needs the app
/// signed with an Apple Developer team for keychain sharing.
class DesktopGoogleAccountService implements GoogleAccountService {
  DesktopGoogleAccountService({
    required String clientId,
    required String clientSecret,
    required this.secrets,
  }) : _clientId = ClientId(clientId, clientSecret);

  final ClientId _clientId;
  final SecretStore secrets;

  static const _credentialsName = 'google_oauth_credentials';

  /// Each extra permission is kept apart from the main sign-in (and from
  /// each other), so those never change.
  static String _extraName(String scope) => switch (scope) {
    calendarScope => 'google_calendar_credentials',
    _ => 'google_extra_${scope.hashCode}',
  };

  static const _extraScopes = [calendarScope];

  /// Kept by older versions (Drive file names, for signed policy PDFs).
  static const _legacyNames = ['google_policy_credentials'];

  @override
  Future<http.Client?> access(String scope) async {
    final raw = await secrets.read(_extraName(scope));
    if (raw == null) return null;
    try {
      final credentials = AccessCredentials.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      if (credentials.refreshToken == null) return null;
      return _keepSaved(
        scope,
        autoRefreshingClient(_clientId, credentials, http.Client()),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<http.Client> grantAccess(String scope) async {
    try {
      final client = await clientViaUserConsent(_clientId, [
        scope,
      ], _openConsent).timeout(const Duration(minutes: 5));
      await secrets.write(
        _extraName(scope),
        jsonEncode(client.credentials.toJson()),
      );
      return _keepSaved(scope, client);
    } on TimeoutException {
      throw const GoogleAccountException(
        'Timed out. Try again, and finish it in the browser window.',
        cancelled: true,
      );
    } catch (e) {
      throw GoogleAccountException('Google didn\'t grant access: $e');
    }
  }

  AutoRefreshingAuthClient _keepSaved(
    String scope,
    AutoRefreshingAuthClient client,
  ) {
    client.credentialUpdates.listen(
      (c) => secrets.write(_extraName(scope), jsonEncode(c.toJson())),
    );
    return client;
  }

  /// Opens Google's consent page in the browser, always asking which
  /// account to use (the browser may be signed in to several) and always
  /// handing back a refresh token, even for an account used before.
  static void _openConsent(String url) {
    final uri = Uri.parse(url);
    launchUrl(
      uri.replace(
        queryParameters: {
          ...uri.queryParameters,
          'prompt': 'select_account consent',
        },
      ),
    );
  }

  AutoRefreshingAuthClient? _client;
  StreamSubscription<AccessCredentials>? _updates;

  @override
  Future<GoogleSession?> restore() async {
    final raw = await secrets.read(_credentialsName);
    if (raw == null) return null;
    try {
      final credentials = AccessCredentials.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      if (credentials.refreshToken == null) return null;
      return _start(
        autoRefreshingClient(_clientId, credentials, http.Client()),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<GoogleSession> signIn() async {
    final AutoRefreshingAuthClient client;
    try {
      client = await clientViaUserConsent(
        _clientId,
        googleScopes,
        _openConsent,
      ).timeout(const Duration(minutes: 5));
    } on TimeoutException {
      throw const GoogleAccountException(
        'Sign-in timed out. Try again, and finish it in the browser window.',
        cancelled: true,
      );
    } catch (e) {
      throw GoogleAccountException('Google sign-in failed: $e');
    }
    await _save(client.credentials);
    return _start(client);
  }

  @override
  Future<void> signOut() async {
    await _updates?.cancel();
    _client?.close();
    _client = null;
    await secrets.write(_credentialsName, null);
    for (final scope in _extraScopes) {
      await secrets.write(_extraName(scope), null);
    }
    for (final name in _legacyNames) {
      await secrets.write(name, null);
    }
  }

  GoogleSession _start(AutoRefreshingAuthClient client) {
    _updates?.cancel();
    _client?.close();
    _client = client;
    // Google hands out new access tokens hourly; keep the latest.
    _updates = client.credentialUpdates.listen(_save);
    return GoogleSession(client: client);
  }

  Future<void> _save(AccessCredentials credentials) =>
      secrets.write(_credentialsName, jsonEncode(credentials.toJson()));
}
