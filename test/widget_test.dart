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
}) async {
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

    await tester.tap(find.text('Clients'));
    await tester.pumpAndSettle();
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
    await tester.tap(find.text('Clients'));
    await tester.pumpAndSettle();
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
    await tester.tap(find.text('Clients'));
    await tester.pumpAndSettle();
    expect(find.textContaining('not verified'), findsOneWidget);
  });

  testWidgets('a client keeps a phone number and email', (tester) async {
    await pumpApp(tester, _savedPrefs);
    await tester.tap(find.text('Clients'));
    await tester.pumpAndSettle();
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

    // Editing keeps the details.
    await tester.tap(find.text('Jane Smith'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'jane@example.com'), findsOneWidget);
    expect(find.widgetWithText(TextField, '(309) 555-0142'), findsOneWidget);
  });
}
