import '../models/saved_address.dart';

String _plain(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

/// Whether [typed] is [name]: the same words, in any order ("Smith,
/// Jane").
bool sameName(String typed, String name) {
  final a = _plain(typed).split(' ').toSet()..remove('');
  final b = _plain(name).split(' ').toSet()..remove('');
  return b.isNotEmpty && a.length == b.length && b.every(a.contains);
}

/// Which client someone is (a form signer, a Stripe payer): by [email]
/// (the client's own or one of their contacts'), otherwise by [name].
/// [contactId] is null for the client themself. Null if nobody, or more
/// than one client, matches.
({SavedAddress client, String? contactId})? matchPerson({
  required String email,
  required String name,
  required List<SavedAddress> clients,
}) {
  ({SavedAddress client, String? contactId})? only(
    List<({SavedAddress client, String? contactId})> hits,
  ) => {for (final h in hits) h.client.id}.length == 1 ? hits.first : null;

  final e = email.trim().toLowerCase();
  if (e.isNotEmpty) {
    final hits = [
      for (final c in clients) ...[
        if (c.email.toLowerCase() == e) (client: c, contactId: null),
        for (final p in c.contacts)
          if (p.email.toLowerCase() == e) (client: c, contactId: p.id),
      ],
    ];
    if (hits.isNotEmpty) return only(hits);
  }
  if (name.trim().isEmpty) return null;
  final hits = [
    for (final c in clients) ...[
      if (sameName(name, c.name)) (client: c, contactId: null),
      for (final p in c.contacts)
        if (sameName(name, p.name)) (client: c, contactId: p.id),
    ],
  ];
  return hits.isEmpty ? null : only(hits);
}
