import 'package:flutter_test/flutter_test.dart';
import 'package:mileage_log/models/saved_address.dart';
import 'package:mileage_log/services/policy_docs.dart';

void main() {
  const jane = SavedAddress(id: 'j', name: 'Jane Smith', address: 'x');
  const ann = SavedAddress(id: 'a', name: 'Ann Lee', address: 'x');
  const annLeeds = SavedAddress(id: 'al', name: 'Ann Leeds', address: 'x');
  final clients = [jane, ann, annLeeds];
  SignedDoc doc(String name) =>
      SignedDoc(id: name, name: name, at: DateTime(2026, 11, 14));

  test('a client is matched by their name in the file name', () {
    expect(matchSignedDoc(doc('Policies - Jane Smith.pdf'), clients), jane);
    expect(matchSignedDoc(doc('Smith, Jane – Policies.pdf'), clients), jane);
    expect(matchSignedDoc(doc('POLICIES_jane_smith.pdf'), clients), jane);
  });

  test('the longest name wins; no name, no match', () {
    expect(matchSignedDoc(doc('Policies Ann Leeds.pdf'), clients), annLeeds);
    expect(matchSignedDoc(doc('Policies Ann Lee.pdf'), clients), ann);
    expect(matchSignedDoc(doc('Policies.pdf'), clients), isNull);
    expect(matchSignedDoc(doc('Policies Jane.pdf'), clients), isNull);
  });

  test('signing makes the client active, unless archived', () {
    final signed = signedWith(jane, doc('x'));
    expect(signed.policiesSignedOn, DateTime(2026, 11, 14));
    expect(signed.status, ClientStatus.active);
    final archived = jane.copyWith(status: ClientStatus.archived);
    expect(signedWith(archived, doc('x')).status, ClientStatus.archived);
  });
}
