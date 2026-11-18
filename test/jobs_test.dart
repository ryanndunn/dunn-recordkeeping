import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mileage_log/models/app_settings.dart';
import 'package:mileage_log/models/job.dart';
import 'package:mileage_log/models/place.dart';
import 'package:mileage_log/models/saved_address.dart';
import 'package:mileage_log/models/trip.dart';
import 'package:mileage_log/services/auto_trip.dart';
import 'package:mileage_log/services/jobs.dart';
import 'package:mileage_log/services/local_store.dart';
import 'package:mileage_log/services/places_service.dart';
import 'package:mileage_log/services/stop_detector.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

const home = Place(
  label: 'Home',
  address: '1 Home Rd',
  placeId: 'h',
  lat: 40,
  lng: -89,
);
const clinic = SavedAddress(
  id: 'c',
  name: 'Clinic',
  address: '2 Main St',
  placeId: 'pc',
  lat: 40.1,
  lng: -89.1,
);
const dentist = SavedAddress(
  id: 'd',
  name: 'Dentist',
  address: '3 Oak Ave',
  placeId: 'pd',
  lat: 40.2,
  lng: -89.2,
);
const goodwill = SavedAddress(
  id: 'g',
  name: 'Goodwill',
  address: '9 Charity Ln',
  placeId: 'pg',
  lat: 40.3,
  lng: -89.3,
);
const gas = Place(
  label: 'Shell',
  address: '5 Fuel Rd',
  placeId: 'shell',
  lat: 40.4,
  lng: -89.4,
);
const store = Place(
  label: 'Target',
  address: '7 Shop Way',
  placeId: 'target',
  lat: 40.5,
  lng: -89.5,
);

final morning = DateTime(2026, 11, 17, 9);
Duration _m(int minutes) => Duration(minutes: minutes);

/// One phone: its storage, the trip inbox, and a drive of 15 miles.
class Phone {
  Phone._(this.store, this.inbox);

  final LocalStore store;
  final AutoTripInbox inbox;
  var _ids = 0;

  static Future<Phone> create({Place? homePlace = home}) async {
    SharedPreferences.setMockInitialValues({
      'settings_v1': jsonEncode(AppSettings(home: homePlace).toJson()),
    });
    final prefs = await SharedPreferences.getInstance();
    final s = LocalStore(prefs);
    await s.saveAddresses([clinic, dentist]);
    await s.saveDonationCenters([goodwill]);
    return Phone._(s, AutoTripInbox(prefs));
  }

  Future<StopOutcome> stop(StopKind kind, Place place, DateTime at) =>
      recordStop(
        store: store,
        inbox: inbox,
        distance: FakeDistanceService(miles: 15),
        kind: kind,
        place: place,
        arrivedAt: at,
        newId: () => 'id${_ids++}',
      );

  Future<StopOutcome> client(SavedAddress c, DateTime at) =>
      stop(StopKind.client, c.toPlace(), at);

  Future<List<Trip>> trips() async => [
    for (final e in await inbox.load()) e.trip,
  ];

  List<Job> get jobs => store.loadJobs();
}

String route(Trip t) => '${t.from.label} → ${t.to.label}';

void main() {
  group('jobs', () {
    test('a drive from home to a donation center is not a job', () async {
      final phone = await Phone.create();
      final out = await phone.stop(
        StopKind.donation,
        goodwill.toPlace(),
        morning,
      );
      expect(out.trip, isNull);
      expect(await phone.trips(), isEmpty);
      expect(phone.jobs, isEmpty);
    });

    test('arriving at a client starts a session at the arrival', () async {
      final phone = await Phone.create();
      await phone.store.setLastDeparture(PlaceVisit(home, morning));
      final out = await phone.client(clinic, morning.add(_m(25)));

      expect(route(out.trip!), 'Home → Clinic');
      final job = phone.jobs.single;
      expect(job.isActive, isTrue);
      expect(
        job.start,
        morning.add(_m(25)),
        reason: 'the drive there is mileage, not session time',
      );
      expect(job.atClient, isTrue);
      expect(job.clients, ['Clinic']);
      expect(out.startedJob?.id, job.id);
    });

    test('the session ends when you leave the last client; the drive home '
        'is logged but is not session time', () async {
      final phone = await Phone.create();
      await phone.client(clinic, morning);
      await phone.store.setLastDeparture(
        PlaceVisit(clinic.toPlace(), morning.add(_m(180))),
      );
      final out = await phone.stop(StopKind.home, home, morning.add(_m(200)));
      expect(route(out.trip!), 'Clinic → Home');
      final job = phone.jobs.single;
      expect(job.end, morning.add(_m(180)));
      expect(jobMiles(job, await phone.trips()), 0);
    });

    test('without a departure, leaving is estimated from the drive', () async {
      final phone = await Phone.create();
      await phone.client(clinic, morning);
      await phone.stop(StopKind.home, home, morning.add(_m(180)));
      // 15 miles at 30 mph = 30 minutes.
      expect(phone.jobs.single.end, morning.add(_m(150)));
    });

    test('clients, donation centers and gas stations keep the session going; '
        'any other stop ends it, and that drive is logged', () async {
      final phone = await Phone.create();
      await phone.client(clinic, morning);
      await phone.stop(
        StopKind.donation,
        goodwill.toPlace(),
        morning.add(_m(90)),
      );
      await phone.stop(StopKind.gas, gas, morning.add(_m(120)));
      await phone.client(dentist, morning.add(_m(150)));
      expect(phone.jobs.single.isActive, isTrue);

      await phone.store.setLastDeparture(
        PlaceVisit(dentist.toPlace(), morning.add(_m(280))),
      );
      final out = await phone.stop(StopKind.other, store, morning.add(_m(300)));
      expect(out.endedJob, isNotNull);
      final job = phone.jobs.single;
      expect(job.start, morning);
      expect(job.end, morning.add(_m(280)), reason: 'left the dentist');
      expect(job.clients, ['Clinic', 'Dentist']);
      expect(
        [for (final t in await phone.trips()) route(t)],
        [
          'Home → Clinic',
          'Clinic → Goodwill',
          'Goodwill → Shell',
          'Shell → Dentist',
          'Dentist → Target',
        ],
      );
      // Only the drives between clients.
      expect(jobMiles(job, await phone.trips()), 45);
    });

    test('each client gets their own time in a shared session', () async {
      final phone = await Phone.create();
      await phone.client(clinic, morning);
      await phone.store.setLastDeparture(
        PlaceVisit(clinic.toPlace(), morning.add(_m(120))),
      );
      await phone.client(dentist, morning.add(_m(150)));
      await phone.store.setLastDeparture(
        PlaceVisit(dentist.toPlace(), morning.add(_m(240))),
      );
      await phone.stop(StopKind.home, home, morning.add(_m(270)));
      final job = phone.jobs.single;
      final later = morning.add(const Duration(hours: 12));
      expect(job.timeWith('Clinic', later), _m(120));
      expect(job.timeWith('Dentist', later), _m(90));
      expect(job.end!.difference(job.start), _m(240));
    });

    test('a donation stop after the last client is not session time', () async {
      final phone = await Phone.create();
      await phone.client(clinic, morning);
      await phone.store.setLastDeparture(
        PlaceVisit(clinic.toPlace(), morning.add(_m(120))),
      );
      await phone.stop(
        StopKind.donation,
        goodwill.toPlace(),
        morning.add(_m(140)),
      );
      await phone.stop(StopKind.home, home, morning.add(_m(170)));
      expect(phone.jobs.single.end, morning.add(_m(120)));
    });

    test('leaving a client is remembered for a session left open', () {
      final open = [
        Job(id: 'j', start: morning, lastActivity: morning, atClient: true),
      ];
      final left = applyDeparture(
        jobs: open,
        kind: StopKind.client,
        at: morning.add(_m(90)),
      );
      expect(left.single.leftClientAt, morning.add(_m(90)));
      final closed = closeStaleJobs(left, morning.add(const Duration(days: 1)));
      expect(closed.single.end, morning.add(_m(90)));
      // Leaving home or a donation center changes nothing.
      expect(
        applyDeparture(jobs: open, kind: StopKind.donation, at: morning),
        same(open),
      );
    });

    test('after a job ends, only a client starts the next one', () async {
      final phone = await Phone.create();
      await phone.client(clinic, morning);
      await phone.stop(StopKind.other, store, morning.add(_m(60)));

      // Donation run on its own: not a job, nothing logged.
      final donation = await phone.stop(
        StopKind.donation,
        goodwill.toPlace(),
        morning.add(_m(90)),
      );
      expect(donation.trip, isNull);
      expect(phone.jobs.where((j) => j.isActive), isEmpty);

      // Next client: a new job, starting from where the phone really was.
      final next = await phone.client(dentist, morning.add(_m(120)));
      expect(route(next.trip!), 'Goodwill → Dentist');
      expect(phone.jobs, hasLength(2));
      expect(phone.jobs.last.isActive, isTrue);
    });

    test('arriving home off the job logs nothing', () async {
      final phone = await Phone.create();
      final out = await phone.stop(StopKind.home, home, morning);
      expect(out.trip, isNull);
    });

    test('the same stop reported twice is logged once', () async {
      final phone = await Phone.create();
      await phone.client(clinic, morning);
      final again = await phone.client(clinic, morning.add(_m(10)));
      expect(again.trip, isNull);
      expect(await phone.trips(), hasLength(1));
    });

    test('a job left open overnight is closed at its last stop', () async {
      final phone = await Phone.create();
      await phone.client(clinic, morning);
      final tomorrow = morning.add(const Duration(days: 1));
      await phone.client(dentist, tomorrow);

      final jobs = phone.jobs;
      expect(jobs, hasLength(2));
      expect(jobs.first.end, morning, reason: 'its last stop');
      expect(jobs.last.isActive, isTrue);
      // The new day starts from home.
      expect(route((await phone.trips()).last), 'Home → Dentist');
    });

    test(
      'no home set and nothing logged today: nothing to measure from',
      () async {
        final phone = await Phone.create(homePlace: null);
        final out = await phone.client(clinic, morning);
        expect(out.trip, isNull);
      },
    );
  });

  group('geofences', () {
    final withStorage = clinic.copyWith(
      locations: const [
        ClientLocation(
          id: 's',
          label: 'Storage unit',
          address: '8 Depot Rd',
          placeId: 'ps',
          lat: 3,
          lng: 3,
        ),
      ],
    );

    ({StopKind kind, Place place})? fence(String id) => placeForFence(
      id,
      home: home,
      clientStops: clientStops([withStorage, dentist]),
      donationCenters: [goodwill],
    );

    test('each fence is home, a client address or a donation center', () {
      expect(fence(homeFenceId)?.kind, StopKind.home);
      expect(fence(addressFenceId('d'))?.kind, StopKind.client);
      final storage = fence(addressFenceId('c/s'))!;
      expect(storage.kind, StopKind.client);
      expect(storage.place.label, 'Clinic (Storage unit)');
      expect(fence(donationFenceId('g'))?.kind, StopKind.donation);
    });

    test('a deleted place is ignored', () {
      expect(fence(addressFenceId('gone')), isNull);
      expect(fence(donationFenceId('gone')), isNull);
    });
  });

  group('naming a stop', () {
    const here = Place(
      label: 'Stop',
      address: '40.0, -89.0',
      lat: 40,
      lng: -89,
    );

    test('a gas station nearby keeps the job going', () {
      final found = classifyNearby(here, const [
        NearbyPlace(store, ['store']),
        NearbyPlace(gas, ['gas_station', 'convenience_store']),
      ]);
      expect(found.kind, StopKind.gas);
      expect(found.place, gas);
    });

    test('otherwise the stop is named after the nearest place', () {
      final found = classifyNearby(here, const [
        NearbyPlace(store, ['department_store']),
      ]);
      expect(found.kind, StopKind.other);
      expect(found.place.label, 'Target');
    });

    test('with nothing nearby the stop keeps its position', () {
      expect(classifyNearby(here, const []).place, here);
    });

    test('a stop near a saved place is that place', () {
      final near = classifyKnownPlace(
        const Place(label: 'Stop', address: 'x', lat: 40.3003, lng: -89.3),
        home: home,
        clientStops: [clinic],
        donationCenters: [goodwill],
      );
      expect(near.kind, StopKind.donation);
      expect(near.place.label, 'Goodwill');
    });
  });

  group('stop detector', () {
    // ~0.001° latitude is ~111 m.
    test('staying put 5 minutes is a stop, reported once', () {
      final d = StopDetector();
      d.startStoppedAt(40, -89); // At the client where the job began.
      expect(d.add(40.0005, -89, morning), isNull, reason: 'still there');

      // Drive away, then park.
      var t = morning.add(_m(1));
      expect(d.add(40.01, -89, t), isNull);
      expect(d.add(40.02, -89, t = t.add(_m(1))), isNull);
      final parkedAt = t.add(_m(1));
      expect(d.add(40.03, -89, parkedAt), isNull);
      expect(d.add(40.0302, -89, parkedAt.add(_m(2))), isNull);
      final stop = d.add(40.0301, -89, parkedAt.add(_m(5)));
      expect(stop, isNotNull);
      expect(stop!.arrivedAt, parkedAt);
      expect(d.add(40.0301, -89, parkedAt.add(_m(20))), isNull);
    });

    test('stop-and-go traffic is not a stop', () {
      final d = StopDetector();
      var t = morning;
      for (var i = 0; i < 20; i++) {
        // Moves ~220 m every 2 minutes.
        expect(d.add(40 + i * 0.002, -89, t), isNull);
        t = t.add(_m(2));
      }
    });
  });
}
