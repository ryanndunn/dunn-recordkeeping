import 'package:google_sign_in/google_sign_in.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:http/http.dart' as http;

import 'google_account.dart';

/// Android: Google's sign-in package (system account picker).
class AndroidGoogleAccountService implements GoogleAccountService {
  AndroidGoogleAccountService({
    required this.serverClientId,
    required this.rememberedEmail,
  });

  /// The "Web application" OAuth client ID (Android's sign-in needs one).
  final String serverClientId;

  /// The account signed in last time (cleared on sign-out), used when the
  /// quick sign-in can't find it, e.g. after an app update.
  final String? Function() rememberedEmail;

  final _signIn = GoogleSignIn.instance;
  Future<void>? _initialized;

  Future<void> _init() =>
      _initialized ??= _signIn.initialize(serverClientId: serverClientId);

  @override
  Future<GoogleSession?> restore() async {
    try {
      await _init();
      final account = await _signIn.attemptLightweightAuthentication();
      if (account != null) {
        final auth = await account.authorizationClient.authorizationForScopes(
          googleScopes,
        );
        if (auth != null) return _session(account);
      }
    } on GoogleSignInException {
      // Fall through to the remembered account.
    }
    return _restoreRemembered();
  }

  /// Asks Android for a token for the remembered account, with no screen.
  /// Works as long as the user hasn't removed the app's Google access.
  Future<GoogleSession?> _restoreRemembered() async {
    final email = rememberedEmail();
    if (email == null) return null;
    Future<String?> token() async {
      final tokens = await GoogleSignInPlatform.instance
          .clientAuthorizationTokensForScopes(
            ClientAuthorizationTokensForScopesParameters(
              request: AuthorizationRequestDetails(
                scopes: googleScopes,
                userId: null,
                email: email,
                promptIfUnauthorized: false,
              ),
            ),
          );
      return tokens?.accessToken;
    }

    try {
      if (await token() == null) return null;
    } on GoogleSignInException {
      return null;
    }
    return GoogleSession(
      email: email,
      client: _TokenClient(() async {
        final t = await token();
        if (t == null) {
          throw const GoogleAccountException(
            'Google access was removed. Sign in again in Settings.',
          );
        }
        return t;
      }),
    );
  }

  @override
  Future<GoogleSession> signIn() async {
    try {
      await _init();
      final account = await _signIn.authenticate(scopeHint: googleScopes);
      await account.authorizationClient.authorizeScopes(googleScopes);
      return _session(account);
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        throw const GoogleAccountException(
          'Sign-in was cancelled. If you didn\'t cancel it, the Android '
          'client in Google Cloud may not match this app (package name '
          'or SHA-1).',
          cancelled: true,
        );
      }
      throw GoogleAccountException(
        'Google sign-in failed: ${e.description ?? e.code.name}',
      );
    }
  }

  @override
  Future<void> signOut() async {
    await _init();
    await _signIn.disconnect();
  }

  GoogleSession _session(GoogleSignInAccount account) => GoogleSession(
    email: account.email,
    client: _TokenClient(() async {
      final auth = await account.authorizationClient.authorizationForScopes(
        googleScopes,
      );
      if (auth == null) {
        throw const GoogleAccountException(
          'Google access was removed. Sign in again in Settings.',
        );
      }
      return auth.accessToken;
    }),
  );
}

/// Adds a bearer token to each request, asking for a new one well before
/// Google's one-hour expiry, and once more if Google says it's stale.
class _TokenClient extends http.BaseClient {
  _TokenClient(this._fetchToken);

  final Future<String> Function() _fetchToken;
  final _inner = http.Client();
  String? _token;
  DateTime _fetchedAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<String> _currentToken({bool force = false}) async {
    if (force ||
        _token == null ||
        DateTime.now().difference(_fetchedAt) > const Duration(minutes: 45)) {
      _token = await _fetchToken();
      _fetchedAt = DateTime.now();
    }
    return _token!;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    request.headers['Authorization'] = 'Bearer ${await _currentToken()}';
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
