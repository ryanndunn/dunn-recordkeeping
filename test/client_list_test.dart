import 'package:flutter_test/flutter_test.dart';
import 'package:mileage_log/models/saved_address.dart';
import 'package:mileage_log/services/client_list.dart';

final jane = SavedAddress(
  id: 'j',
  name: 'Jane Smith',
  address: '9 Elm St, Peoria, IL',
  phone: '(309) 555-0142',
  email: 'jane@example.com',
  locations: const [
    ClientLocation(id: 's', label: 'Storage unit', address: '8 Depot Rd'),
  ],
  storedStatus: ClientStatus.active,
  updatedAt: DateTime.utc(2026, 11, 1),
  scheduled: [ScheduledJob(id: 'a', start: DateTime(2026, 11, 25, 9))],
);
final bob = SavedAddress(
  id: 'b',
  name: 'bob Jones',
  address: '2 Oak Ave, Towson, MD',
  storedStatus: ClientStatus.newClient,
  updatedAt: DateTime.utc(2026, 11, 10),
  scheduled: [
    ScheduledJob(id: 'old', start: DateTime(2026, 11, 2, 9)),
    ScheduledJob(id: 'b1', start: DateTime(2026, 11, 20, 13)),
  ],
);
const cara = SavedAddress(
  id: 'c',
  name: 'Cara Lee',
  address: '5 Pine Rd, Towson, MD',
  storedStatus: ClientStatus.consultation,
);

void main() {
  final now = DateTime(2026, 11, 17);

  test('search looks at name, addresses, email and phone', () {
    bool m(String q) => clientMatches(jane, q);
    expect(m(''), isTrue);
    expect(m('jane'), isTrue);
    expect(m('SMITH'), isTrue);
    expect(m('elm st'), isTrue, reason: 'every word, anywhere');
    expect(m('storage'), isTrue);
    expect(m('depot'), isTrue);
    expect(m('example.com'), isTrue);
    expect(m('5550142'), isTrue, reason: 'phone by digits');
    expect(m('555-0142'), isTrue);
    expect(m('towson'), isFalse);
    expect(m('jane towson'), isFalse);
  });

  List<String> names(ClientSort s) => [
    for (final c in sortClients([jane, bob, cara], s, now)) c.name,
  ];

  test('sorts by name either way, ignoring case', () {
    expect(names(ClientSort.nameAZ), ['bob Jones', 'Cara Lee', 'Jane Smith']);
    expect(names(ClientSort.nameZA), ['Jane Smith', 'Cara Lee', 'bob Jones']);
  });

  test('sorts by status, from New to Archived', () {
    expect(names(ClientSort.status), ['bob Jones', 'Cara Lee', 'Jane Smith']);
  });

  test('sorts by next scheduled job; past bookings and none go last', () {
    expect(names(ClientSort.nextJob), ['bob Jones', 'Jane Smith', 'Cara Lee']);
  });

  test('sorts by most recently changed', () {
    expect(names(ClientSort.recent), ['bob Jones', 'Jane Smith', 'Cara Lee']);
  });

  test('a large property is kept on each address and when reordered', () {
    final big = jane.withAddresses([
      jane.allAddresses.last.copyWith(large: true),
      jane.allAddresses.first,
    ]);
    expect(big.largeSite, isTrue, reason: 'the storage unit is first now');
    expect(big.locations.single.large, isFalse);
    expect(big.stops.first.largeSite, isTrue);
    expect(siteRadius(big.stops.first), largeSiteMeters);
    expect(siteRadius(big.stops.last), normalSiteMeters);

    final again = SavedAddress.fromJson(big.toJson());
    expect(again.largeSite, isTrue);
    expect(again.allAddresses.first.large, isTrue);
    expect(SavedAddress.fromJson(jane.toJson()).largeSite, isFalse);
    expect(jane.toJson().containsKey('largeSite'), isFalse);
  });
}
