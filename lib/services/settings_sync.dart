import 'dart:convert';

import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;

import '../models/app_settings.dart';
import '../models/job.dart';
import '../models/lead.dart';
import '../models/place.dart';
import '../models/saved_address.dart';
import 'policy_docs.dart';

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
    SyncedField.bookingUrl: s.bookingUrl,
    SyncedField.policyDocName: s.policyDocName,
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
          bookingUrl: s.bookingUrl,
          policyDocName: s.policyDocName,
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
          bookingUrl: s.bookingUrl,
          policyDocName: s.policyDocName,
        );
      case SyncedField.policyDocName:
        if (v is String) s = s.copyWith(policyDocName: v);
      case SyncedField.bookingUrl:
        s = v == null
            ? s.copyWith(clearBookingUrl: true)
            : s.copyWith(bookingUrl: v as String);
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

// ------------------------------------------------- clients, donation centers
//
// Each client (and donation center) is its own entry in the same file,
// keyed "client:<id>" (or "donation:<id>"), so the newer change wins entry
// by entry. A deleted one stays as an entry with a null value, so the
// deletion reaches the other device.

const clientPrefix = 'client:';
const donationPrefix = 'donation:';
const _placePrefixes = [clientPrefix, donationPrefix];

bool isClientKey(String key) => key.startsWith(clientPrefix);

bool _isPlaceKey(String key) => _placePrefixes.any(key.startsWith);

/// This device's list and deletions as [SyncDoc] entries under [prefix].
SyncDoc placesDocFromLocal(
  String prefix,
  List<SavedAddress> list,
  Map<String, DateTime> deletions,
) {
  final doc = <String, SyncField>{
    for (final e in deletions.entries)
      '$prefix${e.key}': SyncField(null, e.value.toUtc()),
  };
  for (final c in list) {
    final at = (c.updatedAt ?? legacyTime).toUtc();
    final key = '$prefix${c.id}';
    final deleted = doc[key];
    if (deleted == null || at.isAfter(deleted.at)) {
      doc[key] = SyncField(c.toJson(withTime: false), at);
    }
  }
  return doc;
}

SyncDoc clientDocFromLocal(
  List<SavedAddress> clients,
  Map<String, DateTime> deletions,
) => placesDocFromLocal(clientPrefix, clients, deletions);

/// Just the entries of [doc] under [prefix].
SyncDoc entriesWithPrefix(SyncDoc doc, String prefix) => {
  for (final e in doc.entries)
    if (e.key.startsWith(prefix)) e.key: e.value,
};

SyncDoc clientEntries(SyncDoc doc) => entriesWithPrefix(doc, clientPrefix);

/// The list and deletions under [prefix] in [doc], sorted by name.
({List<SavedAddress> clients, Map<String, DateTime> deletions}) placesFromDoc(
  SyncDoc doc,
  String prefix,
) {
  final list = <SavedAddress>[];
  final deletions = <String, DateTime>{};
  for (final e in doc.entries) {
    if (!e.key.startsWith(prefix)) continue;
    final id = e.key.substring(prefix.length);
    final v = e.value.value;
    if (v == null) {
      deletions[id] = e.value.at;
    } else {
      final c = SavedAddress.fromJson({
        ...(v as Map<String, dynamic>),
        'id': id,
      });
      list.add(
        c.copyWith(
          updatedAt: e.value.at.isAtSameMomentAs(legacyTime)
              ? null
              : e.value.at,
        ),
      );
    }
  }
  list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return (clients: list, deletions: deletions);
}

({List<SavedAddress> clients, Map<String, DateTime> deletions}) clientsFromDoc(
  SyncDoc doc,
) => placesFromDoc(doc, clientPrefix);

/// When the same client (or donation center) was added on both devices
/// (same name at the same place), keeps one: the most recently changed, or
/// on a tie the lower ID. The others are marked deleted just after their
/// own change time, so every device makes the same choice and the copies
/// don't come back.
SyncDoc dedupeClients(SyncDoc doc) {
  final groups = <String, List<MapEntry<String, SyncField>>>{};
  for (final e in doc.entries) {
    final v = e.value.value;
    if (!_isPlaceKey(e.key) || v is! Map<String, dynamic>) continue;
    final prefix = _placePrefixes.firstWhere(e.key.startsWith);
    final name = (v['name'] as String? ?? '').trim().toLowerCase();
    final where =
        (v['placeId'] as String?) ??
        (v['address'] as String? ?? '').trim().toLowerCase();
    (groups['$prefix|$name|$where'] ??= []).add(e);
  }
  final out = {...doc};
  for (final copies in groups.values) {
    if (copies.length < 2) continue;
    copies.sort((a, b) {
      final byTime = b.value.at.compareTo(a.value.at);
      return byTime != 0 ? byTime : a.key.compareTo(b.key);
    });
    for (final dup in copies.skip(1)) {
      out[dup.key] = SyncField(
        null,
        dup.value.at.add(const Duration(milliseconds: 1)),
      );
    }
  }
  return out;
}

// ------------------------------------------------------------------- jobs
//
// Each device sends the jobs it recorded, keyed "job:<id>", with their
// stops and miles. Only the device that recorded a job changes it (and
// uploads it to the spreadsheet); the other just shows it.

const jobPrefix = 'job:';

/// This device's jobs as [SyncDoc] entries.
SyncDoc jobDocFromLocal(List<JobSummary> jobs) => {
  for (final j in jobs)
    '$jobPrefix${j.job.id}': SyncField(j.toJson(), j.changedAt.toUtc()),
};

/// The jobs in [doc] that this device didn't record.
SyncDoc otherDeviceJobs(SyncDoc doc, Set<String> localIds) => {
  for (final e in doc.entries)
    if (e.key.startsWith(jobPrefix) &&
        e.value.value is Map<String, dynamic> &&
        !localIds.contains(e.key.substring(jobPrefix.length)))
      e.key: e.value,
};

List<JobSummary> jobsFromDoc(SyncDoc doc) => [
  for (final e in doc.values)
    if (e.value case final Map<String, dynamic> json) JobSummary.fromJson(json),
];

// ------------------------------------------------------------------ leads
//
// What's been done with each lead (made a client, dismissed), keyed
// "lead:<id>". The newer change wins. The leads themselves come from the
// spreadsheet, which both devices read.

const leadPrefix = 'lead:';

/// Lead states as [SyncDoc] entries.
SyncDoc leadDocFromLocal(
  Map<String, ({LeadState state, DateTime at})> states,
) => {
  for (final e in states.entries)
    '$leadPrefix${e.key}': SyncField(
      e.value.state.toJson(),
      e.value.at.toUtc(),
    ),
};

Map<String, ({LeadState state, DateTime at})> leadStatesFromDoc(
  SyncDoc doc,
) => {
  for (final e in doc.entries)
    if (e.key.startsWith(leadPrefix) && e.value.value is Map<String, dynamic>)
      e.key.substring(leadPrefix.length): (
        state: LeadState.fromJson(e.value.value as Map<String, dynamic>),
        at: e.value.at,
      ),
};

// ------------------------------------------------- signed policy docs
//
// Which client each signed policy PDF belongs to, keyed
// "signeddoc:<Drive file ID>". The newer change wins.

const signedDocPrefix = 'signeddoc:';

SyncDoc signedDocDecisionDoc(
  Map<String, ({SignedDocDecision decision, DateTime at})> decisions,
) => {
  for (final e in decisions.entries)
    '$signedDocPrefix${e.key}': SyncField(
      e.value.decision.toJson(),
      e.value.at.toUtc(),
    ),
};

Map<String, ({SignedDocDecision decision, DateTime at})>
signedDocDecisionsFromDoc(SyncDoc doc) => {
  for (final e in doc.entries)
    if (e.key.startsWith(signedDocPrefix) &&
        e.value.value is Map<String, dynamic>)
      e.key.substring(signedDocPrefix.length): (
        decision: SignedDocDecision.fromJson(
          e.value.value as Map<String, dynamic>,
        ),
        at: e.value.at,
      ),
};

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
