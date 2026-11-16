import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mileage_log/models/place.dart';
import 'package:mileage_log/models/trip.dart';
import 'package:mileage_log/services/mileage_sheet.dart';

const _json = {'content-type': 'application/json; charset=utf-8'};

void main() {
  final trip = Trip(
    id: 'trip-1',
    date: DateTime(2026, 11, 15, 9, 5),
    from: const Place(label: 'Home', address: '1 Home Rd'),
    to: const Place(
      label: 'Main St Clinic',
      address: '123 Main St, Springfield, IL 62701, USA',
    ),
    miles: 12.4,
    notes: 'checkup',
  );

  group('row layout', () {
    test('a trip becomes one readable row with the ID last', () {
      expect(tripRow(trip), [
        '2026-11-15',
        '09:05',
        'Main St Clinic',
        '123 Main St, Springfield, IL 62701, USA',
        'Home',
        12.4,
        'Google Maps',
        'checkup',
        'trip-1',
      ]);
      expect(tripRow(trip).length, sheetHeaders.length);
    });

    test('estimated trips say so in the Source column', () {
      final est = Trip(
        id: 'x',
        date: trip.date,
        from: trip.from,
        to: trip.to,
        miles: 3,
        estimated: true,
      );
      expect(tripRow(est)[6], 'Estimate');
    });

    test('summary has 12 months of formulas reading the log', () {
      final rows = summaryValues(0.7);
      expect(rows[3], ['Rate per mile', 0.7, isA<String>()]);
      expect(rows[5], ['Month', 'Trips', 'Miles', 'Amount']);
      // January is row 7 and refers to its own row.
      expect(rows[6][0], r'=DATE($B$3,1,1)');
      expect(rows[6][2], contains('>="&A7'));
      expect(rows[6][2], contains("'Mileage Log'!\$F:\$F"));
      // December is row 18; totals on row 19.
      expect(rows[17][0], r'=DATE($B$3,12,1)');
      expect(rows[18][0], 'Total');
      expect(rows[18][2], '=SUM(C7:C18)');
    });

    test('the trip ID column is hidden', () {
      final hide = formatRequests().where(
        (r) => r.updateDimensionProperties?.properties?.hiddenByUser == true,
      );
      expect(hide.single.updateDimensionProperties!.range!.startIndex, 8);
    });
  });

  group('Google Sheets calls', () {
    test('adding trips appends rows, then sorts by date and time', () async {
      final requests = <http.Request>[];
      final client = MockClient((r) async {
        requests.add(r);
        return http.Response('{}', 200, headers: _json);
      });
      await GoogleMileageSheet(client).addTrips('sheet-1', [trip]);

      expect(requests, hasLength(2));
      expect(requests[0].url.path, contains('/spreadsheets/sheet-1/values/'));
      expect(requests[0].url.path, contains(':append'));
      expect(
        requests[0].url.queryParameters['valueInputOption'],
        'USER_ENTERED',
      );
      final body = jsonDecode(requests[0].body) as Map<String, dynamic>;
      expect((body['values'] as List).single, tripRow(trip));
      expect(requests[1].url.path, endsWith('sheet-1:batchUpdate'));
      expect(requests[1].body, contains('sortRange'));
    });

    test('deleting finds rows by trip ID and removes them bottom-up', () async {
      final requests = <http.Request>[];
      final client = MockClient((r) async {
        requests.add(r);
        if (r.method == 'GET') {
          return http.Response(
            jsonEncode({
              'values': [
                ['Trip ID'],
                ['a'],
                ['b'],
                [],
                ['c'],
              ],
            }),
            200,
            headers: _json,
          );
        }
        return http.Response('{}', 200, headers: _json);
      });
      await GoogleMileageSheet(client).deleteTrips('s', {'a', 'c', 'zzz'});

      final batch = jsonDecode(requests.last.body) as Map<String, dynamic>;
      final starts = [
        for (final r in batch['requests'] as List)
          r['deleteDimension']['range']['startIndex'],
      ];
      expect(starts, [4, 1]);
    });

    test('a deleted spreadsheet is reported as missing', () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'error': {
              'code': 404,
              'message': 'Requested entity was not found.',
            },
          }),
          404,
          headers: _json,
        ),
      );
      expect(
        () => GoogleMileageSheet(client).addTrips('gone', [trip]),
        throwsA(
          isA<SheetException>().having((e) => e.missing, 'missing', true),
        ),
      );
    });

    test('no network is a plain (retryable) error', () async {
      final client = MockClient((_) async => throw http.ClientException('x'));
      expect(
        () => GoogleMileageSheet(client).addTrips('s', [trip]),
        throwsA(
          isA<SheetException>().having((e) => e.missing, 'missing', false),
        ),
      );
    });
  });
}
