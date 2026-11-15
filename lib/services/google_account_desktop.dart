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
        (url) => launchUrl(Uri.parse(url)),
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
