import 'package:flutter_test/flutter_test.dart';
import 'package:mileage_log/models/app_settings.dart';
import 'package:mileage_log/models/place.dart';
import 'package:mileage_log/models/saved_address.dart';
import 'package:mileage_log/models/trip.dart';
import 'package:mileage_log/services/local_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('addresses, trips and settings survive a save and reload', () async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());

    final address = SavedAddress(
      id: 'a1',
      hourlyRate: 82.5,
      policiesSignedOn: DateTime(2026, 11, 3),
      name: 'Clinic',
      address: '1 Main St',
      email: 'front@clinic.test',
      phone: '555-0100',
      lat: 1.5,
      lng: -2.5,
      locations: const [
        ClientLocation(
          id: 'l1',
          label: 'Storage unit',
          address: '8 Depot Rd',
          placeId: 'ps',
          lat: 3,
          lng: 4,
        ),
      ],
    );
    final trip = Trip(
      id: 't1',
      date: DateTime(2026, 11, 14, 9, 30),
      from: const Place(label: 'Home', address: '1 Home Rd'),
      to: address.toPlace(),
      miles: 12.3,
      notes: 'checkup',
    );
    const settings = AppSettings(
      home: Place(label: 'Home', address: '1 Home Rd'),
      navApp: NavApp.waze,
      ratePerMile: 0.7,
    );

    await store.saveAddresses([address]);
    await store.saveTrips([trip]);
    await store.saveSettings(settings);

    final reloaded = LocalStore(await SharedPreferences.getInstance());
    final a = reloaded.loadAddresses().single;
    expect(
      (a.id, a.name, a.address, a.email, a.phone, a.lat, a.lng),
      ('a1', 'Clinic', '1 Main St', 'front@clinic.test', '555-0100', 1.5, -2.5),
    );
    expect(a.hourlyRate, 82.5);
    expect(a.policiesSignedOn, DateTime(2026, 11, 3));
    expect(a.isActive, isTrue);
    final l = a.locations.single;
    expect(
      (l.id, l.label, l.address, l.placeId, l.lat, l.lng),
      ('l1', 'Storage unit', '8 Depot Rd', 'ps', 3.0, 4.0),
    );

    final t = reloaded.loadTrips().single;
    expect(
      (t.id, t.date, t.from, t.to, t.miles, t.notes),
      (trip.id, trip.date, trip.from, trip.to, 12.3, 'checkup'),
    );

    final s = reloaded.loadSettings();
    expect(
      (s.home, s.navApp, s.ratePerMile),
      (settings.home, NavApp.waze, 0.7),
    );
  });

  test('empty store returns defaults', () async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    expect(store.loadAddresses(), isEmpty);
    expect(store.loadTrips(), isEmpty);
    expect(store.loadSettings().navApp, NavApp.googleMaps);
  });

  test('clients default to \$75/hour and pending; defaults stay out of '
      'saved data', () {
    final old = SavedAddress.fromJson({
      'id': 'x',
      'name': 'Old',
      'address': '5 Typed St',
    });
    expect(old.hourlyRate, 75);
    expect(old.isActive, isFalse);
    expect(old.toJson().containsKey('hourlyRate'), isFalse);
    expect(old.toJson().containsKey('policiesSignedOn'), isFalse);

    final signed = old.copyWith(policiesSignedOn: DateTime(2026, 1, 9));
    expect(signed.toJson()['policiesSignedOn'], '2026-01-09');
    expect(signed.copyWith(clearPoliciesSigned: true).isActive, isFalse);
  });

  test('client status: older clients derive it; set ones are saved', () {
    final old = SavedAddress.fromJson({
      'id': 'x',
      'name': 'Old',
      'address': '5 Typed St',
    });
    expect(old.status, ClientStatus.policyDoc);
    expect(
      old.copyWith(policiesSignedOn: DateTime(2026, 1, 9)).status,
      ClientStatus.active,
    );
    expect(old.toJson().containsKey('status'), isFalse);

    final booked = old.copyWith(
      status: ClientStatus.consultation,
      consultationOn: DateTime(2026, 2, 3),
    );
    final back = SavedAddress.fromJson(booked.toJson());
    expect(back.status, ClientStatus.consultation);
    expect(back.consultationOn, DateTime(2026, 2, 3));

    final archived = old.copyWith(status: ClientStatus.archived);
    expect(clientStops([archived, old]).map((c) => c.id), [
      'x',
    ], reason: 'only the one not archived');
  });

  group('switching Google account', () {
    const home = Place(label: 'Home', address: '1 Home Rd', placeId: 'h');

    Future<(LocalStore, SharedPreferences)> filledStore() async {
      SharedPreferences.setMockInitialValues({
        'addresses_v1': '[]',
        'trips_v1': '[]',
        'jobs_v1': '[]',
        'client_deletions_v1': '{}',
        'donation_centers_v1': '[]',
        'distance_cache_v1': '{"a>b":3.2}',
        'auto_trips_enabled_v1': true,
        'leads_v1': '[]',
        'lead_states_v1': '{}',
        'policy_signatures_v1': '[]',
        'policy_signature_decisions_v1': '{}',
        'calendars_shown_v1': '[]',
        'other_device_jobs_v1': '{}',
        'styled_sheet_id_v6': 'old-sheet',
        'data_account_v1': 'test@example.com',
        LocalStore.manualPaymentsKey: '{}',
        LocalStore.expensesKey: '{}',
        LocalStore.clubSeatsKey: '{}',
        LocalStore.clubRegistrationsKey: '[]',
        LocalStore.recordsSheetKey: 'old-sheet',
        LocalStore.ledgerWrittenKey: 'old-sheet|1',
      });
      final prefs = await SharedPreferences.getInstance();
      final store = LocalStore(prefs);
      await store.saveSettings(
        const AppSettings(home: home, spreadsheetId: 'old-sheet')
            .stamped(SyncedField.spreadsheetId, DateTime.utc(2026))
            .stamped(SyncedField.home, DateTime.utc(2026)),
      );
      return (store, prefs);
    }

    const accountKeys = [
      'leads_v1',
      'lead_states_v1',
      'policy_signatures_v1',
      'policy_signature_decisions_v1',
      'calendars_shown_v1',
      'other_device_jobs_v1',
      'styled_sheet_id_v6',
      'data_account_v1',
      LocalStore.clubSeatsKey,
      LocalStore.clubRegistrationsKey,
      LocalStore.recordsSheetKey,
      LocalStore.ledgerWrittenKey,
    ];
    const dataKeys = [
      'addresses_v1',
      'trips_v1',
      'jobs_v1',
      'client_deletions_v1',
      LocalStore.manualPaymentsKey,
      LocalStore.expensesKey,
    ];
    const alwaysKept = [
      'donation_centers_v1',
      'distance_cache_v1',
      'auto_trips_enabled_v1',
    ];

    void expectSettingsReset(LocalStore store) {
      final s = store.loadSettings();
      expect(s.spreadsheetId, isNull);
      expect(s.changedAt.containsKey(SyncedField.spreadsheetId), isFalse);
      expect(s.home, home);
      expect(s.changedAt.containsKey(SyncedField.home), isTrue);
    }

    test('starting fresh forgets the account and erases the data', () async {
      final (store, prefs) = await filledStore();
      await store.forgetAccount(keepData: false);
      for (final k in [...accountKeys, ...dataKeys]) {
        expect(prefs.containsKey(k), isFalse, reason: k);
      }
      for (final k in alwaysKept) {
        expect(prefs.containsKey(k), isTrue, reason: k);
      }
      expectSettingsReset(store);
    });

    test('keeping data forgets only the account', () async {
      final (store, prefs) = await filledStore();
      await store.forgetAccount(keepData: true);
      for (final k in accountKeys) {
        expect(prefs.containsKey(k), isFalse, reason: k);
      }
      for (final k in [...dataKeys, ...alwaysKept]) {
        expect(prefs.containsKey(k), isTrue, reason: k);
      }
      expectSettingsReset(store);
    });
  });
}
