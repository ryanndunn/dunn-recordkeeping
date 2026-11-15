/// Google OAuth client IDs, supplied at build time with
/// `--dart-define-from-file=config/google_oauth.json`
/// (copy config/google_oauth.example.json and fill it in).
///
/// Left empty, the app builds and runs normally with Google sign-in turned
/// off.
abstract final class OAuthConfig {
  /// "Web application" client. Android's sign-in system needs it as the
  /// server client ID, even though there is no server.
  static const androidServerClientId = String.fromEnvironment(
    'GOOGLE_ANDROID_SERVER_CLIENT_ID',
  );

  /// "Desktop app" client, used by the Mac app's browser sign-in.
  static const desktopClientId = String.fromEnvironment(
    'GOOGLE_DESKTOP_CLIENT_ID',
  );

  /// Comes with the desktop client. Google does not treat installed-app
  /// secrets as confidential, but it is still kept out of git.
  static const desktopClientSecret = String.fromEnvironment(
    'GOOGLE_DESKTOP_CLIENT_SECRET',
  );

  static bool _filled(String v) => v.isNotEmpty && !v.startsWith('PASTE-');

  static bool get androidConfigured => _filled(androidServerClientId);

  static bool get desktopConfigured =>
      _filled(desktopClientId) && _filled(desktopClientSecret);
}
