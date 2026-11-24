import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mileage_log/app.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:http/http.dart' as http;
import 'package:mileage_log/services/google_account.dart';
import 'package:mileage_log/services/google_calendar.dart';
import 'package:mileage_log/state/calendar_provider.dart';
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
  List<Override> overrides = const [],
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
        ...overrides,
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

/// Picks [label] (e.g. "Active (1)") in the clients' Status dropdown.
Future<void> chooseStatus(WidgetTester tester, String label) async {
  await tester.tap(find.byType(DropdownButtonFormField<int>));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

/// Picks [label] from the status menu under a client's name.
Future<void> setClientStatus(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip('Change status'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
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
    expect(find.text('(309) 555-0142\njane@example.com'), findsOneWidget);
    expect(find.text('Primary'), findsOneWidget);
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
    tester.view.physicalSize = const Size(420, 3200);
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

    // The client is the first contact, labelled Primary. Add a phone.
    expect(find.text('Primary'), findsOneWidget);
    await tester.tap(find.text('Tap to add a phone number or email'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Phone (optional)'),
      '555-0100',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('555-0100'), findsOneWidget);
    expect(action('Call').onPressed, isNotNull);

    // A bad email is refused, and the label can be changed.
    await tester.tap(find.text('555-0100'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Remove this contact'), findsNothing);
    await tester.enterText(
      find.widgetWithText(TextField, 'Email (optional)'),
      'nope',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('Check the email address'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Email (optional)'),
      '',
    );
    await tester.tap(find.widgetWithText(ActionChip, 'Pays'));
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('Pays'), findsOneWidget);
    expect(find.text('Primary'), findsNothing);

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
    tester.view.physicalSize = const Size(420, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpApp(tester, _savedPrefs, openLogTrip: false);

    await tester.tap(find.text('Clinic'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add an address'));
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
    expect(find.textContaining('+ 1 more address'), findsOneWidget);

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
    expect(find.text('Large property'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('Remove this address'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Remove this address'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(find.text('Storage unit'), findsNothing);
    expect(find.text('Add an address'), findsOneWidget);
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
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpApp(tester, _savedPrefs, openLogTrip: false);
    // Clients from before the statuses: waiting on the policy doc.
    await chooseStatus(tester, 'Pending policy doc (2)');
    await chooseStatus(tester, 'All clients (2)');

    // A new client starts as New.
    await tester.tap(find.text('Add client'));
    await tester.pumpAndSettle();
    await searchIn(tester, find.widgetWithText(TextField, 'Address'), 'elm');
    await tester.tap(find.text('9 Elm St'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Jane');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    await chooseStatus(tester, 'New (1)');
    await chooseStatus(tester, 'All clients (3)');

    await tester.tap(find.text('Jane'));
    await tester.pumpAndSettle();
    expect(find.text('New'), findsOneWidget, reason: 'the status badge');

    // The badge under the name is the status menu.
    await setClientStatus(tester, 'Pending consultation');
    expect(find.text('Pending consultation'), findsOneWidget);

    // Consultation done: no date to pick; it's recorded as today.
    await setClientStatus(tester, 'Pending policy doc');
    expect(find.byType(DatePickerDialog), findsNothing);
    expect(find.text('Pending policy doc'), findsOneWidget);
    expect(find.textContaining('Consultation 11/14/26'), findsOneWidget);
    expect(find.text('Not signed yet'), findsOneWidget);

    // Signing the policy doc (its own section) makes them active, and the
    // section moves to the bottom of the page.
    double top(Finder f) => tester.getTopLeft(f).dy;
    expect(
      top(find.text('Not signed yet')) < top(find.text('Contacts')),
      isTrue,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Mark signed'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Active'), findsOneWidget);
    expect(find.text('Signed 11/14/26'), findsOneWidget);
    expect(
      top(find.text('Signed 11/14/26')) > top(find.text('Sessions')),
      isTrue,
    );

    await goBack(tester);
    await chooseStatus(tester, 'Active (1)');
    expect(find.text('Jane'), findsOneWidget);
    expect(find.text('Clinic'), findsNothing);

    // Archive: off the main list, and not offered as a trip stop.
    await tester.tap(find.text('Jane'));
    await tester.pumpAndSettle();
    await setClientStatus(tester, 'Archived');
    expect(find.text('Archived'), findsOneWidget);
    await goBack(tester);
    await chooseStatus(tester, 'All clients (2)');
    expect(find.text('Jane'), findsNothing);
    await chooseStatus(tester, 'Archived (1)');
    expect(find.text('Jane'), findsOneWidget);

    await openMileageLog(tester);
    await search(tester, 'jane');
    expect(find.text('Jane'), findsNothing);

    // Archived → Active: no date picker; the signed date is kept.
    await openClientsTab(tester);
    await tester.tap(find.text('Jane'));
    await tester.pumpAndSettle();
    await setClientStatus(tester, 'Active');
    expect(find.byType(DatePickerDialog), findsNothing);
    expect(find.text('Active'), findsOneWidget);
    expect(find.text('Signed 11/14/26'), findsOneWidget);

    // Marking the policy doc not signed puts them back to waiting on it.
    await tester.tap(find.byTooltip('Policy doc options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mark as not signed'));
    await tester.pumpAndSettle();
    expect(find.text('Pending policy doc'), findsOneWidget);
    expect(find.text('Not signed yet'), findsOneWidget);
  });

  testWidgets('a client page has notes, keeps the bottom bar, and switches '
      'to other clients', (tester) async {
    await pumpApp(tester, _savedPrefs, openLogTrip: false);
    await tester.tap(find.text('Clinic'));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Saved as you type'),
      'Gate code 1234',
    );
    await tester.pump(const Duration(seconds: 1));

    // Other clients are in the slim sidebar, even on a phone: it slides
    // out with its button (or on hover) and closes after picking.
    expect(find.text('Dentist'), findsNothing, reason: 'initials only');
    await tester.tap(find.byTooltip('Show clients'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dentist').last);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Dentist'), findsOneWidget);
    expect(find.text('Gate code 1234'), findsNothing);
    expect(find.byTooltip('Show clients'), findsOneWidget, reason: 'closed');

    // Back to Clinic: the note was saved.
    await tester.tap(find.byTooltip('Show clients'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clinic').last);
    await tester.pumpAndSettle();
    expect(find.text('Gate code 1234'), findsOneWidget);

    // Back goes to the list, not the previous client.
    await goBack(tester);
    expect(find.widgetWithText(AppBar, 'Clients'), findsOneWidget);
  });

  testWidgets('the client sidebar slides out on hover', (tester) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpApp(tester, _savedPrefs, openLogTrip: false);
    await tester.tap(find.text('Clinic'));
    await tester.pumpAndSettle();
    expect(find.text('Dentist'), findsNothing);

    // Hovering the strip of initials shows the names.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byTooltip('Show clients')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dentist'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Dentist'), findsOneWidget);

    // Moving away slides it back.
    await mouse.moveTo(const Offset(900, 700));
    await tester.pumpAndSettle();
    expect(find.text('Clinic'), findsNothing);
  });

  testWidgets('Mileage Log lives in Settings, with jobs and donation centers', (
    tester,
  ) async {
    await pumpApp(tester, _savedPrefs, openLogTrip: false);
    expect(find.text('Log Trip'), findsNothing, reason: 'no longer a tab');
    await openMileageLog(tester);
    expect(find.widgetWithText(AppBar, 'Mileage Log'), findsOneWidget);
    expect(find.text('Not in a session'), findsOneWidget);

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
    await tester.ensureVisible(find.text('Not in a session'));
    await tester.pumpAndSettle();
    await search(tester, 'clin');
    await tester.tap(find.text('Clinic'));
    await tester.pumpAndSettle();
    expect(find.textContaining('In a session since'), findsOneWidget);

    // The donation center is offered when searching, and keeps the job
    // going.
    await search(tester, 'good');
    await tester.tap(find.text('Goodwill').first);
    await tester.pumpAndSettle();
    expect(find.text('Clinic → Goodwill'), findsOneWidget);
    expect(find.textContaining('In a session since'), findsOneWidget);

    // Back home ends it.
    await tester.tap(find.text('Return to Home'));
    await tester.pumpAndSettle();
    expect(find.text('Not in a session'), findsOneWidget);
    expect(find.textContaining('Today:'), findsOneWidget);
  });

  testWidgets('a session is booked with an end time and billed at the '
      'client\'s rate', (tester) async {
    await pumpApp(tester, _savedPrefs, openLogTrip: false);
    tester.view.physicalSize = const Size(420, 3200);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clinic'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No sessions yet'), findsOneWidget);

    // Book one for tomorrow (the default), 9:00 AM to noon.
    await tester.tap(find.text('Schedule a session'));
    await tester.pumpAndSettle();
    expect(find.text('3 h 00 m at \$75/hour = \$225'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Notes (optional)'),
      'Garage clean-out',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('Upcoming'), findsOneWidget);
    const booked = 'Sun 11/15/26 · 9:00 AM – 12:00 PM';
    expect(find.text(booked), findsOneWidget);
    expect(
      find.text('3 h 00 m with the client · \$225\nGarage clean-out'),
      findsOneWidget,
    );

    // Clients pre-pay: mark it paid by Venmo.
    expect(find.text('1 to bill · \$225'), findsOneWidget);
    await tester.ensureVisible(find.text('Need to bill'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Need to bill'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paid').last);
    await tester.pumpAndSettle();
    FilledButton save() => tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Save').last,
    );
    expect(save().onPressed, isNull, reason: 'paid needs a method');
    await tester.tap(find.text('Venmo'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
    await tester.pumpAndSettle();
    expect(find.text('Paid'), findsOneWidget);
    expect(find.text('Venmo'), findsOneWidget);
    expect(find.text('Nothing to bill'), findsOneWidget);

    // Cancel it.
    await tester.tap(find.text(booked));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel session'));
    await tester.pumpAndSettle();
    expect(find.text('Upcoming'), findsNothing);
  });

  testWidgets('a client can have more contacts, found by search', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpApp(tester, _savedPrefs, openLogTrip: false);
    await tester.tap(find.text('Clinic'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add a contact'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Contact name'),
      'Pat Spouse',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Email (optional)'),
      'not-an-email',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    expect(find.text('Check the email address'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Email (optional)'),
      'pat@example.com',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Phone (optional)'),
      '(309) 555-0199',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    expect(find.text('Pat Spouse'), findsOneWidget);
    expect(find.byTooltip('Call Pat Spouse'), findsOneWidget);

    await goBack(tester);
    await tester.enterText(
      find.widgetWithText(TextField, 'Search clients'),
      '5550199',
    );
    await tester.pumpAndSettle();
    expect(find.text('Clinic'), findsOneWidget);
    expect(find.text('Dentist'), findsNothing);
  });

  testWidgets('Calendar shows Google events with booked sessions, and '
      'books a session in a free spot', (tester) async {
    final prefs = {
      ..._savedPrefs,
      'addresses_v1': jsonEncode([
        for (final c
            in jsonDecode(_savedPrefs['addresses_v1']! as String) as List)
          if ((c as Map<String, dynamic>)['id'] == 'c')
            {
              ...c,
              'scheduled': [
                {
                  'id': 's1',
                  'start': '2026-11-12T13:00:00',
                  'end': '2026-11-12T15:00:00',
                },
              ],
            }
          else
            c,
      ]),
    };
    await pumpApp(
      tester,
      prefs,
      openLogTrip: false,
      overrides: [
        googleAccountServiceProvider.overrideWithValue(_CalendarAccount()),
        calendarSourceFactoryProvider.overrideWithValue((_) => _FakeCalendar()),
      ],
    );
    await tester.tap(find.text('Calendar'));
    await tester.pumpAndSettle();

    // The week of Sun 11/8, with a personal event and Clinic's session.
    expect(find.text('Nov 8 – 14, 2026'), findsOneWidget);
    expect(find.textContaining('Pilates'), findsOneWidget);
    expect(find.text('Clinic\n1:00 PM – 3:00 PM'), findsOneWidget);
    expect(find.text('Consultation Availability'), findsOneWidget);

    // Tap Saturday at 2 PM (an open spot) to book Dentist there.
    final saturday = find
        .byWidgetPredicate((w) => w.runtimeType.toString() == '_DayColumn')
        .at(6);
    final top = tester.getTopLeft(saturday);
    await tester.tapAt(top + const Offset(20, 14 * 48 + 10));
    await tester.pumpAndSettle();
    expect(find.text('Book a session at 2:00 PM, Sat 11/14'), findsOneWidget);
    await tester.tap(find.text('Dentist'));
    await tester.pumpAndSettle();
    expect(find.text('Schedule a session · Dentist'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('Dentist\n2:00 PM – 5:00 PM'), findsOneWidget);

    // Tapping a session opens the client.
    await tester.tap(find.text('Clinic\n1:00 PM – 3:00 PM'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Clinic'), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('Club lists members, marks clients, and shows who paid for '
      'the next webinar, to send them the link', (tester) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final soon = DateTime.now().add(const Duration(days: 10));
    final next = DateTime(soon.year, soon.month, soon.day, 20);
    final at = DateTime.now().toUtc().toIso8601String();
    final prefs = {
      ..._savedPrefs,
      'addresses_v1': jsonEncode([
        for (final c
            in jsonDecode(_savedPrefs['addresses_v1']! as String) as List)
          (c as Map<String, dynamic>)['id'] == 'c'
              ? {...c, 'email': 'clinic@example.com'}
              : c,
      ]),
      // Sam filled out the interest form.
      'club_registrations_v1': jsonEncode([
        {
          'id': 'r1',
          'at': DateTime.now().toIso8601String(),
          'email': 'sam@example.com',
          'name': 'Sam Lee',
          'mailingList': true,
        },
      ]),
      // The clinic's owner was added by hand.
      'club_members_v1': jsonEncode({
        'm1': {
          'v': {'email': 'clinic@example.com', 'name': 'Clara'},
          'at': at,
        },
      }),
      'webinars_v1': jsonEncode({
        'w1': {
          'v': {'start': next.toIso8601String(), 'topic': 'Closets'},
          'at': at,
        },
      }),
      'club_payments_v1': jsonEncode({
        'w1|m1': {
          'v': {'status': 'paid', 'method': 'venmo', 'amount': 20},
          'at': at,
        },
      }),
    };
    await pumpApp(tester, prefs, openLogTrip: false);
    await tester.tap(find.text('Club'));
    await tester.pumpAndSettle();

    expect(find.text('Members (2)'), findsOneWidget);
    expect(find.text('Sam Lee'), findsOneWidget);
    expect(find.text('New'), findsOneWidget, reason: 'Sam just joined');
    expect(find.text('Add as client'), findsOneWidget, reason: 'Sam only');
    expect(find.widgetWithText(ActionChip, 'Client'), findsOneWidget);

    // Leads are contact form inquiries only.
    await tester.tap(find.text('Leads'));
    await tester.pumpAndSettle();
    expect(find.text('Sam Lee'), findsNothing);
    await tester.tap(find.text('Club'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Webinars (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Closets'), findsOneWidget);
    expect(find.textContaining('1 paid · 1 not paid'), findsOneWidget);
    await tester.tap(find.text('Closets'));
    await tester.pumpAndSettle();
    expect(find.text('Paid (1)'), findsOneWidget);
    expect(find.text('Not paid (1)'), findsOneWidget);
    expect(find.textContaining('First meeting (free)'), findsOneWidget);

    // The join link goes only to Clara, who paid.
    await tester.tap(find.text('Send join link (1)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('To 1 member who paid'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Clara'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // The invite goes to the mailing list.
    await tester.tap(find.text('Email the invite'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('To 2 members on the mailing list'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Sam pays.
    await tester.tap(find.text('Mark paid'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paid \$20.00'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Venmo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Paid (2)'), findsOneWidget);
    expect(find.text('Send join link (2)'), findsOneWidget);
  });

  testWidgets('a paid session and an added expense show in Payments', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final prefs = {
      ..._savedPrefs,
      'addresses_v1': jsonEncode([
        for (final c
            in jsonDecode(_savedPrefs['addresses_v1']! as String) as List)
          if ((c as Map<String, dynamic>)['id'] == 'c')
            {
              ...c,
              'scheduled': [
                {
                  'id': 's1',
                  'start': '2026-11-10T09:00:00',
                  'end': '2026-11-10T12:00:00',
                },
              ],
            }
          else
            c,
      ]),
    };
    await pumpApp(tester, prefs, openLogTrip: false);

    // Mark Clinic's session paid by Zelle.
    await tester.tap(find.text('Clinic'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Need to bill'));
    await tester.tap(find.text('Need to bill'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paid').last);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '225'), findsOneWidget);
    await tester.tap(find.text('Zelle'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
    await tester.pumpAndSettle();
    await goBack(tester);

    await tester.tap(find.text('Billing').last);
    await tester.pumpAndSettle();
    // Opens on sessions: the paid one is under "Paid in 2026".
    expect(find.text('Paid in 2026'), findsOneWidget);
    expect(
      find.text('Nothing to bill. Every session is billed or paid.'),
      findsOneWidget,
    );
    expect(find.textContaining('Zelle · paid'), findsOneWidget);

    // The session's full details.
    await tester.tap(find.byTooltip('Session details'));
    await tester.pumpAndSettle();
    expect(find.text('Session details'), findsOneWidget);
    expect(find.text('9:00 AM – 12:00 PM'), findsOneWidget, reason: 'booked');
    expect(find.text('Zelle'), findsOneWidget);
    expect(find.text('Paid on'), findsOneWidget);
    expect(find.text('Edit billing'), findsOneWidget);
    expect(find.text('Send bill'), findsNothing, reason: 'already paid');
    await goBack(tester);

    await tester.tap(find.textContaining('Payments ('));
    await tester.pumpAndSettle();
    expect(find.text('Session 11/10/26'), findsOneWidget);
    expect(find.text('\$225.00'), findsWidgets);
    expect(find.text('received in 2026'), findsOneWidget);

    // Add an expense.
    await tester.tap(find.text('Expenses (0)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add expense'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Paid to'), 'Canva');
    await tester.enterText(find.widgetWithText(TextField, 'Amount'), '12.99');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('Canva'), findsOneWidget);
    expect(
      find.text('\$212.01'),
      findsOneWidget,
      reason: 'income less expenses',
    );
  });

  testWidgets('the client list can be searched and sorted', (tester) async {
    await pumpApp(tester, _savedPrefs, openLogTrip: false);
    expect(find.text('Clinic'), findsOneWidget);
    expect(find.text('Dentist'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Search clients'),
      'oak ave',
    );
    await tester.pumpAndSettle();
    expect(find.text('Dentist'), findsOneWidget);
    expect(find.text('Clinic'), findsNothing);
    expect(find.text('All clients (1)'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'nobody');
    await tester.pumpAndSettle();
    expect(find.textContaining('No clients match "nobody"'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    expect(find.text('All clients (2)'), findsOneWidget);

    // Z–A puts Dentist first.
    double top(String name) => tester.getTopLeft(find.text(name)).dy;
    expect(top('Clinic') < top('Dentist'), isTrue);
    await tester.tap(find.byTooltip('Sort'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Name (Z–A)'));
    await tester.pumpAndSettle();
    expect(top('Dentist') < top('Clinic'), isTrue);
  });
}

/// Signed out, but with calendar access (enough for the Calendar tab).
class _CalendarAccount implements GoogleAccountService {
  @override
  Future<GoogleSession?> restore() async => null;
  @override
  Future<GoogleSession> signIn() => throw UnimplementedError();
  @override
  Future<void> signOut() async {}
  @override
  Future<http.Client> grantAccess(String scope) async => http.Client();
  @override
  Future<http.Client?> access(String scope) async =>
      scope == calendarScope ? http.Client() : null;
}

class _FakeCalendar implements CalendarSource {
  @override
  Future<List<CalendarInfo>> calendars() async => const [
    CalendarInfo(id: 'me', name: 'Personal', color: 0xFF7986CB),
  ];

  @override
  Future<List<CalendarEvent>> events(
    List<String> ids,
    DateTime from,
    DateTime to,
  ) async => [
    CalendarEvent(
      id: 'e1',
      calendarId: 'me',
      title: 'Pilates',
      start: DateTime(2026, 11, 13, 10),
      end: DateTime(2026, 11, 13, 11),
    ),
  ];
}
