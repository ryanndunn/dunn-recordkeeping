import 'dart:convert';

import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;

import '../models/app_settings.dart';
import '../models/place.dart';

/// One synced setting: its value (as JSON) and when it was last changed.
class SyncField {
  const SyncField(this.value, this.at);

  final Object? value;
  final DateTime at;

  @override
  bool operator ==(Object other) =>
      other is SyncField &&
      other.at.isAtSameMomentAs(at) &&
      jsonEncode(other.value) == jsonEncode(value);

  @override
  int get hashCode => Object.hash(jsonEncode(value), at.millisecondsSinceEpoch);
}

/// All synced settings, keyed by [SyncedField] name.
typedef SyncDoc = Map<String, SyncField>;

/// Values set before syncing existed have no change time; they count as
/// older than anything set since.
final legacyTime = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

/// This device's settings (plus API key) as a [SyncDoc]. Fields never set
/// are left out so they can't overwrite the other device.
SyncDoc docFromLocal(AppSettings s, String? apiKey) {
  final values = <String, Object?>{
    SyncedField.home: s.home?.toJson(),
    SyncedField.navApp: s.navApp.name,
    SyncedField.ratePerMile: s.ratePerMile,
    SyncedField.spreadsheetId: s.spreadsheetId,
    SyncedField.apiKey: apiKey,
  };
  final doc = <String, SyncField>{};
  for (final field in SyncedField.all) {
    final at = s.changedAt[field];
    final value = values[field];
    if (at != null) {
      doc[field] = SyncField(value, at);
    } else if (value != null && field != SyncedField.navApp) {
      doc[field] = SyncField(value, legacyTime);
    }
  }
  return doc;
}

/// Field by field, the newer change wins.
SyncDoc mergeDocs(SyncDoc local, SyncDoc remote) {
  final merged = <String, SyncField>{...remote};
  for (final e in local.entries) {
    final theirs = remote[e.key];
    if (theirs == null || e.value.at.isAfter(theirs.at)) {
      merged[e.key] = e.value;
    }
  }
  return merged;
}

bool docsEqual(SyncDoc a, SyncDoc b) =>
    a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

/// Applies [doc] on top of [current]. Fields missing from [doc] are kept.
({AppSettings settings, String? apiKey, bool apiKeyChanged}) applyDoc(
  SyncDoc doc,
  AppSettings current,
  String? currentApiKey,
) {
  var s = current;
  final times = {...current.changedAt};
  var apiKey = currentApiKey;
  var apiKeyChanged = false;

  for (final e in doc.entries) {
    final v = e.value.value;
    switch (e.key) {
      case SyncedField.home:
        s = AppSettings(
          home: v == null ? null : Place.fromJson(v as Map<String, dynamic>),
          navApp: s.navApp,
          ratePerMile: s.ratePerMile,
          spreadsheetId: s.spreadsheetId,
        );
      case SyncedField.navApp:
        s = s.copyWith(
          navApp: NavApp.values.firstWhere(
            (n) => n.name == v,
            orElse: () => NavApp.googleMaps,
          ),
        );
      case SyncedField.ratePerMile:
        s = v == null
            ? s.copyWith(clearRatePerMile: true)
            : s.copyWith(ratePerMile: (v as num).toDouble());
      case SyncedField.spreadsheetId:
        s = AppSettings(
          home: s.home,
          navApp: s.navApp,
          ratePerMile: s.ratePerMile,
          spreadsheetId: v as String?,
        );
      case SyncedField.apiKey:
        if (v != apiKey) {
          apiKey = v as String?;
          apiKeyChanged = true;
        }
      default:
        continue; // Unknown field from a newer app version.
    }
    times[e.key] = e.value.at;
  }
  return (
    settings: s.copyWith(changedAt: times),
    apiKey: apiKey,
    apiKeyChanged: apiKeyChanged,
  );
}

String encodeDoc(SyncDoc doc) => jsonEncode({
  'version': 1,
  'fields': {
    for (final e in doc.entries)
      e.key: {'value': e.value.value, 'at': e.value.at.toIso8601String()},
  },
});

SyncDoc decodeDoc(String raw) {
  final json = jsonDecode(raw) as Map<String, dynamic>;
  final fields = (json['fields'] as Map<String, dynamic>?) ?? const {};
  return {
    for (final e in fields.entries)
      e.key: SyncField(
        (e.value as Map<String, dynamic>)['value'],
        DateTime.parse((e.value as Map<String, dynamic>)['at'] as String),
      ),
  };
}

/// Where the synced settings live.
abstract class SettingsRemote {
  Future<SyncDoc?> read();
  Future<void> write(SyncDoc doc);

  /// The signed-in account's email, for display.
  Future<String?> accountEmail();
}

/// A JSON file in the app's hidden Drive folder ("appDataFolder"). Hidden
/// from the Drive website and readable only by this app.
class DriveSettingsRemote implements SettingsRemote {
  DriveSettingsRemote(http.Client client) : _api = drive.DriveApi(client);

  final drive.DriveApi _api;
  static const fileName = 'mileage_log_settings.json';
  String? _fileId;

  Future<String?> _findFile() async {
    if (_fileId != null) return _fileId;
    final list = await _api.files.list(
      spaces: 'appDataFolder',
      q: "name = '$fileName' and trashed = false",
      $fields: 'files(id)',
    );
    return _fileId = list.files?.firstOrNull?.id;
  }

  @override
  Future<SyncDoc?> read() async {
    final id = await _findFile();
    if (id == null) return null;
    final media = await _api.files.get(
      id,
      downloadOptions: drive.DownloadOptions.fullMedia,
    ) as drive.Media;
    final bytes = <int>[];
    await for (final chunk in media.stream) {
      bytes.addAll(chunk);
    }
    return decodeDoc(utf8.decode(bytes));
  }

  @override
  Future<void> write(SyncDoc doc) async {
    final bytes = utf8.encode(encodeDoc(doc));
    final media = drive.Media(
      Stream.value(bytes),
      bytes.length,
      contentType: 'application/json',
    );
    final id = await _findFile();
    if (id == null) {
      final created = await _api.files.create(
        drive.File(name: fileName, parents: ['appDataFolder']),
        uploadMedia: media,
        $fields: 'id',
      );
      _fileId = created.id;
    } else {
      await _api.files.update(drive.File(), id, uploadMedia: media);
    }
  }

  @override
  Future<String?> accountEmail() async {
    final about = await _api.about.get($fields: 'user(emailAddress)');
    return about.user?.emailAddress;
  }
}
