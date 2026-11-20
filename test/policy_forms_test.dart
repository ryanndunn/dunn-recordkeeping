import 'package:flutter_test/flutter_test.dart';
import 'package:mileage_log/models/saved_address.dart';
import 'package:mileage_log/services/ledger.dart';
import 'package:mileage_log/services/policy_forms.dart';

/// Questions from the real policies form (trimmed).
const _pay =
    'I agree to pay the hourly rate of \$75/hour via cash, check, credit '
    'card, or Zelle® prior to the session.';
const _travel =
    'I agree to pay a travel fee at the same rate of \$75/hour (\$1.25 per '
    'minute) for estimated travel time that is more than 30 minutes each '
    'way from Parkville, Maryland.';
const _photos =
    'I give permission for photos of my space without identifying '
    'information to be used on Sarah Dunn Organizer, LLC \'s website.';
const _sign =
    'The typing of my name will serve as my legally binding signature.';

void main() {
  const standard = ['Timestamp', 'Email', _pay, _travel, _photos, _sign];
  const noPayment = ['Timestamp', 'Email', _photos, _sign, 'Today\'s Date'];

  group('reading a policies form', () {
    test('recognized by its signature question, not mistaken for others', () {
      expect(formKindOf(standard), FormKind.policy);
      expect(formKindOf(noPayment), FormKind.policy);
      expect(
        formKindOf(['Timestamp', 'Name', 'Phone number']),
        FormKind.contact,
      );
      expect(formKindOf(['Timestamp', 'Email Address', 'Name']), FormKind.club);
    });

    test(
      'the rate comes from the hourly-rate question, not the travel fee',
      () {
        expect(policyFormRate(standard), 75);
        expect(
          policyFormRate([
            'I agree to pay the hourly rate of \$82.50/hour prior to the session.',
          ]),
          82.5,
        );
        expect(policyFormRate(noPayment), isNull);
        expect(policyFormRate(['Timestamp', _travel]), isNull);
        expect(policyFormIncludesPayment(standard), isTrue);
        expect(policyFormIncludesPayment(noPayment), isFalse);
        expect(policyFormIncludesPayment(['Timestamp', _travel]), isFalse);
      },
    );

    test('responses: email, typed name, rate and the other answers', () {
      final sigs = parsePolicyResponses('Form Responses 3', [
        standard,
        [
          '11/16/2026 18:30:00',
          ' Dan@Example.com ',
          'Yes',
          'Yes',
          'No',
          'Dan Lee',
        ],
        ['11/14/2026 9:00:00', '', 'Yes', 'Yes', '', ''],
        ['11/15/2026 9:00:00', 'amy@example.com', 'Yes', 'Yes', 'Yes', 'Amy'],
      ]);
      expect(sigs.map((s) => s.signedName), ['Amy', 'Dan Lee']);
      final dan = sigs.last;
      expect(dan.email, 'dan@example.com');
      expect(dan.form, 'Form Responses 3');
      expect(dan.at, DateTime(2026, 11, 16, 18, 30));
      expect(dan.rate, 75);
      expect(dan.includesPayment, isTrue);
      expect(dan.answers.map((a) => a.answer), ['Yes', 'Yes', 'No']);
      expect(dan.answers.last.question, _photos);
      expect(PolicySignature.fromJson(dan.toJson()).toJson(), dan.toJson());
    });
  });

  group('whose signature', () {
    SavedAddress client(
      String id,
      String name, {
      String email = '',
      List<ClientContact> contacts = const [],
    }) => SavedAddress(
      id: id,
      name: name,
      address: '1 Main St',
      email: email,
      contacts: contacts,
    );
    PolicySignature sig({String email = '', String name = ''}) =>
        PolicySignature(
          id: 'x',
          at: DateTime(2026),
          form: 'f',
          email: email,
          signedName: name,
        );

    final jane = client('j', 'Jane Smith', email: 'jane@example.com');
    final carol = client(
      'c',
      'Carol Lee',
      contacts: const [
        ClientContact(
          id: 'p',
          name: 'Dan Lee',
          email: 'dan@example.com',
          label: 'Pays',
        ),
      ],
    );
    final clients = [jane, carol];

    test('by email first, the client\'s or a contact\'s', () {
      expect(
        matchSignature(sig(email: 'JANE@example.com', name: 'J'), clients),
        (client: jane, contactId: null),
      );
      expect(
        matchSignature(
          sig(email: 'dan@example.com', name: 'Jane Smith'),
          clients,
        ),
        (client: carol, contactId: 'p'),
      );
    });

    test('then by typed name, in any order', () {
      expect(
        matchSignature(sig(email: 'new@x.com', name: 'smith, jane'), clients),
        (client: jane, contactId: null),
      );
      expect(matchSignature(sig(name: 'Dan  Lee'), clients), (
        client: carol,
        contactId: 'p',
      ));
      expect(matchSignature(sig(name: 'Jane'), clients), isNull);
      expect(matchSignature(sig(name: 'Somebody Else'), clients), isNull);
    });

    test('two clients with the same name: nobody', () {
      final twin = client('t', 'Jane Smith');
      expect(matchSignature(sig(name: 'Jane Smith'), [jane, twin]), isNull);
    });
  });

  group('signed when', () {
    PolicySignature s(String id, int day, {bool pays = false, double? rate}) =>
        PolicySignature(
          id: id,
          at: DateTime(2026, 11, day, 12),
          form: 'f',
          includesPayment: pays,
          rate: rate,
        );

    const decided = SignatureDecision(clientId: 'c');
    SignatureDecision by(String contact) =>
        SignatureDecision(clientId: 'c', contactId: contact);
    SavedAddress client({
      bool primarySigns = true,
      Set<String> contactsWhoSign = const {},
    }) => SavedAddress(
      id: 'c',
      name: 'Carol Lee',
      address: 'a',
      primarySigns: primarySigns,
      contacts: [
        for (final id in ['p', 'q'])
          ClientContact(
            id: id,
            name: id,
            signsPolicies: contactsWhoSign.contains(id),
          ),
      ],
    );

    test('by default, the client signs a form agreeing to pay', () {
      final c = client();
      expect(c.policySigners, {null});
      final p = policyProgressOf(
        c,
        [s('a', 3, pays: true, rate: 75)],
        {'a': decided},
      );
      expect(p.complete, isTrue);
      expect(p.completedAt, DateTime(2026, 11, 3, 12));
      expect(p.rate, 75);
    });

    test('someone else pays: both forms needed, done on the later one', () {
      final c = client();
      final mine = s('a', 5);
      final payer = s('b', 3, pays: true, rate: 90);

      final onlyClient = policyProgressOf(c, [mine], {'a': decided});
      expect(onlyClient.hasSigned(null), isTrue);
      expect(onlyClient.complete, isFalse, reason: 'nobody agreed to pay');

      final onlyPayer = policyProgressOf(c, [payer], {'b': by('p')});
      expect(onlyPayer.paymentSigned, isTrue);
      expect(onlyPayer.missing, [null]);
      expect(onlyPayer.complete, isFalse);

      final both = policyProgressOf(
        c,
        [payer, mine],
        {'a': decided, 'b': by('p')},
      );
      expect(both.complete, isTrue);
      expect(both.completedAt, DateTime(2026, 11, 5, 12));
      expect(both.rate, 90);
    });

    test('several people need to sign: waits for all of them', () {
      final c = client(contactsWhoSign: {'p', 'q'});
      expect(c.policySigners, {null, 'p', 'q'});
      final sigs = [s('a', 2, pays: true), s('b', 4), s('d', 7)];
      final two = policyProgressOf(c, sigs.take(2).toList(), {
        'a': decided,
        'b': by('p'),
      });
      expect(two.missing, ['q']);
      expect(two.complete, isFalse);
      final all = policyProgressOf(c, sigs, {
        'a': decided,
        'b': by('p'),
        'd': by('q'),
      });
      expect(all.complete, isTrue);
      expect(all.completedAt, DateTime(2026, 11, 7, 12));
    });

    test('a client who doesn\'t sign: only the contacts who do', () {
      final c = client(primarySigns: false, contactsWhoSign: {'p'});
      expect(c.policySigners, {'p'});
      final p = policyProgressOf(c, [s('a', 3, pays: true)], {'a': by('p')});
      expect(p.complete, isTrue);
      // Nobody marked at all: someone agreeing to pay is enough.
      final none = client(primarySigns: false);
      expect(none.policySigners, isEmpty);
      expect(
        policyProgressOf(
          none,
          [s('a', 3, pays: true)],
          {'a': by('q')},
        ).complete,
        isTrue,
      );
      expect(policyProgressOf(none, const [], const {}).complete, isFalse);
    });

    test('the flags are saved, and left out at their defaults', () {
      final c = client(primarySigns: false, contactsWhoSign: {'p'});
      final back = SavedAddress.fromJson(c.toJson());
      expect(back.policySigners, {'p'});
      final plain = client().toJson();
      expect(plain.containsKey('primarySigns'), isFalse);
      expect(
        (plain['contacts'] as List).every(
          (x) => !(x as Map).containsKey('signsPolicies'),
        ),
        isTrue,
      );
      expect(client().primaryContact.signsPolicies, isTrue);
    });

    test('other clients\' and ignored responses don\'t count', () {
      final p = policyProgressOf(
        client(),
        [s('a', 1, pays: true), s('b', 2)],
        {
          'a': const SignatureDecision(clientId: 'other'),
          'b': SignatureDecision.ignored,
        },
      );
      expect(p.signatures, isEmpty);
    });

    test('signing sets the date and rate; archived clients stay archived', () {
      const c = SavedAddress(id: 'c', name: 'C', address: 'a');
      final signed = signedWith(c, DateTime(2026, 11, 5, 12), rate: 90);
      expect(signed.policiesSignedOn, DateTime(2026, 11, 5));
      expect(signed.hourlyRate, 90);
      expect(signed.status, ClientStatus.active);
      final archived = signedWith(
        c.copyWith(status: ClientStatus.archived),
        DateTime(2026, 11, 5),
      );
      expect(archived.status, ClientStatus.archived);
      expect(archived.hourlyRate, 75);
    });
  });
}
