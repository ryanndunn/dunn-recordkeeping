import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mileage_log/app.dart';
import 'package:mileage_log/models/place.dart';
import 'package:mileage_log/services/distance_service.dart';
import 'package:mileage_log/services/local_store.dart';
import 'package:mileage_log/services/places_service.dart';
import 'package:mileage_log/services/secret_store.dart';
import 'package:mileage_log/state/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

const _home = Place(
  label: 'Home',
  address: '1 Home Rd, Springfield, IL 62701, USA',
  placeId: 'home',
  lat: 39.78,
  lng: -89.65,
);
const _clinicGoogle = Place(
  label: 'Springfield Family Clinic',
  address: '123 Main St, Springfield, IL 62701, USA',
  placeId: 'clinic',
  lat: 39.80,
  lng: -89.64,
);
const _elm = Place(
  label: '9 Elm St',
  address: '9 Elm St, Peoria, IL 61602, USA',
  placeId: 'elm',
  lat: 40.69,
  lng: -89.59,
);

final _savedPrefs = <String, Object>{
  'settings_v1': jsonEncode({'home': _home.toJson()}),
  'addresses_v1': jsonEncode([
    {
      'id': 'c',
      'name': 'Clinic',
      'address': _clinicGoogle.address,
      'placeId': 'clinic',
      'lat': 39.80,
      'lng': -89.64,
    },
    {
      'id': 'd',
      'name': 'Dentist',
      'address': '55 Oak Ave, Springfield, IL 62702, USA',
      'placeId': 'dentist',
    },
  ]),
};

Future<void> pumpApp(
  WidgetTester tester,
  Map<String, Object> prefs, {
  bool withGoogle = true,
  DistanceService? distance,
  bool openLogTrip = true,
}) async {
  // A tall window, so the Mileage Log's trip list (below the job card)
  // is on screen. Tests that set their own size keep it.
  if (tester.view.devicePixelRatio != 1) {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }
  SharedPreferences.setMockInitialValues(prefs);
  final store = LocalStore(await SharedPreferences.getInstance());
  final PlacesService? places = withGoogle
      ? FakePlacesService([_home, _clinicGoogle, _elm])
      : null;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        localStoreProvider.overrideWithValue(store),
        secretStoreProvider.overrideWithValue(
          MemorySecretStore(withGoogle ? 'test-key-0123456789abcd' : null),
        ),
        placesServiceProvider.overrideWithValue(places),
        distanceServiceProvider.overrideWithValue(
          distance ??
              (withGoogle
                  ? FakeDistanceService(miles: 8.4)
                  : const DemoDistanceService()),
        ),
        clockProvider.overrideWithValue(() => DateTime(2026, 11, 14, 10)),
      ],
      child: const MileageApp(),
    ),
  );
  await tester.pumpAndSettle();
  // The app opens on Clients; most tests start from the Mileage Log.
  if (openLogTrip) await openMileageLog(tester);
}

/// Settings → Mileage Log.
Future<void> openMileageLog(WidgetTester tester) async {
  await tester.tap(find.text('Settings'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Mileage Log'));
  await tester.pumpAndSettle();
}

/// Back to the tabs (if on a pushed page), then Clients.
Future<void> openClientsTab(WidgetTester tester) async {
  while (find.byType(BackButton).evaluate().isNotEmpty) {
    await goBack(tester);
  }
  await tester.tap(find.text('Clients'));
  await tester.pumpAndSettle();
}

/// Taps a filter chip, scrolling the chip row to it first.
Future<void> tapChip(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

/// Back from a pushed page (Mileage Log, a client) to the tabs.
Future<void> goBack(WidgetTester tester) async {
  await tester.tap(find.byType(BackButton));
  await tester.pumpAndSettle();
}

/// Types into the address box and waits out the search debounce.
Future<void> search(WidgetTester tester, String text) =>
    searchIn(tester, find.byType(TextField).first, text);

/// Types into [field] and waits out the search debounce.
Future<void> searchIn(WidgetTester tester, Finder field, String text) async {
  await tester.enterText(field, text);
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('asks for a home address before the first trip', (tester) async {
    await pumpApp(tester, {});
    expect(find.text('Set your home/office address'), findsOneWidget);
  });

  testWidgets('picking saved addresses logs trips from home, then onward', (
    tester,
  ) async {
    await pumpApp(tester, _savedPrefs);
    expect(find.text('From: Home'), findsOneWidget);

    await search(tester, 'clin');
    await tester.tap(find.text('Clinic'));
    await tester.pumpAndSettle();

    expect(find.text('Home → Clinic'), findsOneWidget);
    expect(find.text('From: Clinic'), findsOneWidget);
    // Box is cleared and the dropdown closed.
    expect(find.text('55 Oak Ave, Springfield, IL 62702, USA'), findsNothing);

    await search(tester, 'dent');
    await tester.tap(find.text('Dentist'));
    await tester.pumpAndSettle();
    expect(find.text('Clinic → Dentist'), findsOneWidget);
    expect(find.text('From: Dentist'), findsOneWidget);
  });

  testWidgets('a Google result that is already saved shows as the saved one', (
    tester,
  ) async {
    await pumpApp(tester, _savedPrefs);

    await search(tester, 'family');
    expect(find.text('Clinic'), findsOneWidget);
    expect(find.text('Springfield Family Clinic'), findsNothing);
  });

  testWidgets('a new Google address can be logged once', (tester) async {
    await pumpApp(tester, _savedPrefs);

    await search(tester, 'elm');
    expect(find.text('Powered by Google'), findsOneWidget);
    await tester.tap(find.text('9 Elm St'));
    await tester.pumpAndSettle();
    expect(find.text('Not one of your clients'), findsOneWidget);

    await tester.tap(find.text('Log once'));
    await tester.pumpAndSettle();
    expect(find.text('Home → 9 Elm St'), findsOneWidget);
  });

  testWidgets('a new Google address can be saved and logged', (tester) async {
    await pumpApp(tester, _savedPrefs);

    await search(tester, 'elm');
    await tester.tap(find.text('9 Elm St'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add client & log'));
    await tester.pumpAndSettle();

    // Client dialog is prefilled with Google's name and verified address.
    expect(find.text('New client'), findsOneWidget);
    expect(find.text(_elm.address), findsWidgets);
    await tester.enterText(
      find.widgetWithText(TextField, 'Name'),
      'Peoria Office',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save & log'));
    await tester.pumpAndSettle();

    expect(find.text('Home → Peoria Office'), findsOneWidget);

    await openClientsTab(tester);
    expect(find.text('Peoria Office'), findsOneWidget);
  });

  testWidgets('typed text that was not picked is refused', (tester) async {
    await pumpApp(tester, _savedPrefs);

    await search(tester, '742 Evergreen Terrace');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.text('Choose an address from the list.'), findsOneWidget);
    expect(find.textContaining('→'), findsNothing);
  });

  testWidgets('refuses a trip to the place you are already at', (tester) async {
    await pumpApp(tester, _savedPrefs);

    await search(tester, 'home rd');
    await tester.tap(find.text('Home').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Log once'));
    await tester.pumpAndSettle();

    expect(find.textContaining('already at'), findsOneWidget);
    expect(find.textContaining('→'), findsNothing);
  });

  testWidgets('without an API key only clients are offered', (tester) async {
    await pumpApp(tester, _savedPrefs, withGoogle: false);

    expect(find.textContaining('Clients only'), findsOneWidget);
    await search(tester, 'elm');
    expect(find.text('9 Elm St'), findsNothing);

    await search(tester, 'clin');
    await tester.tap(find.text('Clinic'));
    await tester.pumpAndSettle();
    expect(find.text('Home → Clinic'), findsOneWidget);
  });

  testWidgets('new client address must be picked from Google', (tester) async {
    await pumpApp(tester, _savedPrefs);
    await openClientsTab(tester);
    await tester.tap(find.text('Add client'));
    await tester.pumpAndSettle();

    FilledButton saveButton() =>
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'));
    expect(saveButton().onPressed, isNull);

    await searchIn(tester, find.widgetWithText(TextField, 'Address'), 'elm');
    await tester.tap(find.text('9 Elm St'));
    await tester.pumpAndSettle();

    expect(saveButton().onPressed, isNotNull);
    // Name was filled from Google.
    expect(find.widgetWithText(TextField, '9 Elm St'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.text('9 Elm St'), findsOneWidget);
    expect(find.text(_elm.address), findsOneWidget);
  });

  testWidgets('with a key, trips log Google miles with no estimate tag', (
    tester,
  ) async {
    await pumpApp(tester, _savedPrefs);
    expect(find.text('Estimated miles'), findsNothing);

    await search(tester, 'clin');
    await tester.tap(find.text('Clinic'));
    await tester.pumpAndSettle();
    expect(find.text('8.4 mi'), findsWidgets);
    expect(find.textContaining('est.'), findsNothing);
  });

  testWidgets('without a key, trips are tagged as estimates', (tester) async {
    await pumpApp(tester, _savedPrefs, withGoogle: false);
    expect(find.text('Estimated miles'), findsOneWidget);

    await search(tester, 'clin');
    await tester.tap(find.text('Clinic'));
    await tester.pumpAndSettle();
    expect(find.textContaining('est.'), findsOneWidget);
  });

  testWidgets('if Google cannot measure the drive, no trip is logged', (
    tester,
  ) async {
    await pumpApp(
      tester,
      _savedPrefs,
      distance: FakeDistanceService(fail: true),
    );

    await search(tester, 'clin');
    await tester.tap(find.text('Clinic'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Trip not logged'), findsOneWidget);
    expect(find.textContaining('→'), findsNothing);
    expect(find.text('From: Home'), findsOneWidget);
  });

  testWidgets('older unverified addresses are flagged', (tester) async {
    await pumpApp(tester, {
      'settings_v1': jsonEncode({'home': _home.toJson()}),
      'addresses_v1': jsonEncode([
        {'id': 'x', 'name': 'Old', 'address': '5 Typed St'},
      ]),
    });
    await openClientsTab(tester);
    expect(find.textContaining('not verified'), findsOneWidget);
  });

  testWidgets('a client keeps a phone number and email', (tester) async {
    await pumpApp(tester, _savedPrefs);
    await openClientsTab(tester);
    await tester.tap(find.text('Add client'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Name'),
      'Jane Smith',
    );
    await searchIn(tester, find.widgetWithText(TextField, 'Address'), 'elm');
    await tester.tap(find.text('9 Elm St'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Phone (optional)'),
      '(309) 555-0142',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Email (optional)'),
      'jane.example.com',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('Check the email address'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Email (optional)'),
      'jane@example.com',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.text('Jane Smith'), findsOneWidget);
    expect(find.textContaining('(309) 555-0142 · jane@example.com'), findsOne);
    expect(find.byTooltip('Call Jane Smith'), findsOneWidget);
    expect(find.byTooltip('Email Jane Smith'), findsOneWidget);
    // Clients without contact details show no call or email buttons.
    expect(find.byTooltip('Call Clinic'), findsNothing);

    // The client's page shows the details.
    await tester.tap(find.text('Jane Smith'));
    await tester.pumpAndSettle();
    expect(find.text('jane@example.com'), findsOneWidget);
    expect(find.text('(309) 555-0142'), findsOneWidget);
  });

  testWidgets('the app opens on Clients', (tester) async {
    await pumpApp(tester, _savedPrefs, openLogTrip: false);
    expect(find.widgetWithText(AppBar, 'Clients'), findsOneWidget);
    expect(find.text('Add client'), findsOneWidget);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      0,
    );
  });

  testWidgets('a client page edits details in place and lists trips', (
    tester,
  ) async {
    // A phone-sized screen, tall enough to show the whole page.
    tester.view.physicalSize = const Size(420, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpApp(tester, _savedPrefs);
    await search(tester, 'clin');
    await tester.tap(find.text('Clinic'));
    await tester.pumpAndSettle();

    await openClientsTab(tester);
    await tester.tap(find.text('Clinic'));
    await tester.pumpAndSettle();

    // A page, not a popup: name in the app bar, trips listed.
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.widgetWithText(AppBar, 'Clinic'), findsOneWidget);
    expect(find.text('In progress'), findsOneWidget, reason: 'job started');
    expect(find.textContaining('8.4 mi'), findsWidgets);
    // No phone yet: Call and Text are greyed out.
    FilledButton action(String label) => tester.widget<FilledButton>(
      find.ancestor(of: find.text(label), matching: find.byType(FilledButton)),
    );
    expect(action('Call').onPressed, isNull);
    expect(action('Directions').onPressed, isNotNull);

    // Add a phone number in place.
    await tester.tap(find.text('Add a phone number'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Phone'), '555-0100');
    await tester.tap(find.byTooltip('Save phone'));
    await tester.pumpAndSettle();
    expect(find.text('555-0100'), findsOneWidget);
    expect(action('Call').onPressed, isNotNull);

    // A bad email is refused; the old value stays.
    await tester.tap(find.byTooltip('Edit email'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Email'), 'nope');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Check the email address'), findsOneWidget);
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Add an email address'), findsOneWidget);

    // Renaming updates the page and the list.
    await tester.tap(find.byTooltip('Edit name'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Name'),
      'Main Clinic',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Main Clinic'), findsOneWidget);

    // Deleting goes back to the list.
    await tester.tap(find.byTooltip('Delete client'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Clients'), findsOneWidget);
    expect(find.text('Main Clinic'), findsNothing);
    expect(find.text('Dentist'), findsOneWidget);
  });

  testWidgets('a client can have more addresses, each its own trip stop', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpApp(tester, _savedPrefs, openLogTrip: false);

    await tester.tap(find.text('Clinic'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add another address'));
    await tester.pumpAndSettle();

    FilledButton addButton() =>
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Add'));
    expect(addButton().onPressed, isNull);
    await tester.tap(find.widgetWithText(ActionChip, 'Storage unit'));
    await searchIn(tester, find.widgetWithText(TextField, 'Address'), 'elm');
    await tester.tap(find.text('9 Elm St'));
    await tester.pumpAndSettle();
    expect(addButton().onPressed, isNotNull);
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    expect(find.text('Storage unit'), findsOneWidget);
    expect(find.text(_elm.address), findsOneWidget);
    expect(find.byTooltip('Directions to Storage unit'), findsOneWidget);

    // Back on the list, the client shows the extra address.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.textContaining('+ Storage unit'), findsOneWidget);

    // Log Trip offers it as its own stop.
    await openMileageLog(tester);
    await search(tester, 'clin');
    await tester.tap(find.text('Clinic (Storage unit)'));
    await tester.pumpAndSettle();
    expect(find.text('Home → Clinic (Storage unit)'), findsOneWidget);

    // The client's page counts it, and says where it went.
    await openClientsTab(tester);
    await tester.tap(find.text('Clinic'));
    await tester.pumpAndSettle();
    expect(find.textContaining('at Storage unit'), findsOneWidget);

    // Removing the address keeps the trip.
    await tester.tap(find.byTooltip('Edit Storage unit'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Remove this address'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(find.text('Storage unit'), findsNothing);
    expect(find.text('Add another address'), findsOneWidget);
  });

  testWidgets('clients have an hourly rate (default \$75)', (tester) async {
    await pumpApp(tester, _savedPrefs, openLogTrip: false);
    await tester.tap(find.text('Clinic'));
    await tester.pumpAndSettle();
    expect(find.text('\$75 per hour'), findsOneWidget);

    await tester.tap(find.byTooltip('Edit hourly rate'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Hourly rate'), '0');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Enter an amount'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Hourly rate'),
      '82.50',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('\$82.50 per hour'), findsOneWidget);
  });

  testWidgets('a client goes new → consultation → policy doc → active, and '
      'can be archived', (tester) async {
    await pumpApp(tester, _savedPrefs, openLogTrip: false);
    // Clients from before the statuses: waiting on the policy doc.
    expect(find.text('Policy doc 2'), findsOneWidget);

    // A new client starts as New.
    await tester.tap(find.text('Add client'));
    await tester.pumpAndSettle();
    await searchIn(tester, find.widgetWithText(TextField, 'Address'), 'elm');
    await tester.tap(find.text('9 Elm St'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Jane');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('New 1'), findsOneWidget);

    await tester.tap(find.text('Jane'));
    await tester.pumpAndSettle();
    expect(find.text('Next: book the free 30-minute consultation'), findsOne);

    await tester.tap(find.widgetWithText(FilledButton, 'Consultation booked'));
    await tester.pumpAndSettle();
    expect(find.text('Pending consultation'), findsWidgets);

    // Consultation done: no date to pick; it's recorded as today.
    await tester.tap(find.widgetWithText(FilledButton, 'Consultation done'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsNothing);
    expect(find.text('Pending policy doc'), findsWidgets);
    expect(find.textContaining('Consultation 11/14/26'), findsOneWidget);
    expect(find.text('Not signed yet'), findsOneWidget);

    // Signing the policy doc (its own section) makes them active.
    await tester.tap(find.widgetWithText(FilledButton, 'Mark signed'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Active'), findsWidgets);
    expect(find.text('Signed 11/14/26'), findsOneWidget);

    await goBack(tester);
    expect(find.text('Active 1'), findsOneWidget);
    await tapChip(tester, 'Active 1');
    expect(find.text('Jane'), findsOneWidget);
    expect(find.text('Clinic'), findsNothing);

    // Archive: off the main list, and not offered as a trip stop.
    await tester.tap(find.text('Jane'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Change status'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();
    expect(find.text('Archived'), findsWidgets);
    await goBack(tester);
    await tapChip(tester, 'All 2');
    expect(find.text('Jane'), findsNothing);
    await tapChip(tester, 'Archived 1');
    expect(find.text('Jane'), findsOneWidget);

    await openMileageLog(tester);
    await search(tester, 'jane');
    expect(find.text('Jane'), findsNothing);

    // Restore brings them back where they left off.
    await openClientsTab(tester);
    await tester.tap(find.text('Jane'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsNothing);
    expect(find.text('Current client'), findsOneWidget);
    expect(find.text('Signed 11/14/26'), findsOneWidget);

    // Archived → Active from the menu: no date picker either.
    await tester.tap(find.byTooltip('Change status'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Change status'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set to Active'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsNothing);
    expect(find.text('Current client'), findsOneWidget);

    // Marking the policy doc not signed puts them back to waiting on it.
    await tester.tap(find.byTooltip('Policy doc options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mark as not signed'));
    await tester.pumpAndSettle();
    expect(find.text('Pending policy doc'), findsWidgets);
    expect(find.text('Not signed yet'), findsOneWidget);
  });

  testWidgets('Mileage Log lives in Settings, with jobs and donation centers', (
    tester,
  ) async {
    await pumpApp(tester, _savedPrefs, openLogTrip: false);
    expect(find.text('Log Trip'), findsNothing, reason: 'no longer a tab');
    await openMileageLog(tester);
    expect(find.widgetWithText(AppBar, 'Mileage Log'), findsOneWidget);
    expect(find.text('Not on a job'), findsOneWidget);

    // Add a donation center.
    await tester.ensureVisible(find.text('Donation centers'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Add'));
    await tester.pumpAndSettle();
    await searchIn(tester, find.widgetWithText(TextField, 'Address'), 'elm');
    await tester.tap(find.text('9 Elm St'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Goodwill');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('Goodwill'), findsOneWidget);

    // A trip to a client starts a job.
    await tester.ensureVisible(find.text('Not on a job'));
    await tester.pumpAndSettle();
    await search(tester, 'clin');
    await tester.tap(find.text('Clinic'));
    await tester.pumpAndSettle();
    expect(find.textContaining('On a job since'), findsOneWidget);

    // The donation center is offered when searching, and keeps the job
    // going.
    await search(tester, 'good');
    await tester.tap(find.text('Goodwill').first);
    await tester.pumpAndSettle();
    expect(find.text('Clinic → Goodwill'), findsOneWidget);
    expect(find.textContaining('On a job since'), findsOneWidget);

    // Back home ends it.
    await tester.tap(find.text('Return to Home'));
    await tester.pumpAndSettle();
    expect(find.text('Not on a job'), findsOneWidget);
    expect(find.textContaining('Today:'), findsOneWidget);
  });

  testWidgets('a job can be scheduled, edited and cancelled', (tester) async {
    await pumpApp(tester, _savedPrefs, openLogTrip: false);
    tester.view.physicalSize = const Size(420, 2200);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clinic'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No jobs yet'), findsOneWidget);

    // Book one for tomorrow (the default) at 9:00 AM.
    await tester.tap(find.text('Schedule a job'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Notes (optional)'),
      'Garage clean-out',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('Upcoming'), findsOneWidget);
    expect(find.text('Sun 11/15/26 · 9:00 AM'), findsOneWidget);
    expect(find.text('Garage clean-out'), findsOneWidget);

    // Cancel it.
    await tester.tap(find.text('Sun 11/15/26 · 9:00 AM'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel job'));
    await tester.pumpAndSettle();
    expect(find.text('Upcoming'), findsNothing);
  });
}
