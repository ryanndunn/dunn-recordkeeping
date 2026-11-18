import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mileage_log/models/job.dart';
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

    test('the trip ID and job ID columns are hidden', () {
      final hidden = {
        for (final r in formatRequests())
          if (r.updateDimensionProperties?.properties?.hiddenByUser == true)
            r.updateDimensionProperties!.range!.sheetId:
                r.updateDimensionProperties!.range!.startIndex,
      };
      expect(hidden, {1: 8, 3: 7});
    });

    test('a job becomes one row: date, times, hours, miles, clients', () {
      final job = Job(
        id: 'job-1',
        start: DateTime(2026, 11, 17, 8, 40),
        end: DateTime(2026, 11, 17, 12, 25),
        clients: const ['Jane Smith', 'Main St Clinic'],
      );
      expect(jobRow((job: job, miles: 42.3)), [
        '2026-11-17',
        '08:40',
        '12:25',
        3.75,
        42.3,
        'Jane Smith, Main St Clinic',
        '',
        'job-1',
      ]);
      expect(jobRow((job: job, miles: 0)).length, jobHeaders.length);
    });

    test('trip rows get dark, regular text; the header stays white', () {
      final rows = formatRequests()
          .map((r) => r.repeatCell)
          .where((c) => c != null && c.range!.sheetId == 1)
          .toList();
      final header = rows.firstWhere((c) => c!.range!.startRowIndex == 0)!;
      final data = rows.firstWhere((c) => c!.range!.startRowIndex == 1)!;
      final headerText = header.cell!.userEnteredFormat!.textFormat!;
      final dataText = data.cell!.userEnteredFormat!.textFormat!;
      expect(headerText.foregroundColorStyle!.rgbColor!.red, 1.0);
      expect(dataText.bold, isFalse);
      expect(data.range!.endRowIndex, isNull, reason: 'covers future rows');
      final ink = dataText.foregroundColorStyle!.rgbColor!;
      expect([ink.red, ink.green, ink.blue].every((c) => c! < 0.2), isTrue);
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
      // Inserting rows would copy the header's white text onto them.
      expect(requests[0].url.queryParameters['insertDataOption'], 'OVERWRITE');
      final body = jsonDecode(requests[0].body) as Map<String, dynamic>;
      expect((body['values'] as List).single, tripRow(trip));
      expect(requests[1].url.path, endsWith('sheet-1:batchUpdate'));
      expect(requests[1].body, contains('sortRange'));
    });

    test('dates are mm/dd/yy and times hh:mm AM/PM, on new and updated '
        'spreadsheets', () {
      String? pattern(List<sheets.Request> requests, int col) => requests
          .map((r) => r.repeatCell)
          .firstWhere(
            (c) =>
                c?.range?.sheetId == 1 &&
                c?.range?.startColumnIndex == col &&
                c?.cell?.userEnteredFormat?.numberFormat != null,
          )!
          .cell!
          .userEnteredFormat!
          .numberFormat!
          .pattern;
      for (final requests in [formatRequests(), restyleRequests()]) {
        expect(pattern(requests, 0), 'mm/dd/yy');
        expect(pattern(requests, 1), 'hh:mm AM/PM');
      }
    });

    MockClient spreadsheetWith(
      List<int> tabIds,
      List<http.Request> log, {
      String jobsTitle = 'Sessions',
    }) => MockClient((r) async {
      log.add(r);
      if (r.method == 'GET') {
        return http.Response(
          jsonEncode({
            'sheets': [
              for (final id in tabIds)
                {
                  'properties': {
                    'sheetId': id,
                    'title': id == 3 ? jobsTitle : 'Tab $id',
                  },
                },
            ],
          }),
          200,
          headers: _json,
        );
      }
      return http.Response('{}', 200, headers: _json);
    });

    test('updating an older spreadsheet adds the Jobs tab', () async {
      final requests = <http.Request>[];
      await GoogleMileageSheet(spreadsheetWith([1, 2], requests))
          .restyle('sheet-1');
      final bodies = [
        for (final r in requests)
          if (r.method != 'GET') r.body,
      ];
      expect(bodies[0], contains('addSheet'));
      expect(bodies[0], contains('"title":"Sessions"'));
      expect(bodies[1], contains('Hours'), reason: 'header row');
      expect(bodies[2], contains('addBanding'), reason: 'Jobs tab look');
    });

    test('an older "Jobs" tab is renamed "Sessions"', () async {
      final requests = <http.Request>[];
      await GoogleMileageSheet(
        spreadsheetWith([1, 2, 3], requests, jobsTitle: 'Jobs'),
      ).restyle('sheet-1');
      final bodies = [
        for (final r in requests)
          if (r.method != 'GET') r.body,
      ];
      expect(bodies[0], contains('updateSheetProperties'));
      expect(bodies[0], contains('"title":"Sessions"'));
      expect(bodies[1], contains('Session ID'), reason: 'header row');
    });

    test('restyling sends the current trip-row look', () async {
      final requests = <http.Request>[];
      final client = spreadsheetWith([1, 2, 3], requests);
      await GoogleMileageSheet(client).restyle('sheet-1');
      final update = requests.where((r) => r.method != 'GET').single;
      expect(update.url.path, endsWith('sheet-1:batchUpdate'));
      expect(
        jsonDecode(update.body),
        jsonDecode(
          jsonEncode(
            sheets.BatchUpdateSpreadsheetRequest(requests: restyleRequests()),
          ),
        ),
      );
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
