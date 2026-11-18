import 'package:flutter_test/flutter_test.dart';
import 'package:mileage_log/models/saved_address.dart';

void main() {
  final start = DateTime(2026, 11, 18, 9);

  test('a booked session bills its length at the hourly rate', () {
    final s = ScheduledJob(
      id: 's',
      start: start,
      end: start.add(const Duration(hours: 2, minutes: 30)),
    );
    expect(s.billFor(75), 187.5);
    expect(s.billFor(82.5), 206.25);
  });

  test('sessions booked before end times bill nothing', () {
    expect(ScheduledJob(id: 's', start: start).billFor(75), isNull);
  });

  test('end times and notes survive syncing', () {
    final c = SavedAddress(
      id: 'c',
      name: 'Clinic',
      address: '2 Main St',
      notes: 'Gate code 1234',
      scheduled: [
        ScheduledJob(
          id: 's',
          start: start,
          end: start.add(const Duration(hours: 3)),
        ),
      ],
    );
    final back = SavedAddress.fromJson(c.toJson());
    expect(back.notes, 'Gate code 1234');
    expect(back.scheduled.single.end, DateTime(2026, 11, 18, 12));
    // Clients without notes sync unchanged.
    expect(
      const SavedAddress(id: 'd', name: 'D', address: 'x').toJson(),
      isNot(contains('notes')),
    );
  });

  test('removing the first address makes the next one first', () {
    const c = SavedAddress(
      id: 'c',
      name: 'Clinic',
      address: '2 Main St',
      placeId: 'p1',
      addressLabel: 'Home',
      locations: [
        ClientLocation(
          id: 's',
          label: 'Storage unit',
          address: '8 Depot Rd',
          placeId: 'p2',
        ),
      ],
    );
    final rest = c.withAddresses(c.allAddresses.skip(1).toList());
    expect(rest.address, '8 Depot Rd');
    expect(rest.addressLabel, 'Storage unit');
    expect(rest.placeId, 'p2');
    expect(rest.locations, isEmpty);
  });

  test('billing status and payment method survive syncing', () {
    const c = SavedAddress(
      id: 'c',
      name: 'Clinic',
      address: '2 Main St',
      billing: {
        's1': SessionBilling(
          status: BillingStatus.paid,
          method: PaymentMethod.stripeKlarna,
        ),
        's2': SessionBilling(status: BillingStatus.billed),
      },
      contacts: [ClientContact(id: 'p', name: 'Pat', phone: '555')],
    );
    final back = SavedAddress.fromJson(c.toJson());
    expect(back.billing, c.billing);
    expect(back.contacts.single.name, 'Pat');
  });
}
