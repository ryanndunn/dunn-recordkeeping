import 'package:flutter_test/flutter_test.dart';
import 'package:mileage_log/models/saved_address.dart';
import 'package:mileage_log/services/address_matcher.dart';

void main() {
  const matcher = AddressMatcher();

  const clinic = SavedAddress(
    id: '1',
    name: 'Main St Clinic',
    address: '123 Main Street, Suite 4, Springfield, IL 62701, USA',
  );
  const patel = SavedAddress(
    id: '2',
    name: 'Dr. Patel',
    address: '900 North Oak Avenue, Springfield, IL 62702',
    placeId: 'place-patel',
    lat: 39.8000,
    lng: -89.6500,
  );
  const otherMain = SavedAddress(
    id: '3',
    name: 'Chicago Office',
    address: '123 Main St, Chicago, IL 60601',
  );
  final saved = [clinic, patel];

  group('normalize', () {
    test('abbreviates street words and drops punctuation and country', () {
      expect(
        AddressMatcher.normalize('123 Main Street, Suite 4, Springfield, USA'),
        '123 main st ste 4 springfield',
      );
      expect(AddressMatcher.normalize('900 N. Oak Ave.'), '900 n oak ave');
    });

    test('does not chop "usa" out of the middle of a word', () {
      expect(AddressMatcher.normalize('10 Tusa Rd'), '10 tusa rd');
    });
  });

  group('match', () {
    test('matches by place ID first', () {
      expect(
        matcher.match(
          const AddressQuery(text: 'anything', placeId: 'place-patel'),
          saved,
        ),
        patel,
      );
    });

    test('matches by saved name, ignoring case and punctuation', () {
      expect(matcher.match(const AddressQuery(text: 'dr patel'), saved), patel);
    });

    test('matches the same address written differently', () {
      expect(
        matcher.match(
          const AddressQuery(text: '123 Main St Ste 4, Springfield, IL 62701'),
          saved,
        ),
        clinic,
      );
    });

    test('matches a typed street line when only one saved address fits', () {
      expect(
        matcher.match(const AddressQuery(text: '900 N Oak Ave'), saved),
        patel,
      );
    });

    test('does not guess when a street line fits two saved addresses', () {
      expect(
        matcher.match(const AddressQuery(text: '123 Main St'), [
          clinic,
          otherMain,
        ]),
        isNull,
      );
    });

    test('does not treat "123 Main" as a prefix of "1234 Main"', () {
      const far = SavedAddress(
        id: '9',
        name: 'Far',
        address: '1234 Main St, Springfield',
      );
      expect(
        matcher.match(const AddressQuery(text: '123 Main'), [far]),
        isNull,
      );
    });

    test('matches by coordinates within 75 m', () {
      // About 40 m north of Dr. Patel.
      expect(
        matcher.match(
          const AddressQuery(text: 'somewhere', lat: 39.80036, lng: -89.65),
          saved,
        ),
        patel,
      );
    });

    test('rejects coordinates farther than 75 m', () {
      // About 150 m north.
      expect(
        matcher.match(
          const AddressQuery(text: 'somewhere', lat: 39.80135, lng: -89.65),
          saved,
        ),
        isNull,
      );
    });

    test('returns null for an unknown address', () {
      expect(
        matcher.match(const AddressQuery(text: '1 Elm St, Peoria'), saved),
        isNull,
      );
    });
  });

  group('suggestions', () {
    test('name prefix ranks above address match', () {
      const mainStreetDentist = SavedAddress(
        id: '4',
        name: 'Dentist',
        address: '55 Main St, Springfield',
      );
      final result = matcher.suggestions('main', [
        mainStreetDentist,
        clinic,
        patel,
      ]);
      expect(result, [clinic, mainStreetDentist]);
    });

    test('empty text lists everything alphabetically', () {
      expect(matcher.suggestions('', saved), [patel, clinic]);
    });
  });
}
