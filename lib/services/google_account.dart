import 'package:http/http.dart' as http;

/// Google permissions the app asks for. Both are "non-sensitive": the app
/// can only see files it created itself, plus its own hidden settings
/// folder in Drive.
const googleScopes = <String>[
  'https://www.googleapis.com/auth/drive.file',
  'https://www.googleapis.com/auth/drive.appdata',
];

/// Read-only access to the names and dates of files in Drive (not their
/// contents), to spot signed policy documents. Asked for separately, from
/// Settings, so signing in and syncing never depend on it.
const policyDocsScope =
    'https://www.googleapis.com/auth/drive.metadata.readonly';

/// Read-only access to Google Calendar events, for the Calendar tab.
/// Asked for separately, like [policyDocsScope].
const calendarScope = 'https://www.googleapis.com/auth/calendar.readonly';

/// A signed-in Google account, with an HTTP client that adds (and keeps
/// fresh) the access token on every request.
class GoogleSession {
  GoogleSession({required this.client, this.email});

  final http.Client client;

  /// Filled in by the caller after the first Drive call, if not known.
  String? email;
}

class GoogleAccountException implements Exception {
  const GoogleAccountException(this.message, {this.cancelled = false});
  final String message;

  /// The user backed out; not worth an error message.
  final bool cancelled;

  @override
  String toString() => message;
}

/// Signs in to Google. Android uses the system account picker; macOS uses a
/// browser window.
abstract class GoogleAccountService {
  /// Signs back in without any UI if the user did before. Null if not.
  Future<GoogleSession?> restore();

  /// Interactive sign-in. Must be called from a button press.
  Future<GoogleSession> signIn();

  Future<void> signOut();

  /// Asks for an extra permission, [scope] ([policyDocsScope] or
  /// [calendarScope]), showing Google's consent screen. Returns a client
  /// that uses it. Must be called from a button press.
  Future<http.Client> grantAccess(String scope);

  /// A client for [scope] if it was granted before (no UI), else null.
  Future<http.Client?> access(String scope);
}
