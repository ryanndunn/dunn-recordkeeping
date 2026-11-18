import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:url_launcher/url_launcher.dart';

/// Google Calendar's appointment schedules, where consultation
/// availability is edited.
final availabilityEditorUri = Uri.parse(
  'https://calendar.google.com/calendar/u/0/r/appointment?pli=1',
);

/// Opens the availability editor where you're already signed in to
/// Google (Google doesn't allow signing in inside the app). On the phone
/// it opens over the app in a Chrome tab; on the Mac, in the browser.
/// False if nothing could open it.
Future<bool> openAvailabilityEditor() async {
  try {
    return await launchUrl(
      availabilityEditorUri,
      mode: !kIsWeb && Platform.isAndroid
          ? LaunchMode.inAppBrowserView
          : LaunchMode.externalApplication,
    );
  } catch (_) {
    return false;
  }
}
