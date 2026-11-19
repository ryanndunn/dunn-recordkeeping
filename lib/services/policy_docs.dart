import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;

import '../models/saved_address.dart';

/// A PDF in Drive that looks like a signed policy document. Google's
/// eSignature saves one to Drive when everyone has signed.
class SignedDoc {
  const SignedDoc({required this.id, required this.name, required this.at});

  final String id;
  final String name;

  /// When it was created (when the signing finished).
  final DateTime at;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'at': at.toUtc().toIso8601String(),
  };

  factory SignedDoc.fromJson(Map<String, dynamic> json) => SignedDoc(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    at: DateTime.parse(json['at'] as String),
  );
}

/// What was decided about a signed doc: the client it belongs to, or that
/// it isn't a client's policy doc. Synced between devices.
class SignedDocDecision {
  const SignedDocDecision({this.clientId, this.automatic = false});

  /// Not a client's policy doc.
  static const ignored = SignedDocDecision();

  final String? clientId;

  /// Matched by the client's name in the file name (not picked by hand).
  final bool automatic;

  Map<String, dynamic> toJson() => {
    if (clientId != null) 'clientId': clientId,
    if (automatic) 'automatic': true,
  };

  factory SignedDocDecision.fromJson(Map<String, dynamic> json) =>
      SignedDocDecision(
        clientId: json['clientId'] as String?,
        automatic: json['automatic'] as bool? ?? false,
      );
}

/// Finds signed policy PDFs in the user's Drive.
abstract class SignedDocSource {
  /// PDFs whose name contains [nameContains], newest first.
  Future<List<SignedDoc>> find(String nameContains);
}

class DriveSignedDocSource implements SignedDocSource {
  DriveSignedDocSource(http.Client client) : _api = drive.DriveApi(client);

  final drive.DriveApi _api;

  @override
  Future<List<SignedDoc>> find(String nameContains) async {
    final term = nameContains.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
    final docs = <SignedDoc>[];
    String? page;
    do {
      final list = await _api.files.list(
        q:
            "mimeType = 'application/pdf' and name contains '$term' "
            'and trashed = false',
        $fields: 'nextPageToken, files(id, name, createdTime)',
        orderBy: 'createdTime desc',
        pageSize: 100,
        pageToken: page,
        spaces: 'drive',
      );
      for (final f in list.files ?? const <drive.File>[]) {
        if (f.id == null) continue;
        docs.add(
          SignedDoc(
            id: f.id!,
            name: f.name ?? '',
            at: f.createdTime ?? DateTime.now(),
          ),
        );
      }
      page = list.nextPageToken;
      // A few hundred is plenty; older docs are long since handled.
    } while (page != null && docs.length < 500);
    return docs;
  }
}

String _plain(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

/// The client [doc] is for, by their name in its file name: the whole
/// name, or every word of it in any order ("Smith, Jane"). The longest
/// matching name wins, so "Ann Lee" doesn't take "Ann Leeds"'s doc. Null
/// if no client, or more than one equally, matches. Archived clients are
/// included (signing doesn't change their status).
SavedAddress? matchSignedDoc(SignedDoc doc, List<SavedAddress> clients) {
  final words = _plain(doc.name).split(' ').toSet();
  final file = ' ${_plain(doc.name)} ';
  final hits = <SavedAddress>[];
  for (final c in clients) {
    final name = _plain(c.name);
    if (name.isEmpty) continue;
    final parts = name.split(' ');
    if (file.contains(' $name ') || parts.every(words.contains)) hits.add(c);
  }
  if (hits.isEmpty) return null;
  hits.sort((a, b) => _plain(b.name).length.compareTo(_plain(a.name).length));
  if (hits.length > 1 &&
      _plain(hits[0].name).length == _plain(hits[1].name).length) {
    return null;
  }
  return hits.first;
}

/// [client] with the policy doc signed on [doc]'s day: active, unless
/// archived (signing doesn't bring them back).
SavedAddress signedWith(SavedAddress client, SignedDoc doc) {
  final d = doc.at.toLocal();
  return client.copyWith(
    policiesSignedOn: DateTime(d.year, d.month, d.day),
    status: client.status == ClientStatus.archived ? null : ClientStatus.active,
  );
}
