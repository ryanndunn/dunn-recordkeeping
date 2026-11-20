import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:mileage_log/features/payments/send_bill_dialog.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:mileage_log/app.dart';
import 'package:mileage_log/models/app_settings.dart';
import 'package:mileage_log/models/job.dart';
import 'package:mileage_log/models/lead.dart';
import 'package:mileage_log/state/leads_provider.dart';
import 'package:mileage_log/models/money.dart';
import 'package:mileage_log/state/money_provider.dart';
import 'package:mileage_log/state/policy_forms_provider.dart';
import 'package:mileage_log/services/client_jobs.dart';
import 'package:mileage_log/services/stripe.dart';
import 'package:mileage_log/state/stripe_provider.dart';
import 'package:mileage_log/models/place.dart';
import 'package:mileage_log/models/saved_address.dart';
import 'package:mileage_log/models/trip.dart';
import 'package:mileage_log/services/distance_service.dart';
import 'package:mileage_log/services/google_account.dart';
import 'package:mileage_log/services/local_store.dart';
import 'package:mileage_log/services/mileage_sheet.dart';
import 'package:mileage_log/services/secret_store.dart';
import 'package:mileage_log/services/settings_sync.dart';
import 'package:mileage_log/state/providers.dart';

import 'fakes.dart';

/// Stands in for the hidden Drive file both devices share.
class FakeRemote implements SettingsRemote {
  SyncDoc? stored;
  int writes = 0;

  @override
  Future<SyncDoc?> read() async =>
      stored == null ? null : decodeDoc(encodeDoc(stored!));

  @override
  Future<void> write(SyncDoc doc) async {
    stored = decodeDoc(encodeDoc(doc));
    writes++;
  }

  @override
  Future<String?> accountEmail() async => 'me@example.com';
}

class FakeAccount implements GoogleAccountService {
  bool signedIn = false;

  /// The account picked at the next sign-in.
  String email = 'me@example.com';

  @override
  Future<GoogleSession?> restore() async =>
      signedIn ? GoogleSession(client: http.Client(), email: email) : null;

  /// The next sign-in is backed out of.
  bool cancelNext = false;

  @override
  Future<GoogleSession> signIn() async {
    if (cancelNext) {
      cancelNext = false;
      throw const GoogleAccountException('Cancelled.', cancelled: true);
    }
    signedIn = true;
    return GoogleSession(client: http.Client(), email: email);
  }

  @override
  Future<void> signOut() async => signedIn = false;

  /// Extra permissions given (calendar).
  final granted = <String>{};

  @override
  Future<http.Client> grantAccess(String scope) async {
    granted.add(scope);
    return http.Client();
  }

  @override
  Future<http.Client?> access(String scope) async =>
      granted.contains(scope) ? http.Client() : null;
}

/// Per-device storage (test SharedPreferences is one shared instance, so
/// it can't stand in for two devices).
class MemoryLocalStore implements LocalStore {
  List<SavedAddress> _addresses = [];
  List<Trip> _trips = [];
  String? _settingsJson;
  final _distances = <String, double>{};
  Set<String> _pendingDeletes = {};
  bool _autoTrips = false;
  String? _email;
  String? _styledSheet;

  @override
  String? get styledSheetId => _styledSheet;
  @override
  Future<void> setStyledSheetId(String id) async => _styledSheet = id;

  @override
  bool get autoTripsEnabled => _autoTrips;
  @override
  Future<void> setAutoTripsEnabled(bool on) async => _autoTrips = on;
  @override
  String? get googleEmail => _email;
  @override
  Future<void> setGoogleEmail(String? email) async => _email = email;

  @override
  Set<String> loadPendingDeletes() => {..._pendingDeletes};
  @override
  Future<void> savePendingDeletes(Set<String> ids) async =>
      _pendingDeletes = {...ids};

  List<SavedAddress> _donations = [];
  Map<String, DateTime> _donationDeletions = {};
  List<Job> _jobs = [];
  PlaceVisit? _lastStop;
  PlaceVisit? _lastDeparture;

  @override
  List<SavedAddress> loadDonationCenters() => [..._donations];
  @override
  Future<void> saveDonationCenters(List<SavedAddress> c) async =>
      _donations = [...c];
  @override
  Map<String, DateTime> loadDonationDeletions() => {..._donationDeletions};
  @override
  Future<void> saveDonationDeletions(Map<String, DateTime> d) async =>
      _donationDeletions = {...d};
  @override
  Future<void> reload() async {}
  String? _sort;
  @override
  String? get clientSort => _sort;

  final _records = <String, String>{};
  @override
  String? recordsRaw(String key) => _records[key];
  @override
  Future<void> setRecordsRaw(String key, String raw) async =>
      _records[key] = raw;

  String? _calendarsShown;
  @override
  String? get calendarsShownRaw => _calendarsShown;
  @override
  Future<void> setCalendarsShownRaw(String raw) async => _calendarsShown = raw;

  String? _signatures;
  String? _signatureDecisions;
  @override
  String? get policySignaturesRaw => _signatures;
  @override
  Future<void> setPolicySignaturesRaw(String raw) async => _signatures = raw;
  @override
  String? get signatureDecisionsRaw => _signatureDecisions;
  @override
  Future<void> setSignatureDecisionsRaw(String raw) async =>
      _signatureDecisions = raw;

  String? _leads;
  String? _leadStates;
  @override
  String? get leadsRaw => _leads;
  @override
  Future<void> setLeadsRaw(String raw) async => _leads = raw;
  @override
  String? get leadStatesRaw => _leadStates;
  @override
  Future<void> setLeadStatesRaw(String raw) async => _leadStates = raw;
  @override
  Future<void> setClientSort(String sort) async => _sort = sort;
  String? _otherJobs;
  @override
  String? get otherDeviceJobsRaw => _otherJobs;
  @override
  Future<void> setOtherDeviceJobsRaw(String raw) async => _otherJobs = raw;
  @override
  List<Job> loadJobs() => [..._jobs];
  @override
  Future<void> saveJobs(List<Job> jobs) async => _jobs = [...jobs];
  @override
  PlaceVisit? get lastStop => _lastStop;
  @override
  Future<void> setLastStop(PlaceVisit v) async => _lastStop = v;
  @override
  PlaceVisit? get lastDeparture => _lastDeparture;
  @override
  Future<void> setLastDeparture(PlaceVisit v) async => _lastDeparture = v;

  Map<String, DateTime> _clientDeletions = {};
  @override
  Map<String, DateTime> loadClientDeletions() => {..._clientDeletions};
  @override
  Future<void> saveClientDeletions(Map<String, DateTime> d) async =>
      _clientDeletions = {...d};

  @override
  List<SavedAddress> loadAddresses() => [..._addresses];
  @override
  Future<void> saveAddresses(List<SavedAddress> a) async => _addresses = [...a];
  @override
  List<Trip> loadTrips() => [..._trips];
  @override
  Future<void> saveTrips(List<Trip> t) async => _trips = [...t];
  @override
  AppSettings loadSettings() => _settingsJson == null
      ? const AppSettings()
      : AppSettings.fromJson(
          jsonDecode(_settingsJson!) as Map<String, dynamic>,
        );
  @override
  Future<void> saveSettings(AppSettings s) async =>
      _settingsJson = jsonEncode(s.toJson());
  String? _stripePayments;
  DateTime? _stripeKeyChanged;
  @override
  String? get stripePaymentsRaw => _stripePayments;
  @override
  Future<void> setStripePaymentsRaw(String? raw) async => _stripePayments = raw;
  @override
  DateTime? get stripeKeyChangedAt => _stripeKeyChanged;
  @override
  Future<void> setStripeKeyChangedAt(DateTime? at) async =>
      _stripeKeyChanged = at;

  String? _dataAccount;
  @override
  String? get dataAccount => _dataAccount;
  @override
  Future<void> setDataAccount(String email) async => _dataAccount = email;

  @override
  Future<void> forgetAccount({required bool keepData}) async {
    final s = loadSettings();
    await saveSettings(
      AppSettings(
        home: s.home,
        navApp: s.navApp,
        ratePerMile: s.ratePerMile,
        bookingUrl: s.bookingUrl,
        changedAt: {...s.changedAt}..remove(SyncedField.spreadsheetId),
      ),
    );
    _dataAccount = null;
    _styledSheet = null;
    _pendingDeletes = {};
    _otherJobs = null;
    _leads = null;
    _leadStates = null;
    _calendarsShown = null;
    _signatures = null;
    _signatureDecisions = null;
    _stripePayments = null;
    _stripeKeyChanged = null;
    for (final k in [
      LocalStore.clubRegistrationsKey,
      LocalStore.clubDecisionsKey,
      LocalStore.recordsSheetKey,
      LocalStore.ledgerWrittenKey,
      LocalStore.stripeDecisionsKey,
      if (!keepData) ...[LocalStore.manualPaymentsKey, LocalStore.expensesKey],
    ]) {
      _records.remove(k);
    }
    if (!keepData) {
      _addresses = [];
      _clientDeletions = {};
      _trips = [];
      _jobs = [];
      _lastStop = null;
      _lastDeparture = null;
    }
  }

  @override
  double? cachedMiles(String key) => _distances[key];
  @override
  Future<void> cacheMiles(String key, double miles) async =>
      _distances[key] = miles;
}

/// Stands in for the user's spreadsheet(s): rows keyed by trip ID.
class FakeSheet implements MileageSheet {
  final sheets = <String, Map<String, Trip>>{};

  /// The linked form's responses tab, per spreadsheet (header first).
  final formResponses = <String, List<List<String>>>{};

  /// A second linked form (Dunn Club sign-ups), per spreadsheet.
  final clubResponses = <String, List<List<String>>>{};

  /// Policies forms' tabs (by tab name), per spreadsheet.
  final policyResponses = <String, Map<String, List<List<String>>>>{};

  @override
  Future<Map<String, List<List<String>>>> readFormTabs(String id) async {
    if (offline) throw const SheetException('offline');
    return {
      'Form Responses 1': ?formResponses[id],
      'Form Responses 2': ?clubResponses[id],
      ...?policyResponses[id],
    };
  }

  /// Spreadsheets made into business records.
  final upgraded = <String>{};

  /// The Payments and Expenses tabs' rows, per spreadsheet.
  final paymentRowsBySheet = <String, List<List<Object>>>{};
  final expenseRowsBySheet = <String, List<List<Object>>>{};
  int ledgerWrites = 0;

  @override
  Future<void> upgradeToRecords(String id) async {
    if (offline) throw const SheetException('offline');
    upgraded.add(id);
  }

  @override
  Future<void> writeLedger(
    String id, {
    required List<List<Object>> payments,
    required List<List<Object>> expenses,
  }) async {
    if (offline) throw const SheetException('offline');
    ledgerWrites++;
    paymentRowsBySheet[id] = payments;
    expenseRowsBySheet[id] = expenses;
  }

  int created = 0;
  bool offline = false;

  @override
  Future<String> create({double? ratePerMile}) async {
    if (offline) throw const SheetException('offline');
    created++;
    final id = 'sheet-$created';
    sheets[id] = {};
    return id;
  }

  @override
  Future<void> addTrips(String id, List<Trip> trips) async {
    if (offline) throw const SheetException('offline');
    final rows = sheets[id];
    if (rows == null) throw const SheetException('gone', missing: true);
    for (final t in trips) {
      rows[t.id] = t;
    }
  }

  @override
  Future<void> deleteTrips(String id, Set<String> tripIds) async {
    if (offline) throw const SheetException('offline');
    final rows = sheets[id];
    if (rows == null) throw const SheetException('gone', missing: true);
    rows.removeWhere((k, _) => tripIds.contains(k));
  }

  /// Job rows by spreadsheet, keyed by job ID (with miles).
  final jobRows = <String, Map<String, JobRecord>>{};

  @override
  Future<void> addJobs(String id, List<JobRecord> jobs) async {
    if (offline) throw const SheetException('offline');
    if (!sheets.containsKey(id)) {
      throw const SheetException('gone', missing: true);
    }
    final rows = jobRows[id] ??= {};
    for (final j in jobs) {
      rows[j.job.id] = j;
    }
  }

  /// Spreadsheet IDs restyled, in order.
  final restyled = <String>[];

  @override
  Future<void> restyle(String id) async {
    if (offline) throw const SheetException('offline');
    if (!sheets.containsKey(id)) {
      throw const SheetException('gone', missing: true);
    }
    restyled.add(id);
  }
}

/// One simulated device: its own storage, the shared remote.
/// Signed PDFs "in Drive".
Future<ProviderContainer> device(
  FakeRemote remote, {
  required DateTime Function() clock,
  FakeSheet? sheet,
  DistanceService? distance,
  FakeAccount? account,

  /// The Drive sync file of whichever account is signed in (default:
  /// [remote]).
  FakeRemote Function()? remoteOf,
  FakeStripe? stripe,
}) async {
  final container = ProviderContainer(
    overrides: [
      localStoreProvider.overrideWithValue(MemoryLocalStore()),
      secretStoreProvider.overrideWithValue(MemorySecretStore()),
      googleAccountServiceProvider.overrideWithValue(account ?? FakeAccount()),
      settingsRemoteFactoryProvider.overrideWithValue(
        (_) => remoteOf?.call() ?? remote,
      ),
      mileageSheetFactoryProvider.overrideWithValue(
        (_) => sheet ?? FakeSheet(),
      ),
      distanceServiceProvider.overrideWithValue(
        distance ?? const DemoDistanceService(),
      ),
      clockProvider.overrideWithValue(clock),
      stripeSourceFactoryProvider.overrideWithValue(
        (key) => (stripe ?? FakeStripe())..keysUsed.add(key),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Stands in for Stripe: the payments it has, and a key it rejects.
class FakeStripe implements StripeSource {
  final payments = <StripePayment>[];
  final keysUsed = <String>[];
  String? rejectKey;
  int reads = 0;

  @override
  Future<List<StripePayment>> paymentsSince(DateTime since) async {
    if (keysUsed.isNotEmpty && keysUsed.last == rejectKey) {
      throw const StripeException('Invalid API Key provided', badKey: true);
    }
    reads++;
    return [
      for (final p in payments)
        if (!p.at.isBefore(since)) p,
    ];
  }

  /// Links made, by ID; false once turned off.
  final links =
      <
        String,
        ({
          double amount,
          String name,
          String clientId,
          String sessionKey,
          bool active,
        })
      >{};

  /// A key that can read but not make links.
  String? readOnlyKey;

  @override
  Future<({String id, String url})> createPaymentLink({
    required double amount,
    required String name,
    required String clientId,
    required String sessionKey,
  }) async {
    if (keysUsed.isNotEmpty && keysUsed.last == readOnlyKey) {
      throw const StripeException(
        'The provided key does not have the required permissions for this '
        'endpoint.',
        badKey: true,
      );
    }
    final id = 'plink_${links.length + 1}';
    links[id] = (
      amount: amount,
      name: name,
      clientId: clientId,
      sessionKey: sessionKey,
      active: true,
    );
    return (id: id, url: 'https://buy.stripe.com/test_$id');
  }

  @override
  Future<void> deactivatePaymentLink(String id) async {
    final l = links[id]!;
    links[id] = (
      amount: l.amount,
      name: l.name,
      clientId: l.clientId,
      sessionKey: l.sessionKey,
      active: false,
    );
  }

  /// Someone pays link [id] on [at], as Stripe reports it.
  void pay(String id, DateTime at, {String email = '', String name = ''}) {
    final l = links[id]!;
    payments.add(
      StripePayment(
        id: 'cs_$id',
        at: at,
        amount: l.amount,
        fee: (l.amount * 0.03 * 100).round() / 100,
        email: email,
        name: name,
        paymentLink: id,
        clientId: l.clientId,
        sessionKey: l.sessionKey,
      ),
    );
  }
}

void main() {
  const home = Place(label: 'Home', address: '1 Home Rd', placeId: 'h');

  group('merge rules', () {
    final t1 = DateTime.utc(2026, 11, 15, 9);
    final t2 = DateTime.utc(2026, 11, 15, 10);

    test('newer change wins field by field', () {
      final local = {
        'apiKey': SyncField('new-key', t2),
        'ratePerMile': SyncField(0.5, t1),
      };
      final remote = {
        'apiKey': SyncField('old-key', t1),
        'ratePerMile': SyncField(0.7, t2),
        'home': SyncField(home.toJson(), t1),
      };
      final merged = mergeDocs(local, remote);
      expect(merged['apiKey']!.value, 'new-key');
      expect(merged['ratePerMile']!.value, 0.7);
      expect(merged['home']!.value, home.toJson());
    });

    test('values from before syncing existed lose to any later change', () {
      final local = docFromLocal(const AppSettings(home: home), 'legacy-key');
      expect(local['home']!.at, legacyTime);
      expect(local['apiKey']!.at, legacyTime);
      // Default nav app with no change time is not offered at all.
      expect(local.containsKey('navApp'), isFalse);

      final merged = mergeDocs(local, {'apiKey': SyncField('their-key', t1)});
      expect(merged['apiKey']!.value, 'their-key');
      expect(merged['home']!.value, home.toJson());
    });

    test('a removed key (null) that is newer removes it elsewhere', () {
      final applied = applyDoc(
        {'apiKey': SyncField(null, t2)},
        AppSettings(changedAt: {'apiKey': t1}),
        'old-key',
      );
      expect(applied.apiKey, isNull);
      expect(applied.apiKeyChanged, isTrue);
    });

    test('clients round-trip through the sync file', () {
      final jane = SavedAddress(
        id: 'j',
        name: 'Jane Smith',
        address: '9 Elm St',
        email: 'jane@example.com',
        phone: '555-0142',
        placeId: 'elm',
        lat: 40.7,
        lng: -89.6,
        updatedAt: t1,
      );
      final doc = decodeDoc(
        encodeDoc(clientDocFromLocal([jane], {'gone': t2})),
      );
      final back = clientsFromDoc(doc);
      final c = back.clients.single;
      expect(
        (c.id, c.name, c.email, c.phone, c.placeId, c.lat, c.updatedAt),
        ('j', 'Jane Smith', 'jane@example.com', '555-0142', 'elm', 40.7, t1),
      );
      expect(back.deletions, {'gone': t2});
    });

    test('the same client added on both devices is kept once', () {
      Map<String, dynamic> jane(String id) => {
        'id': id,
        'name': 'Jane Smith ',
        'address': '9 Elm',
        'placeId': 'elm',
      };
      final doc = dedupeClients({
        'client:a': SyncField(jane('a'), t1),
        'client:b': SyncField(jane('b'), t2),
        'client:c': SyncField({
          'id': 'c',
          'name': 'Bob',
          'address': '9 Elm',
          'placeId': 'elm',
        }, t1),
      });
      // Newest copy kept; the older one is marked deleted after its own
      // change, so it can't come back. A different client at the same
      // place is untouched.
      expect(doc['client:b']!.value, isNotNull);
      expect(doc['client:a']!.value, isNull);
      expect(doc['client:a']!.at.isAfter(t1), isTrue);
      expect(doc['client:c']!.value, isNotNull);
      // Running it again changes nothing.
      expect(docsEqual(dedupeClients(doc), doc), isTrue);
    });

    test('file format round-trips', () {
      final doc = {
        'home': SyncField(home.toJson(), t1),
        'navApp': SyncField('waze', t2),
        'apiKey': SyncField(null, t2),
      };
      expect(docsEqual(decodeDoc(encodeDoc(doc)), doc), isTrue);
    });
  });

  group('two devices', () {
    test(
      'key set on the Mac reaches the phone; phone home reaches the Mac',
      () async {
        final remote = FakeRemote();
        var now = DateTime.utc(2026, 11, 15, 9);
        DateTime clock() => now;

        final mac = await device(remote, clock: clock);
        final phone = await device(remote, clock: clock);

        // Mac: sign in, enter the key.
        await mac.read(syncProvider.notifier).signIn();
        await mac.read(apiKeyProvider.notifier).set('mac-entered-key');
        await mac.read(syncProvider.notifier).syncNow();
        expect(remote.stored!['apiKey']!.value, 'mac-entered-key');

        // Phone: set home first (before signing in), then sign in.
        now = now.add(const Duration(minutes: 5));
        await phone.read(settingsProvider.notifier).setHome(home);
        await phone.read(syncProvider.notifier).signIn();

        expect(phone.read(apiKeyProvider), 'mac-entered-key');
        expect(phone.read(settingsProvider).home, home);
        expect(phone.read(syncProvider).phase, SyncPhase.ready);
        expect(phone.read(syncProvider).email, 'me@example.com');

        // Mac picks up the phone's home on its next sync.
        await mac.read(syncProvider.notifier).syncNow();
        expect(mac.read(settingsProvider).home, home);
        expect(mac.read(apiKeyProvider), 'mac-entered-key');
      },
    );

    test('a later change on either device wins', () async {
      final remote = FakeRemote();
      var now = DateTime.utc(2026, 11, 15, 9);
      DateTime clock() => now;
      final mac = await device(remote, clock: clock);
      final phone = await device(remote, clock: clock);
      await mac.read(syncProvider.notifier).signIn();
      await phone.read(syncProvider.notifier).signIn();

      await mac.read(settingsProvider.notifier).setNavApp(NavApp.waze);
      await mac.read(syncProvider.notifier).syncNow();
      now = now.add(const Duration(minutes: 1));
      await phone.read(settingsProvider.notifier).setRatePerMile(0.7);
      await phone.read(syncProvider.notifier).syncNow();
      now = now.add(const Duration(minutes: 1));
      await mac.read(settingsProvider.notifier).setRatePerMile(0.65);
      await mac.read(syncProvider.notifier).syncNow();
      await phone.read(syncProvider.notifier).syncNow();

      for (final d in [mac, phone]) {
        expect(d.read(settingsProvider).navApp, NavApp.waze);
        expect(d.read(settingsProvider).ratePerMile, 0.65);
      }
    });

    test('nothing is written when already in sync', () async {
      final remote = FakeRemote();
      final mac = await device(remote, clock: () => DateTime.utc(2026, 11, 15));
      await mac.read(syncProvider.notifier).signIn();
      await mac.read(apiKeyProvider.notifier).set('k');
      await mac.read(syncProvider.notifier).syncNow();
      final writes = remote.writes;
      await mac.read(syncProvider.notifier).syncNow();
      expect(remote.writes, writes);
    });

    testWidgets('Settings: sign in shows the account and sync time', (
      tester,
    ) async {
      final remote = FakeRemote();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localStoreProvider.overrideWithValue(MemoryLocalStore()),
            secretStoreProvider.overrideWithValue(MemorySecretStore()),
            googleAccountServiceProvider.overrideWithValue(FakeAccount()),
            settingsRemoteFactoryProvider.overrideWithValue((_) => remote),
            mileageSheetFactoryProvider.overrideWithValue((_) => FakeSheet()),
            placesServiceProvider.overrideWithValue(null),
            distanceServiceProvider.overrideWithValue(
              const DemoDistanceService(),
            ),
          ],
          child: const MileageApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();

      expect(find.text('Sign in with Google'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();

      expect(find.text('me@example.com'), findsOneWidget);
      expect(find.textContaining('Synced at'), findsOneWidget);
      expect(remote.stored, isNotNull);

      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      expect(find.text('Sign in with Google'), findsOneWidget);
    });

    testWidgets('Settings: Switch account asks first, then starts fresh', (
      tester,
    ) async {
      final account = FakeAccount()..email = 'test@example.com';
      final store = MemoryLocalStore();
      await store.saveAddresses([
        const SavedAddress(
          id: 'c1',
          name: 'Pretend Client',
          address: '2 Main St',
        ),
      ]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localStoreProvider.overrideWithValue(store),
            secretStoreProvider.overrideWithValue(MemorySecretStore()),
            googleAccountServiceProvider.overrideWithValue(account),
            settingsRemoteFactoryProvider.overrideWithValue(
              (_) => FakeRemote(),
            ),
            mileageSheetFactoryProvider.overrideWithValue((_) => FakeSheet()),
            placesServiceProvider.overrideWithValue(null),
            distanceServiceProvider.overrideWithValue(
              const DemoDistanceService(),
            ),
          ],
          child: const MileageApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
      await tester.pumpAndSettle();
      expect(find.text('test@example.com'), findsOneWidget);

      await tester.tap(find.text('Switch account'));
      await tester.pumpAndSettle();
      // Nothing happens until a choice is made.
      final go = find.widgetWithText(FilledButton, 'Switch account');
      expect(tester.widget<FilledButton>(go).onPressed, isNull);
      await tester.tap(find.text('Start fresh'));
      await tester.pumpAndSettle();
      account.email = 'business@example.com';
      await tester.tap(find.widgetWithText(FilledButton, 'Erase and switch'));
      await tester.pumpAndSettle();

      expect(find.text('business@example.com'), findsOneWidget);
      expect(store.loadAddresses(), isEmpty);
    });

    test('signing out stops syncing', () async {
      final remote = FakeRemote();
      final mac = await device(remote, clock: () => DateTime.utc(2026, 11, 15));
      await mac.read(syncProvider.notifier).signIn();
      await mac.read(syncProvider.notifier).signOut();
      await mac.read(apiKeyProvider.notifier).set('after-sign-out');
      await mac.read(syncProvider.notifier).syncNow();
      expect(remote.stored?['apiKey']?.value, isNot('after-sign-out'));
      expect(mac.read(syncProvider).phase, SyncPhase.signedOut);
    });
  });

  group('clients on two devices', () {
    const elm = Place(
      label: '9 Elm St',
      address: '9 Elm St, Peoria, IL',
      placeId: 'elm',
      lat: 40.69,
      lng: -89.59,
    );
    const oak = Place(
      label: '5 Oak Ave',
      address: '5 Oak Ave, Peoria, IL',
      placeId: 'oak',
      lat: 40.7,
      lng: -89.6,
    );

    test('donation centers sync too, kept apart from clients', () async {
      final remote = FakeRemote();
      var now = DateTime.utc(2026, 11, 15, 9);
      DateTime clock() => now;
      final mac = await device(remote, clock: clock);
      final phone = await device(remote, clock: clock);
      await mac.read(syncProvider.notifier).signIn();
      await phone.read(syncProvider.notifier).signIn();

      final goodwill = await mac
          .read(donationCentersProvider.notifier)
          .add(name: 'Goodwill', place: elm);
      await mac.read(syncProvider.notifier).syncNow();
      await phone.read(syncProvider.notifier).syncNow();
      expect(phone.read(donationCentersProvider).single.name, 'Goodwill');
      expect(phone.read(addressesProvider), isEmpty);

      now = now.add(const Duration(minutes: 1));
      await phone.read(donationCentersProvider.notifier).remove(goodwill.id);
      await phone.read(syncProvider.notifier).syncNow();
      await mac.read(syncProvider.notifier).syncNow();
      expect(mac.read(donationCentersProvider), isEmpty);
    });

    test('added, edited and deleted clients reach the other device', () async {
      final remote = FakeRemote();
      var now = DateTime.utc(2026, 11, 15, 9);
      DateTime clock() => now;
      final mac = await device(remote, clock: clock);
      final phone = await device(remote, clock: clock);
      await mac.read(syncProvider.notifier).signIn();
      await phone.read(syncProvider.notifier).signIn();

      // Added on the Mac.
      final jane = await mac
          .read(addressesProvider.notifier)
          .add(name: 'Jane Smith', place: elm, phone: '555-0142');
      await mac.read(syncProvider.notifier).syncNow();
      await phone.read(syncProvider.notifier).syncNow();
      final onPhone = phone.read(addressesProvider).single;
      expect(
        (onPhone.id, onPhone.name, onPhone.phone, onPhone.lat),
        (jane.id, 'Jane Smith', '555-0142', 40.69),
      );

      // Edited on the phone.
      now = now.add(const Duration(minutes: 1));
      await phone
          .read(addressesProvider.notifier)
          .replace(onPhone.copyWith(email: 'jane@example.com'));
      await phone.read(syncProvider.notifier).syncNow();
      await mac.read(syncProvider.notifier).syncNow();
      expect(mac.read(addressesProvider).single.email, 'jane@example.com');

      // Deleted on the Mac.
      now = now.add(const Duration(minutes: 1));
      await mac.read(addressesProvider.notifier).remove(jane.id);
      await mac.read(syncProvider.notifier).syncNow();
      await phone.read(syncProvider.notifier).syncNow();
      expect(phone.read(addressesProvider), isEmpty);

      // And it stays deleted after more syncing both ways.
      await mac.read(syncProvider.notifier).syncNow();
      expect(mac.read(addressesProvider), isEmpty);
    });

    test(
      'clients saved on both before syncing are combined, once each',
      () async {
        final remote = FakeRemote();
        final now = DateTime.utc(2026, 11, 15, 9);
        final mac = await device(remote, clock: () => now);
        final phone = await device(
          remote,
          clock: () => now.add(const Duration(minutes: 3)),
        );
        await mac
            .read(addressesProvider.notifier)
            .add(name: 'Jane', place: elm);
        await phone
            .read(addressesProvider.notifier)
            .add(name: 'Jane', place: elm, email: 'jane@example.com');
        await phone
            .read(addressesProvider.notifier)
            .add(name: 'Bob', place: oak);

        await mac.read(syncProvider.notifier).signIn();
        await phone.read(syncProvider.notifier).signIn();
        await mac.read(syncProvider.notifier).syncNow();

        for (final d in [mac, phone]) {
          final clients = d.read(addressesProvider);
          expect(clients.map((c) => c.name), ['Bob', 'Jane']);
          // The newer copy (the phone's, with the email) is the one kept.
          expect(clients.last.email, 'jane@example.com');
        }
      },
    );

    test('a client added here during a sync is not lost', () async {
      final remote = FakeRemote();
      final now = DateTime.utc(2026, 11, 15, 9);
      final mac = await device(remote, clock: () => now);
      await mac.read(syncProvider.notifier).signIn();
      final phone = await device(remote, clock: () => now);
      await phone.read(addressesProvider.notifier).add(name: 'Bob', place: oak);
      await phone.read(syncProvider.notifier).signIn();

      // Mac adds Jane, then a sync brings Bob in: both remain.
      await mac.read(addressesProvider.notifier).add(name: 'Jane', place: elm);
      await mac.read(syncProvider.notifier).syncNow();
      expect(mac.read(addressesProvider).map((c) => c.name), ['Bob', 'Jane']);
      await phone.read(syncProvider.notifier).syncNow();
      expect(phone.read(addressesProvider).map((c) => c.name), ['Bob', 'Jane']);
    });
  });

  group('trips to the spreadsheet', () {
    const clinic = Place(label: 'Clinic', address: '2 Main St', placeId: 'c');
    const dentist = Place(label: 'Dentist', address: '3 Oak Ave', placeId: 'd');
    final now = DateTime(2026, 11, 15, 9);

    test(
      'first sign-in creates one spreadsheet and uploads earlier trips',
      () async {
        final remote = FakeRemote();
        final sheet = FakeSheet();
        final mac = await device(remote, clock: () => now, sheet: sheet);
        await mac.read(settingsProvider.notifier).setHome(home);
        final trip = await mac.read(tripsProvider.notifier).logTripTo(clinic);

        await mac.read(syncProvider.notifier).signIn();

        expect(sheet.created, 1);
        expect(sheet.sheets['sheet-1']!.keys, [trip.id]);
        expect(mac.read(tripsProvider).single.synced, isTrue);
        expect(mac.read(settingsProvider).spreadsheetId, 'sheet-1');
        expect(remote.stored!['spreadsheetId']!.value, 'sheet-1');
        expect(mac.read(syncProvider).phase, SyncPhase.ready);
      },
    );

    test('the second device adds to the same spreadsheet', () async {
      final remote = FakeRemote();
      final sheet = FakeSheet();
      final mac = await device(remote, clock: () => now, sheet: sheet);
      final phone = await device(remote, clock: () => now, sheet: sheet);
      await mac.read(syncProvider.notifier).signIn();
      await phone.read(syncProvider.notifier).signIn();
      expect(sheet.created, 1);
      expect(phone.read(settingsProvider).spreadsheetId, 'sheet-1');

      await phone.read(settingsProvider.notifier).setHome(home);
      final trip = await phone.read(tripsProvider.notifier).logTripTo(dentist);
      await phone.read(syncProvider.notifier).syncNow();
      expect(sheet.sheets['sheet-1']!.keys, contains(trip.id));
    });

    test('an older spreadsheet gets its trip rows restyled once', () async {
      final remote = FakeRemote();
      final sheet = FakeSheet();
      final mac = await device(remote, clock: () => now, sheet: sheet);
      final phone = await device(remote, clock: () => now, sheet: sheet);
      await mac.read(syncProvider.notifier).signIn();
      expect(sheet.restyled, isEmpty, reason: 'new sheets start styled');

      // The phone finds the existing spreadsheet: repair it, once.
      await phone.read(syncProvider.notifier).signIn();
      await phone.read(syncProvider.notifier).syncNow();
      await mac.read(syncProvider.notifier).syncNow();
      expect(sheet.restyled, ['sheet-1']);
    });

    test(
      'deleting an uploaded trip removes its row; Undo brings it back',
      () async {
        final sheet = FakeSheet();
        final mac = await device(FakeRemote(), clock: () => now, sheet: sheet);
        await mac.read(settingsProvider.notifier).setHome(home);
        await mac.read(syncProvider.notifier).signIn();
        final trips = mac.read(tripsProvider.notifier);
        final trip = await trips.logTripTo(clinic);
        await mac.read(syncProvider.notifier).syncNow();
        expect(sheet.sheets['sheet-1']!.keys, [trip.id]);

        await trips.remove(trip.id);
        await mac.read(syncProvider.notifier).syncNow();
        expect(sheet.sheets['sheet-1'], isEmpty);

        await trips.restore(trip);
        expect(mac.read(tripsProvider).single.synced, isFalse);
        await mac.read(syncProvider.notifier).syncNow();
        expect(sheet.sheets['sheet-1']!.keys, [trip.id]);
      },
    );

    test('a finished session goes to the Sessions tab with the miles '
        'between clients', () async {
      const garage = Place(label: 'Garage', address: '4 Elm St', placeId: 'g');
      var t = now;
      final sheet = FakeSheet();
      final mac = await device(
        FakeRemote(),
        clock: () => t,
        sheet: sheet,
        distance: FakeDistanceService(miles: 8),
      );
      await mac.read(settingsProvider.notifier).setHome(home);
      final c = await mac
          .read(addressesProvider.notifier)
          .add(name: 'Clinic', place: clinic);
      final g = await mac
          .read(addressesProvider.notifier)
          .add(name: 'Garage', place: garage);
      await mac.read(syncProvider.notifier).signIn();

      // A trip to a client starts a session; it uploads once it ends.
      await mac.read(tripsProvider.notifier).logTripTo(c.toPlace());
      expect(mac.read(jobsProvider).single.isActive, isTrue);
      await mac.read(syncProvider.notifier).syncNow();
      expect(sheet.jobRows['sheet-1'], isNull, reason: 'still running');

      t = t.add(const Duration(hours: 2));
      await mac.read(tripsProvider.notifier).logTripTo(g.toPlace());
      t = t.add(const Duration(hours: 2));
      await mac.read(tripsProvider.notifier).logTripTo(home);
      expect(mac.read(jobsProvider).single.isActive, isFalse);
      await mac.read(syncProvider.notifier).syncNow();
      final row = sheet.jobRows['sheet-1']!.values.single;
      expect(row.miles, 8, reason: 'Clinic → Garage only');
      expect(row.job.clients, ['Clinic', 'Garage']);
      expect(mac.read(jobsProvider).single.synced, isTrue);
    });

    test(
      'a session recorded on the phone shows on the Mac, uploaded once',
      () async {
        const garage = Place(
          label: 'Garage',
          address: '4 Elm St',
          placeId: 'g',
        );
        var t = now;
        final remote = FakeRemote();
        final sheet = FakeSheet();
        final phone = await device(
          remote,
          clock: () => t,
          sheet: sheet,
          distance: FakeDistanceService(miles: 8),
        );
        final mac = await device(remote, clock: () => t, sheet: sheet);
        await phone.read(syncProvider.notifier).signIn();
        await mac.read(syncProvider.notifier).signIn();

        await phone.read(settingsProvider.notifier).setHome(home);
        final c = await phone
            .read(addressesProvider.notifier)
            .add(name: 'Clinic', place: clinic);
        final g = await phone
            .read(addressesProvider.notifier)
            .add(name: 'Garage', place: garage);
        await phone.read(tripsProvider.notifier).logTripTo(c.toPlace());
        t = t.add(const Duration(hours: 2));
        await phone.read(tripsProvider.notifier).logTripTo(g.toPlace());
        await phone.read(syncProvider.notifier).syncNow();
        await mac.read(syncProvider.notifier).syncNow();

        // Running on the phone: the Mac sees it, but has no trips of its own.
        final onMac = mac.read(allJobSummariesProvider).single;
        expect(onMac.job.isActive, isTrue);
        expect(onMac.miles, 8);
        expect([for (final p in onMac.stops) p.label], ['Clinic', 'Garage']);
        expect(mac.read(jobsProvider), isEmpty);

        // Ended on the phone: the Mac gets the finished session.
        t = t.add(const Duration(hours: 2));
        await phone.read(tripsProvider.notifier).logTripTo(home);
        await phone.read(syncProvider.notifier).syncNow();
        await mac.read(syncProvider.notifier).syncNow();
        final ended = mac.read(allJobSummariesProvider).single;
        expect(ended.job.isActive, isFalse);
        expect(ended.miles, 8);

        // Only the phone uploads it.
        await mac.read(syncProvider.notifier).syncNow();
        expect(sheet.jobRows['sheet-1'], hasLength(1));
        expect(mac.read(jobsProvider), isEmpty);
      },
    );

    test('leads come from the linked form, and what\'s done with them '
        'reaches the other device', () async {
      final remote = FakeRemote();
      final sheet = FakeSheet();
      final phone = await device(remote, clock: () => now, sheet: sheet);
      final mac = await device(remote, clock: () => now, sheet: sheet);
      await phone.read(syncProvider.notifier).signIn();
      await mac.read(syncProvider.notifier).signIn();
      await phone.read(syncProvider.notifier).syncNow();
      await mac.read(syncProvider.notifier).syncNow();

      // No form linked yet.
      expect(phone.read(leadsProvider).linked, isFalse);

      sheet.formResponses['sheet-1'] = [
        ['Timestamp', 'Name', 'Phone number'],
        ['11/17/2026 14:03:22', 'Sam Sample', '555-0199'],
      ];
      await phone.read(syncProvider.notifier).syncNow();
      final lead = phone.read(leadsProvider).leads.single;
      expect(lead.name, 'Sam Sample');
      expect(phone.read(openLeadsProvider), hasLength(1));

      await phone
          .read(leadStatesProvider.notifier)
          .set(lead.id, const LeadState(LeadStatus.dismissed));
      await phone.read(syncProvider.notifier).syncNow();
      await mac.read(syncProvider.notifier).syncNow();
      expect(mac.read(leadsProvider).leads.single.id, lead.id);
      expect(mac.read(openLeadsProvider), isEmpty);
      expect(
        mac.read(leadStatesProvider.notifier).of(lead.id).status,
        LeadStatus.dismissed,
      );
    });

    test('policies form responses mark clients signed, at the agreed rate, '
        'on both devices', () async {
      var t = now;
      final remote = FakeRemote();
      final sheet = FakeSheet();
      final phone = await device(remote, clock: () => t, sheet: sheet);
      final mac = await device(remote, clock: () => t, sheet: sheet);
      await phone.read(syncProvider.notifier).signIn();
      await mac.read(syncProvider.notifier).signIn();
      final clients = phone.read(addressesProvider.notifier);
      final jane = await clients.add(name: 'Jane Smith', place: clinic);
      await clients.replace(jane.copyWith(email: 'Jane@Example.com'));
      final bob = await clients.add(name: 'Bob Jones', place: home);
      final carol = await clients.add(name: 'Carol Lee', place: clinic);
      await phone.read(syncProvider.notifier).syncNow();
      await mac.read(syncProvider.notifier).syncNow();

      List<String> header({double? rate}) => [
        'Timestamp',
        'Email',
        if (rate != null)
          'I agree to pay the hourly rate of \$${rate.toStringAsFixed(0)}'
              '/hour via cash, check, credit card, or Zelle® prior to the '
              'session.',
        'I agree to the cancelation policy',
        'I am requesting donation receipts for taxes.',
        'The typing of my name will serve as my legally binding signature.',
        'Today\'s Date',
      ];
      sheet.policyResponses['sheet-1'] = {
        // The standard form: Jane, by email.
        'Form Responses 3': [
          header(rate: 75),
          [
            '11/14/2026 16:02:00',
            'jane@example.com',
            'Yes',
            'Yes',
            'No',
            'Jane Smith',
            '11/14/2026',
          ],
        ],
        // The $90 form: Bob, by his typed name; and Carol's payer, who
        // isn't a contact yet.
        'Form Responses 4': [
          header(rate: 90),
          [
            '11/15/2026 9:00:00',
            'bobby@example.com',
            'Yes',
            'Yes',
            'Yes',
            'Jones, Bob',
            '11/15/2026',
          ],
          [
            '11/16/2026 18:30:00',
            'dan@example.com',
            'Yes',
            'Yes',
            'No',
            'Dan Lee',
            '11/16/2026',
          ],
        ],
        // The form without payment, for the person worked with: Carol.
        'Form Responses 5': [
          header(),
          [
            '11/16/2026 10:00:00',
            'carol@example.com',
            'Yes',
            'No',
            'Carol Lee',
            '',
          ],
        ],
      };
      t = t.add(const Duration(minutes: 5));
      await phone.read(syncProvider.notifier).syncNow();

      SavedAddress on(ProviderContainer d, String id) =>
          d.read(addressesProvider).firstWhere((c) => c.id == id);

      // Jane signed the standard form: signed, active, $75.
      expect(on(phone, jane.id).policiesSignedOn, DateTime(2026, 11, 14));
      expect(on(phone, jane.id).status, ClientStatus.active);
      expect(on(phone, jane.id).hourlyRate, 75);
      // Bob signed the $90 form: his rate is now $90.
      expect(on(phone, bob.id).policiesSignedOn, DateTime(2026, 11, 15));
      expect(on(phone, bob.id).hourlyRate, 90);
      // Carol signed hers (no payment), but nobody has agreed to pay yet.
      expect(on(phone, carol.id).policiesSignedOn, isNull);
      final carolSoFar = phone.read(policyProgressProvider(carol.id));
      expect(carolSoFar.hasSigned(null), isTrue);
      expect(carolSoFar.paymentSigned, isFalse);
      // Dan (paying for Carol) needs a client picked.
      final dan = phone.read(unmatchedSignaturesProvider).single;
      expect(dan.signedName, 'Dan Lee');
      expect(dan.includesPayment, isTrue);

      // He's Carol's payer, someone new: added as her contact, and now
      // she's signed, on the day the last form came in, at $90.
      t = t.add(const Duration(minutes: 5));
      await phone
          .read(policySignaturesProvider.notifier)
          .assign(dan, carol.id, newContact: true);
      final c = on(phone, carol.id);
      expect(c.contacts.single.name, 'Dan Lee');
      expect(c.contacts.single.email, 'dan@example.com');
      expect(c.contacts.single.label, 'Pays');
      expect(c.policiesSignedOn, DateTime(2026, 11, 16));
      expect(c.hourlyRate, 90);
      expect(phone.read(unmatchedSignaturesProvider), isEmpty);

      // The Mac gets all of it through sync.
      await phone.read(syncProvider.notifier).syncNow();
      await mac.read(syncProvider.notifier).syncNow();
      expect(on(mac, carol.id).policiesSignedOn, DateTime(2026, 11, 16));
      expect(on(mac, bob.id).hourlyRate, 90);
      expect(mac.read(unmatchedSignaturesProvider), isEmpty);
      expect(
        mac.read(signatureDecisionsProvider.notifier).of(dan.id)?.contactId,
        c.contacts.single.id,
      );

      // Marking Jane not signed sticks: her form isn't matched again.
      t = t.add(const Duration(minutes: 5));
      await clients.replace(
        on(phone, jane.id).copyWith(clearPoliciesSigned: true),
      );
      await phone.read(syncProvider.notifier).syncNow();
      expect(on(phone, jane.id).policiesSignedOn, isNull);
    });

    test('unchecking someone who hasn\'t signed completes the client', () async {
      final sheet = FakeSheet();
      final phone = await device(FakeRemote(), clock: () => now, sheet: sheet);
      await phone.read(syncProvider.notifier).signIn();
      final clients = phone.read(addressesProvider.notifier);
      final added = await clients.add(name: 'Ed Park', place: clinic);
      await clients.replace(
        added.copyWith(
          contacts: const [
            ClientContact(
              id: 'kim',
              name: 'Kim Park',
              email: 'kim@example.com',
              label: 'Daughter',
              signsPolicies: true,
            ),
          ],
        ),
      );
      sheet.policyResponses['sheet-1'] = {
        'Form Responses 3': [
          [
            'Timestamp',
            'Email',
            'I agree to pay the hourly rate of \$75/hour.',
            'The typing of my name will serve as my legally binding signature.',
          ],
          ['11/18/2026 10:00:00', 'kim@example.com', 'Yes', 'Kim Park'],
        ],
      };
      await phone.read(syncProvider.notifier).syncNow();
      SavedAddress ed() =>
          phone.read(addressesProvider).firstWhere((c) => c.id == added.id);
      // Kim (his daughter) signed and pays; Ed himself hasn't signed.
      expect(phone.read(policyProgressProvider(added.id)).missing, [null]);
      expect(ed().policiesSignedOn, isNull);

      // Ed doesn't need to sign after all.
      await clients.replace(ed().copyWith(primarySigns: false));
      await phone.read(policySignaturesProvider.notifier).recheck(added.id);
      expect(ed().policiesSignedOn, DateTime(2026, 11, 18));
      expect(ed().status, ClientStatus.active);
    });

    test('Dunn Club sign-ups, payments and expenses reach the other device '
        'and the business records spreadsheet', () async {
      var t = now;
      final remote = FakeRemote();
      final sheet = FakeSheet();
      final phone = await device(remote, clock: () => t, sheet: sheet);
      final mac = await device(remote, clock: () => t, sheet: sheet);
      await phone.read(syncProvider.notifier).signIn();
      await mac.read(syncProvider.notifier).signIn();
      await phone.read(syncProvider.notifier).syncNow();
      expect(sheet.upgraded, {'sheet-1'}, reason: 'made a business record');

      sheet.clubResponses['sheet-1'] = [
        ['Timestamp', 'Email Address'],
        ['10/2/2026 9:00:00', 'sam@example.com'],
        ['11/3/2026 9:00:00', 'sam@example.com'],
      ];
      await phone.read(syncProvider.notifier).syncNow();
      final regs = phone.read(clubRegistrationsProvider);
      expect(regs, hasLength(2));
      expect(phone.read(clubToConfirmProvider).single.id, regs[1].id);
      // Sam is a lead too.
      expect(phone.read(openLeadsProvider).single.email, 'sam@example.com');

      t = t.add(const Duration(minutes: 1));
      await phone
          .read(clubDecisionRecordsProvider.notifier)
          .decide(
            regs[1].id,
            const ClubDecision(ClubStatus.paid, method: PaymentMethod.venmo),
          );
      await mac
          .read(expenseRecordsProvider.notifier)
          .save(
            Expense(
              id: 'e1',
              date: DateTime(2026, 11, 5),
              amount: 12.99,
              category: ExpenseCategory.software,
              vendor: 'Canva',
            ),
          );
      await phone.read(syncProvider.notifier).syncNow();
      await mac.read(syncProvider.notifier).syncNow();
      await phone.read(syncProvider.notifier).syncNow();

      // Both devices have both.
      for (final d in [phone, mac]) {
        expect(d.read(ledgerProvider).single.amount, clubPrice);
        expect(d.read(expensesProvider).single.vendor, 'Canva');
      }
      expect(mac.read(clubToConfirmProvider), isEmpty);
      // The spreadsheet has them, and isn't rewritten when nothing changed.
      expect(sheet.paymentRowsBySheet['sheet-1']!.single[5], clubPrice);
      expect(sheet.expenseRowsBySheet['sheet-1']!.single[1], 'Canva');
      final writes = sheet.ledgerWrites;
      await phone.read(syncProvider.notifier).syncNow();
      expect(sheet.ledgerWrites, writes);
      expect(sheet.upgraded, {'sheet-1'});
    });

    test('Undo before the next sync just cancels the delete', () async {
      final sheet = FakeSheet();
      final mac = await device(FakeRemote(), clock: () => now, sheet: sheet);
      await mac.read(settingsProvider.notifier).setHome(home);
      await mac.read(syncProvider.notifier).signIn();
      final trips = mac.read(tripsProvider.notifier);
      final trip = await trips.logTripTo(clinic);
      await mac.read(syncProvider.notifier).syncNow();

      await trips.remove(trip.id);
      await trips.restore(trip);
      expect(mac.read(tripsProvider).single.synced, isTrue);
      await mac.read(syncProvider.notifier).syncNow();
      expect(sheet.sheets['sheet-1']!.keys, [trip.id]);
    });

    test('offline trips wait, then upload when Google is reachable', () async {
      final sheet = FakeSheet();
      final mac = await device(FakeRemote(), clock: () => now, sheet: sheet);
      await mac.read(settingsProvider.notifier).setHome(home);
      await mac.read(syncProvider.notifier).signIn();

      sheet.offline = true;
      final trip = await mac.read(tripsProvider.notifier).logTripTo(clinic);
      await mac.read(syncProvider.notifier).syncNow();
      expect(mac.read(syncProvider).phase, SyncPhase.error);
      expect(mac.read(syncProvider).message, contains('Trips not uploaded'));
      expect(mac.read(tripsProvider).single.synced, isFalse);

      sheet.offline = false;
      await mac.read(syncProvider.notifier).syncNow();
      expect(mac.read(syncProvider).phase, SyncPhase.ready);
      expect(sheet.sheets['sheet-1']!.keys, [trip.id]);
    });

    test(
      'if the spreadsheet is deleted, a new one gets this device\'s trips',
      () async {
        final sheet = FakeSheet();
        final mac = await device(FakeRemote(), clock: () => now, sheet: sheet);
        await mac.read(settingsProvider.notifier).setHome(home);
        final first = await mac.read(tripsProvider.notifier).logTripTo(clinic);
        await mac.read(syncProvider.notifier).signIn();

        sheet.sheets.remove('sheet-1');
        final second = await mac
            .read(tripsProvider.notifier)
            .logTripTo(dentist);
        await mac.read(syncProvider.notifier).syncNow();

        expect(sheet.created, 2);
        expect(mac.read(settingsProvider).spreadsheetId, 'sheet-2');
        expect(
          sheet.sheets['sheet-2']!.keys,
          unorderedEquals([first.id, second.id]),
        );
      },
    );
  });

  group('switching Google account', () {
    const clinic = Place(label: 'Clinic', address: '2 Main St', placeId: 'c');
    final now = DateTime(2026, 11, 19, 9);

    /// A phone signed in to a test account with a client, a trip, a
    /// payment, home and the Maps key; [remotes] holds each account's
    /// Drive sync file.
    Future<
      ({
        ProviderContainer phone,
        FakeAccount account,
        FakeSheet sheet,
        Map<String, FakeRemote> remotes,
      })
    >
    testPhone() async {
      final account = FakeAccount()..email = 'test@example.com';
      final remotes = <String, FakeRemote>{};
      final sheet = FakeSheet();
      final phone = await device(
        FakeRemote(),
        clock: () => now,
        sheet: sheet,
        account: account,
        remoteOf: () => remotes.putIfAbsent(account.email, FakeRemote.new),
      );
      await phone.read(settingsProvider.notifier).setHome(home);
      await phone.read(apiKeyProvider.notifier).set('maps-key');
      await phone.read(syncProvider.notifier).signIn();
      await phone
          .read(addressesProvider.notifier)
          .add(name: 'Pretend Client', place: clinic);
      await phone.read(tripsProvider.notifier).logTripTo(clinic);
      await phone
          .read(manualPaymentRecordsProvider.notifier)
          .save(ManualPayment(id: 'p1', date: now, amount: 50, from: 'Pat'));
      await phone.read(syncProvider.notifier).syncNow();
      expect(phone.read(settingsProvider).spreadsheetId, 'sheet-1');
      return (phone: phone, account: account, sheet: sheet, remotes: remotes);
    }

    test(
      'starting fresh erases test data and makes a new spreadsheet',
      () async {
        final t = await testPhone();
        await t.phone.read(stripeKeyProvider.notifier).set('rk_test_x');
        t.account.email = 'business@example.com';

        await t.phone
            .read(syncProvider.notifier)
            .switchAccount(keepData: false);

        final p = t.phone;
        expect(p.read(syncProvider).email, 'business@example.com');
        expect(p.read(syncProvider).phase, SyncPhase.ready);
        expect(p.read(addressesProvider), isEmpty);
        // A test Stripe key doesn't come along to the real account.
        expect(p.read(stripeKeyProvider), isNull);
        expect(
          t.remotes['business@example.com']!.stored!.containsKey('stripeKey'),
          isFalse,
        );
        expect(p.read(tripsProvider), isEmpty);
        expect(p.read(manualPaymentsProvider), isEmpty);
        // Not tied to an account: kept.
        expect(p.read(settingsProvider).home, home);
        expect(p.read(apiKeyProvider), 'maps-key');
        // Its own spreadsheet, and nothing of the test account's in its Drive.
        expect(p.read(settingsProvider).spreadsheetId, 'sheet-2');
        final business = t.remotes['business@example.com']!.stored!;
        expect(business['spreadsheetId']!.value, 'sheet-2');
        expect(business.keys.where((k) => k.startsWith('client:')), isEmpty);
        expect(business.keys.where((k) => k.startsWith('payment:')), isEmpty);
        // The test account's Drive is left as it was.
        final test = t.remotes['test@example.com']!.stored!;
        expect(test['spreadsheetId']!.value, 'sheet-1');
        expect(test.keys.where((k) => k.startsWith('client:')), hasLength(1));
        expect(t.sheet.sheets['sheet-1'], hasLength(1));
      },
    );

    test('keeping data copies it into the new account', () async {
      final t = await testPhone();
      t.account.email = 'business@example.com';

      await t.phone.read(syncProvider.notifier).switchAccount(keepData: true);

      final p = t.phone;
      expect(p.read(addressesProvider).single.name, 'Pretend Client');
      expect(p.read(manualPaymentsProvider).single.amount, 50);
      expect(p.read(settingsProvider).spreadsheetId, 'sheet-2');
      final trip = p.read(tripsProvider).single;
      expect(trip.synced, isTrue);
      expect(t.sheet.sheets['sheet-2']!.keys, [trip.id]);
      final business = t.remotes['business@example.com']!.stored!;
      expect(business.keys.where((k) => k.startsWith('client:')), hasLength(1));
    });

    test('backing out of the new sign-in leaves the device signed out and '
        'reset', () async {
      final t = await testPhone();
      t.account.email = 'business@example.com';
      t.account.cancelNext = true;
      await t.phone.read(syncProvider.notifier).switchAccount(keepData: false);
      expect(t.phone.read(syncProvider).phase, SyncPhase.signedOut);
      expect(t.phone.read(addressesProvider), isEmpty);
      expect(t.phone.read(settingsProvider).spreadsheetId, isNull);
    });

    test('signing in to another account after a plain sign-out moves to a '
        'new spreadsheet, keeping the data', () async {
      final t = await testPhone();
      await t.phone.read(syncProvider.notifier).signOut();
      t.account.email = 'business@example.com';
      await t.phone.read(syncProvider.notifier).signIn();

      final p = t.phone;
      expect(p.read(settingsProvider).spreadsheetId, 'sheet-2');
      expect(p.read(syncProvider).phase, SyncPhase.ready);
      expect(p.read(addressesProvider), hasLength(1));
      expect(t.sheet.sheets['sheet-2'], hasLength(1));
    });

    test('signing back in to the same account keeps its spreadsheet', () async {
      final t = await testPhone();
      await t.phone.read(syncProvider.notifier).signOut();
      await t.phone.read(syncProvider.notifier).signIn();
      expect(t.phone.read(settingsProvider).spreadsheetId, 'sheet-1');
      expect(t.sheet.created, 1);
    });
  });

  group('Stripe', () {
    const clinic = Place(label: 'Clinic', address: '2 Main St', placeId: 'c');

    test('payments are matched to sessions, counted once, and reach the '
        'other device and the spreadsheet', () async {
      var t = DateTime(2026, 11, 19, 9);
      DateTime clock() => t;
      final remote = FakeRemote();
      final sheet = FakeSheet();
      final stripe = FakeStripe()
        ..rejectKey = 'rk_test_bad'
        ..payments.addAll([
          StripePayment(
            id: 'cs_1',
            at: DateTime(2026, 11, 17, 15),
            amount: 300,
            fee: 9,
            email: 'jane@example.com',
            name: 'Jane Smith',
          ),
          StripePayment(
            id: 'cs_2',
            at: DateTime(2026, 11, 18, 10),
            amount: 300,
            fee: 9,
            email: 'bob@example.com',
            name: 'Bob Jones',
            method: PaymentMethod.stripeKlarna,
          ),
          StripePayment(
            id: 'cs_3',
            at: DateTime(2026, 11, 18, 11),
            amount: 20,
            fee: 0.88,
            email: 'pat@example.com',
            name: 'Pat Q',
          ),
        ]);
      final mac = await device(
        remote,
        clock: clock,
        sheet: sheet,
        stripe: stripe,
      );
      final phone = await device(
        remote,
        clock: clock,
        sheet: sheet,
        stripe: stripe,
      );
      await mac.read(syncProvider.notifier).signIn();
      await phone.read(syncProvider.notifier).signIn();

      // Jane has one $300 session booked; Bob has two.
      final clients = mac.read(addressesProvider.notifier);
      ScheduledJob booking(String id, int day) => ScheduledJob(
        id: id,
        start: DateTime(2026, 11, day, 9),
        end: DateTime(2026, 11, day, 12),
      );
      final jane = await clients.add(name: 'Jane Smith', place: clinic);
      await clients.replace(
        jane.copyWith(
          email: 'jane@example.com',
          hourlyRate: 100,
          scheduled: [booking('j1', 20)],
        ),
      );
      final bob = await clients.add(name: 'Bob Jones', place: home);
      await clients.replace(
        bob.copyWith(
          email: 'bob@example.com',
          hourlyRate: 100,
          scheduled: [booking('b1', 21), booking('b2', 28)],
        ),
      );

      // A full secret key isn't taken; a key Stripe rejects isn't kept.
      final notifier = mac.read(stripeProvider.notifier);
      expect(await notifier.connect('sk_live_123'), contains('restricted'));
      expect(await notifier.connect('rk_test_bad'), 'Invalid API Key provided');
      expect(mac.read(stripeKeyProvider), isNull);
      expect(await notifier.connect(' rk_test_good '), isNull);
      expect(mac.read(stripeKeyProvider), 'rk_test_good');
      expect(mac.read(stripeProvider).payments, hasLength(3));

      SavedAddress on(ProviderContainer d, String id) =>
          d.read(addressesProvider).firstWhere((c) => c.id == id);

      // Jane's payment fits her one session: marked paid from Stripe.
      final j1 = on(mac, jane.id).billing['j1']!;
      expect(j1.status, BillingStatus.paid);
      expect(j1.stripeId, 'cs_1');
      expect(j1.amount, 300);
      expect(j1.paidOn, DateTime(2026, 11, 17));
      // Bob's could be either session; Pat isn't a client.
      expect(mac.read(unmatchedStripeProvider).map((p) => p.id), [
        'cs_2',
        'cs_3',
      ]);

      // Picked by hand: Bob's second session; Pat's is other income.
      final cs2 = mac.read(stripeProvider).payments[1];
      final b2 = notifier
          .sessionsOf(bob.id)
          .firstWhere((s) => s.scheduled?.id == 'b2');
      await notifier.link(cs2, bob.id, b2);
      await notifier.notForSession(mac.read(stripeProvider).payments[2]);
      expect(mac.read(unmatchedStripeProvider), isEmpty);
      expect(on(mac, bob.id).billing['b2']!.method, PaymentMethod.stripeKlarna);

      // Changing your mind moves the payment: b2 is back to need to bill.
      final b1 = notifier
          .sessionsOf(bob.id)
          .firstWhere((s) => s.scheduled?.id == 'b1');
      await notifier.link(cs2, bob.id, b1);
      expect(on(mac, bob.id).billing.containsKey('b2'), isFalse);
      expect(on(mac, bob.id).billing['b1']!.stripeId, 'cs_2');

      // In the books once each: $620, with the fees as an expense.
      List<String> ids(ProviderContainer d) => [
        for (final p in d.read(ledgerProvider)) p.id,
      ];
      expect(ids(mac), ['stripe:cs_3', 'stripe:cs_2', 'stripe:cs_1']);
      final fees = mac
          .read(allExpensesProvider)
          .where((e) => e.id == 'stripefees:2026-11')
          .single;
      expect(fees.amount, 18.88);

      // The phone gets the key, reads Stripe itself, and agrees.
      t = t.add(const Duration(minutes: 1));
      await mac.read(syncProvider.notifier).syncNow();
      await phone.read(syncProvider.notifier).syncNow();
      expect(phone.read(stripeKeyProvider), 'rk_test_good');
      expect(phone.read(stripeProvider).payments, hasLength(3));
      expect(ids(phone), ids(mac));
      expect(phone.read(unmatchedStripeProvider), isEmpty);
      expect(on(phone, bob.id).billing['b1']!.stripeId, 'cs_2');
      final rows = sheet.paymentRowsBySheet['sheet-1']!;
      expect(rows.map((r) => r[5]), [300.0, 300.0, 20.0]);
      expect(sheet.expenseRowsBySheet['sheet-1']!.single.sublist(1, 3), [
        'Stripe',
        'Bank & payment fees',
      ]);

      // Stripe isn't read again on every sync, only every few minutes.
      final reads = stripe.reads;
      await phone.read(syncProvider.notifier).syncNow();
      expect(stripe.reads, reads);
      t = t.add(StripeNotifier.refreshEvery);
      await phone.read(syncProvider.notifier).syncNow();
      expect(stripe.reads, reads + 1);

      // Disconnecting on the Mac reaches the phone.
      t = t.add(const Duration(minutes: 1));
      await mac.read(stripeProvider.notifier).disconnect();
      await mac.read(syncProvider.notifier).syncNow();
      await phone.read(syncProvider.notifier).syncNow();
      expect(phone.read(stripeKeyProvider), isNull);
      expect(phone.read(stripeProvider).payments, isEmpty);
      // Sessions stay paid, now counted as session payments.
      expect(ids(phone), contains('session:${jane.id}:j1'));
    });
  });

  group('Stripe payment links', () {
    const clinic = Place(label: 'Clinic', address: '2 Main St', placeId: 'c');

    test('a link per session: made, sent, paid, matched exactly', () async {
      var t = DateTime(2026, 11, 19, 9);
      DateTime clock() => t;
      final remote = FakeRemote();
      final stripe = FakeStripe()..readOnlyKey = 'rk_test_read';
      final mac = await device(remote, clock: clock, stripe: stripe);
      final phone = await device(remote, clock: clock, stripe: stripe);
      await mac.read(syncProvider.notifier).signIn();
      await phone.read(syncProvider.notifier).signIn();

      // Two $300 sessions: by amount alone, a payment couldn't be placed.
      final clients = mac.read(addressesProvider.notifier);
      ScheduledJob booking(String id, int day) => ScheduledJob(
        id: id,
        start: DateTime(2026, 11, day, 9),
        end: DateTime(2026, 11, day, 12),
      );
      final added = await clients.add(name: 'Bob Jones', place: clinic);
      await clients.replace(
        added.copyWith(
          hourlyRate: 100,
          scheduled: [booking('b1', 21), booking('b2', 28)],
        ),
      );
      SavedAddress bob(ProviderContainer d) =>
          d.read(addressesProvider).firstWhere((c) => c.id == added.id);
      final notifier = mac.read(stripeProvider.notifier);
      ClientJobEntry session(String id) => notifier
          .sessionsOf(added.id)
          .firstWhere((s) => s.scheduled?.id == id);

      // A read-only key can't make links, and says what to change.
      expect(await notifier.connect('rk_test_read'), isNull);
      final refused = await notifier.createLink(
        added.id,
        session('b2'),
        amount: 300,
        name: 'Organizing session',
      );
      expect(refused, contains('Write access to Payment Links'));
      expect(bob(mac).billing, isEmpty);

      // With write access: a link for the second session.
      expect(await notifier.connect('rk_test_write'), isNull);
      expect(
        await notifier.createLink(
          added.id,
          session('b2'),
          amount: 300,
          name: paymentLinkName(session('b2')),
        ),
        isNull,
      );
      final made = stripe.links['plink_1']!;
      expect(made.amount, 300);
      expect(made.name, 'Organizing session · 11/28/26 · 3 hours');
      expect(made.clientId, added.id);
      expect(made.sessionKey, 'b2');
      final b2 = bob(mac).billing['b2']!;
      expect(b2.status, BillingStatus.billed);
      expect(b2.link!.url, 'https://buy.stripe.com/test_plink_1');
      expect(b2.link!.createdOn, DateTime(2026, 11, 19));

      // The phone sees the link on the session too.
      t = t.add(const Duration(minutes: 1));
      await mac.read(syncProvider.notifier).syncNow();
      await phone.read(syncProvider.notifier).syncNow();
      expect(bob(phone).billing['b2']!.link!.id, 'plink_1');

      // Paid by someone the app doesn't know: still exactly session b2.
      stripe.pay('plink_1', DateTime(2026, 11, 20, 18), email: 'x@y.com');
      t = t.add(StripeNotifier.refreshEvery);
      await phone.read(syncProvider.notifier).syncNow();
      final paid = bob(phone).billing['b2']!;
      expect(paid.status, BillingStatus.paid);
      expect(paid.stripeId, 'cs_plink_1');
      expect(paid.link, isNull);
      expect(bob(phone).billing.containsKey('b1'), isFalse);
      expect(phone.read(unmatchedStripeProvider), isEmpty);
    });

    test('turning a link off; then making a new one', () async {
      final stripe = FakeStripe();
      final mac = await device(
        FakeRemote(),
        clock: () => DateTime(2026, 11, 19, 9),
        stripe: stripe,
      );
      await mac.read(syncProvider.notifier).signIn();
      final clients = mac.read(addressesProvider.notifier);
      final added = await clients.add(name: 'Ann Lee', place: clinic);
      await clients.replace(
        added.copyWith(
          scheduled: [
            ScheduledJob(
              id: 'a1',
              start: DateTime(2026, 11, 22, 9),
              end: DateTime(2026, 11, 22, 11),
            ),
          ],
        ),
      );
      final notifier = mac.read(stripeProvider.notifier);
      expect(await notifier.connect('rk_test_write'), isNull);
      ClientJobEntry a1() => notifier.sessionsOf(added.id).single;
      await notifier.createLink(added.id, a1(), amount: 150, name: 'x');
      expect(await notifier.turnOffLink(added.id, a1()), isNull);
      expect(stripe.links['plink_1']!.active, isFalse);
      SavedAddress ann() =>
          mac.read(addressesProvider).firstWhere((c) => c.id == added.id);
      expect(ann().billing['a1'], SessionBilling.unbilled);
      await notifier.createLink(added.id, a1(), amount: 175, name: 'x');
      expect(ann().billing['a1']!.link!.id, 'plink_2');
      expect(ann().billing['a1']!.link!.amount, 175);
    });
  });

  group('Send bill', () {
    const clinic = Place(label: 'Clinic', address: '2 Main St', placeId: 'c');

    test('Stripe is watched while a bill is out, and a paid bill is '
        'announced', () async {
      var t = DateTime(2026, 11, 19, 9);
      final stripe = FakeStripe();
      final mac = await device(FakeRemote(), clock: () => t, stripe: stripe);
      await mac.read(syncProvider.notifier).signIn();
      final clients = mac.read(addressesProvider.notifier);
      final added = await clients.add(name: 'Bob Jones', place: clinic);
      await clients.replace(
        added.copyWith(
          hourlyRate: 100,
          scheduled: [
            ScheduledJob(
              id: 'b1',
              start: DateTime(2026, 11, 21, 9),
              end: DateTime(2026, 11, 21, 12),
            ),
          ],
        ),
      );
      final notifier = mac.read(stripeProvider.notifier);
      expect(await notifier.connect('rk_test_write'), isNull);
      var reads = stripe.reads;

      // Nothing out: no checking beyond the usual.
      t = t.add(const Duration(minutes: 5));
      await notifier.watch();
      expect(stripe.reads, reads);

      // A bill sent with a link: checked every couple of minutes.
      await notifier.createLink(
        added.id,
        notifier.sessionsOf(added.id).single,
        amount: 300,
        name: 'x',
      );
      expect(notifier.billsOut, isTrue);
      await notifier.watch();
      expect(stripe.reads, ++reads);
      t = t.add(const Duration(minutes: 1));
      await notifier.watch();
      expect(stripe.reads, reads, reason: 'checked a minute ago');

      // Paid: marked paid, announced once, and the watching stops.
      stripe.pay('plink_1', t, email: 'bob@example.com');
      t = t.add(StripeNotifier.watchEvery);
      await notifier.watch();
      expect(stripe.reads, ++reads);
      final b1 = mac
          .read(addressesProvider)
          .firstWhere((c) => c.id == added.id)
          .billing['b1']!;
      expect(b1.status, BillingStatus.paid);
      expect(
        mac.read(stripePaidNoticesProvider).single,
        'Bob Jones paid \$300.00 for the session on 11/21 (Stripe · Card). '
        'Marked paid.',
      );
      expect(notifier.billsOut, isFalse);
      t = t.add(const Duration(minutes: 10));
      await notifier.watch();
      expect(stripe.reads, reads);
    });

    test('goes to whoever pays, by text if they have a phone', () {
      final bob = SavedAddress(
        id: 'b',
        name: 'Bob Jones',
        address: 'a',
        email: 'bob@example.com',
        contacts: const [
          ClientContact(
            id: 's',
            name: 'Sue Jones',
            label: 'Spouse',
            phone: '410-555-0100',
          ),
          ClientContact(
            id: 'a',
            name: 'Ann Jones',
            label: 'Pays',
            email: 'ann@example.com',
          ),
        ],
      );
      expect(billRecipient(bob).id, 'a');
      expect(
        billRecipient(bob.copyWith(contacts: const [])).id,
        SavedAddress.primaryContactId,
      );
      final session = ClientJobEntry(
        state: ClientJobState.upcoming,
        start: DateTime(2026, 12, 1, 9),
        scheduled: ScheduledJob(id: 'x', start: DateTime(2026, 12, 1, 9)),
      );
      expect(
        billMessage(
          name: 'Ann Jones',
          session: session,
          amount: 300,
          link: linkToken,
        ),
        'Hi Ann, here\'s the bill for your organizing session on 12/01/26 '
        '(\$300). You can pay here: [payment link]',
      );
      expect(
        billMessage(name: '', session: session, amount: null),
        'Hi, here\'s the bill for your organizing session on 12/01/26. '
        'Thank you!',
      );
    });

    testWidgets('from Billing → Sessions, without Stripe: copied and '
        'marked billed', (tester) async {
      final store = MemoryLocalStore();
      await store.saveAddresses([
        SavedAddress(
          id: 'c1',
          name: 'Carol Lee',
          address: '5 Pine Rd',
          hourlyRate: 90,
          scheduled: [
            ScheduledJob(
              id: 's1',
              start: DateTime(2026, 11, 14, 9),
              end: DateTime(2026, 11, 14, 11),
            ),
          ],
        ),
      ]);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localStoreProvider.overrideWithValue(store),
            secretStoreProvider.overrideWithValue(MemorySecretStore()),
            googleAccountServiceProvider.overrideWithValue(null),
            placesServiceProvider.overrideWithValue(null),
            distanceServiceProvider.overrideWithValue(
              const DemoDistanceService(),
            ),
            clockProvider.overrideWithValue(() => DateTime(2026, 11, 19, 9)),
          ],
          child: const MileageApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Billing'));
      await tester.pumpAndSettle();
      expect(find.text('Need to bill'), findsOneWidget);
      await tester.tap(find.text('Send bill'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Send bill · Carol Lee'), findsOneWidget);
      // No phone or email for Carol: copying is the way.
      await tester.tap(find.widgetWithText(FilledButton, 'Copy bill'));
      await tester.pumpAndSettle();
      expect(
        copied,
        'Hi Carol, here\'s the bill for your organizing session on '
        '11/14/26 (\$180). Thank you!',
      );
      expect(
        store.loadAddresses().single.billing['s1']!.status,
        BillingStatus.billed,
      );
      expect(find.text('Resend'), findsOneWidget);
    });
  });
}
