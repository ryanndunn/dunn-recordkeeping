import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:http/http.dart' as http;

import '../models/trip.dart';

/// Column layout of the "Mileage Log" tab. The trip ID column is hidden;
/// the app uses it to find a row again (to delete it).
const sheetHeaders = <String>[
  'Date',
  'Time',
  'Appointment',
  'Destination address',
  'From',
  'Miles',
  'Source',
  'Notes',
  'Trip ID',
];

const logTabTitle = 'Mileage Log';
const summaryTabTitle = 'Summary';
const _logSheetId = 1;
const _summarySheetId = 2;
const _idColumn = 'I';

/// One spreadsheet row for [trip]. Date and time are written as text the
/// sheet turns into real dates (so the Summary formulas can add them up).
List<Object> tripRow(Trip trip) {
  final d = trip.date.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return [
    '${d.year}-${two(d.month)}-${two(d.day)}',
    '${two(d.hour)}:${two(d.minute)}',
    trip.to.label,
    trip.to.address,
    trip.from.label,
    trip.miles,
    trip.estimated ? 'Estimate' : 'Google Maps',
    trip.notes,
    trip.id,
  ];
}

class SheetException implements Exception {
  const SheetException(this.message, {this.missing = false});
  final String message;

  /// The spreadsheet no longer exists (deleted, or access removed).
  final bool missing;

  @override
  String toString() => message;
}

/// The user's mileage spreadsheet in Google Sheets.
abstract class MileageSheet {
  /// Creates and formats a new spreadsheet. Returns its ID.
  Future<String> create({double? ratePerMile});

  /// Adds [trips] as rows, then keeps the log sorted by date and time.
  Future<void> addTrips(String spreadsheetId, List<Trip> trips);

  /// Removes the rows for these trip IDs (missing ones are ignored).
  Future<void> deleteTrips(String spreadsheetId, Set<String> tripIds);
}

class GoogleMileageSheet implements MileageSheet {
  GoogleMileageSheet(http.Client client) : _api = sheets.SheetsApi(client);

  final sheets.SheetsApi _api;

  @override
  Future<String> create({double? ratePerMile}) => _guard(() async {
    final created = await _api.spreadsheets.create(
      sheets.Spreadsheet(
        properties: sheets.SpreadsheetProperties(title: 'Mileage Log'),
        sheets: [
          sheets.Sheet(
            properties: sheets.SheetProperties(
              sheetId: _logSheetId,
              title: logTabTitle,
              gridProperties: sheets.GridProperties(
                frozenRowCount: 1,
                columnCount: sheetHeaders.length,
              ),
            ),
          ),
          sheets.Sheet(
            properties: sheets.SheetProperties(
              sheetId: _summarySheetId,
              title: summaryTabTitle,
              gridProperties: sheets.GridProperties(columnCount: 6),
            ),
          ),
        ],
      ),
      $fields: 'spreadsheetId',
    );
    final id = created.spreadsheetId!;
    await _api.spreadsheets.values.batchUpdate(
      sheets.BatchUpdateValuesRequest(
        valueInputOption: 'USER_ENTERED',
        data: [
          sheets.ValueRange(range: "'$logTabTitle'!A1", values: [sheetHeaders]),
          sheets.ValueRange(
            range: "'$summaryTabTitle'!A1",
            values: summaryValues(ratePerMile),
          ),
        ],
      ),
      id,
    );
    await _api.spreadsheets.batchUpdate(
      sheets.BatchUpdateSpreadsheetRequest(requests: formatRequests()),
      id,
    );
    return id;
  });

  @override
  Future<void> addTrips(String spreadsheetId, List<Trip> trips) async {
    if (trips.isEmpty) return;
    await _guard(() async {
      await _api.spreadsheets.values.append(
        sheets.ValueRange(values: [for (final t in trips) tripRow(t)]),
        spreadsheetId,
        "'$logTabTitle'!A:$_idColumn",
        valueInputOption: 'USER_ENTERED',
        insertDataOption: 'INSERT_ROWS',
      );
      await _api.spreadsheets.batchUpdate(
        sheets.BatchUpdateSpreadsheetRequest(requests: [_sortRequest()]),
        spreadsheetId,
      );
    });
  }

  @override
  Future<void> deleteTrips(String spreadsheetId, Set<String> tripIds) async {
    if (tripIds.isEmpty) return;
    await _guard(() async {
      final column = await _api.spreadsheets.values.get(
        spreadsheetId,
        "'$logTabTitle'!$_idColumn:$_idColumn",
      );
      final rows = <int>[];
      final values = column.values ?? const [];
      for (var i = 0; i < values.length; i++) {
        final cell = values[i].isEmpty ? null : values[i].first;
        if (tripIds.contains(cell)) rows.add(i);
      }
      if (rows.isEmpty) return;
      // Delete from the bottom up so earlier row numbers stay valid.
      rows.sort((a, b) => b.compareTo(a));
      await _api.spreadsheets.batchUpdate(
        sheets.BatchUpdateSpreadsheetRequest(
          requests: [
            for (final r in rows)
              sheets.Request(
                deleteDimension: sheets.DeleteDimensionRequest(
                  range: sheets.DimensionRange(
                    sheetId: _logSheetId,
                    dimension: 'ROWS',
                    startIndex: r,
                    endIndex: r + 1,
                  ),
                ),
              ),
          ],
        ),
        spreadsheetId,
      );
    });
  }

  Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on sheets.DetailedApiRequestError catch (e) {
      if (e.status == 404) {
        throw const SheetException(
          'The mileage spreadsheet was deleted or can\'t be opened.',
          missing: true,
        );
      }
      if (e.status == 403) {
        throw SheetException(
          'Google refused access to the spreadsheet (${e.message}). Check '
          'that the Google Sheets API is turned on (setup guide step 2).',
        );
      }
      throw SheetException('Google Sheets error ${e.status}: ${e.message}');
    } on SheetException {
      rethrow;
    } catch (e) {
      throw SheetException('Can\'t reach Google Sheets right now ($e).');
    }
  }
}

// ------------------------------------------------------------ sheet layout

sheets.ColorStyle _color(int rgb) => sheets.ColorStyle(
  rgbColor: sheets.Color(
    red: ((rgb >> 16) & 0xff) / 255,
    green: ((rgb >> 8) & 0xff) / 255,
    blue: (rgb & 0xff) / 255,
  ),
);

sheets.GridRange _range(
  int sheetId, {
  int? startRow,
  int? endRow,
  int? startCol,
  int? endCol,
}) => sheets.GridRange(
  sheetId: sheetId,
  startRowIndex: startRow,
  endRowIndex: endRow,
  startColumnIndex: startCol,
  endColumnIndex: endCol,
);

sheets.Request _numberFormat(
  int sheetId,
  int col,
  String type,
  String pattern, {
  int startRow = 1,
  int? endRow,
}) => sheets.Request(
  repeatCell: sheets.RepeatCellRequest(
    range: _range(
      sheetId,
      startRow: startRow,
      endRow: endRow,
      startCol: col,
      endCol: col + 1,
    ),
    cell: sheets.CellData(
      userEnteredFormat: sheets.CellFormat(
        numberFormat: sheets.NumberFormat(type: type, pattern: pattern),
      ),
    ),
    fields: 'userEnteredFormat.numberFormat',
  ),
);

sheets.Request _width(int sheetId, int col, int pixels) => sheets.Request(
  updateDimensionProperties: sheets.UpdateDimensionPropertiesRequest(
    range: sheets.DimensionRange(
      sheetId: sheetId,
      dimension: 'COLUMNS',
      startIndex: col,
      endIndex: col + 1,
    ),
    properties: sheets.DimensionProperties(pixelSize: pixels),
    fields: 'pixelSize',
  ),
);

sheets.Request _bold(
  int sheetId, {
  required int row,
  int? endRow,
  int? fontSize,
  int? background,
  int? foreground,
}) => sheets.Request(
  repeatCell: sheets.RepeatCellRequest(
    range: _range(sheetId, startRow: row, endRow: endRow ?? row + 1),
    cell: sheets.CellData(
      userEnteredFormat: sheets.CellFormat(
        textFormat: sheets.TextFormat(
          bold: true,
          fontSize: fontSize,
          foregroundColorStyle: foreground == null ? null : _color(foreground),
        ),
        backgroundColorStyle: background == null ? null : _color(background),
      ),
    ),
    fields: 'userEnteredFormat(textFormat,backgroundColorStyle)',
  ),
);

sheets.Request _sortRequest() => sheets.Request(
  sortRange: sheets.SortRangeRequest(
    range: _range(_logSheetId, startRow: 1),
    sortSpecs: [
      sheets.SortSpec(dimensionIndex: 0, sortOrder: 'ASCENDING'),
      sheets.SortSpec(dimensionIndex: 1, sortOrder: 'ASCENDING'),
    ],
  ),
);

/// Formatting for a new spreadsheet: bold green header, banded rows,
/// readable date/time/miles formats, sized columns, hidden trip ID.
List<sheets.Request> formatRequests() {
  const green = 0x2E7D32;
  const white = 0xFFFFFF;
  const lightGreen = 0xEEF5EA;
  return [
    // Mileage Log
    _bold(_logSheetId, row: 0, background: green, foreground: white),
    sheets.Request(
      addBanding: sheets.AddBandingRequest(
        bandedRange: sheets.BandedRange(
          range: _range(_logSheetId, startCol: 0, endCol: sheetHeaders.length),
          rowProperties: sheets.BandingProperties(
            headerColorStyle: _color(green),
            firstBandColorStyle: _color(white),
            secondBandColorStyle: _color(lightGreen),
          ),
        ),
      ),
    ),
    _numberFormat(_logSheetId, 0, 'DATE', 'ddd, mmm d, yyyy'),
    _numberFormat(_logSheetId, 1, 'TIME', 'h:mm am/pm'),
    _numberFormat(_logSheetId, 5, 'NUMBER', '0.0'),
    for (final (col, px) in [
      (0, 130),
      (1, 80),
      (2, 200),
      (3, 320),
      (4, 180),
      (5, 70),
      (6, 110),
      (7, 240),
    ])
      _width(_logSheetId, col, px),
    sheets.Request(
      updateDimensionProperties: sheets.UpdateDimensionPropertiesRequest(
        range: sheets.DimensionRange(
          sheetId: _logSheetId,
          dimension: 'COLUMNS',
          startIndex: 8,
          endIndex: 9,
        ),
        properties: sheets.DimensionProperties(hiddenByUser: true),
        fields: 'hiddenByUser',
      ),
    ),
    // Summary
    _bold(_summarySheetId, row: 0, fontSize: 14),
    _bold(_summarySheetId, row: 5, background: green, foreground: white),
    _bold(_summarySheetId, row: 18),
    _numberFormat(
      _summarySheetId,
      1,
      'CURRENCY',
      r'$0.000',
      startRow: 3,
      endRow: 4,
    ),
    _numberFormat(_summarySheetId, 0, 'DATE', 'mmmm', startRow: 6, endRow: 18),
    _numberFormat(_summarySheetId, 2, 'NUMBER', '0.0', startRow: 6, endRow: 19),
    _numberFormat(
      _summarySheetId,
      3,
      'CURRENCY',
      r'$#,##0.00',
      startRow: 6,
      endRow: 19,
    ),
    _width(_summarySheetId, 0, 160),
    for (final col in [1, 2, 3]) _width(_summarySheetId, col, 110),
  ];
}

/// The Summary tab: miles (and dollar amount, if a rate is set) for each
/// month of the year in B3, all calculated by formulas from the log.
List<List<Object>> summaryValues(double? ratePerMile) {
  const log = "'$logTabTitle'";
  String countIf(int r) =>
      '=COUNTIFS($log!\$A:\$A,">="&A$r,$log!\$A:\$A,"<"&EDATE(A$r,1))';
  String sumIf(int r) =>
      '=SUMIFS($log!\$F:\$F,$log!\$A:\$A,">="&A$r,$log!\$A:\$A,"<"&EDATE(A$r,1))';
  return [
    ['Mileage summary'],
    [],
    ['Year', '=YEAR(TODAY())', 'Change the year to see another year'],
    [
      'Rate per mile',
      ratePerMile ?? '',
      'Optional: fills in the Amount column',
    ],
    [],
    ['Month', 'Trips', 'Miles', 'Amount'],
    for (var m = 1; m <= 12; m++)
      [
        '=DATE(\$B\$3,$m,1)',
        countIf(m + 6),
        sumIf(m + 6),
        '=IF(\$B\$4="","",C${m + 6}*\$B\$4)',
      ],
    ['Total', '=SUM(B7:B18)', '=SUM(C7:C18)', '=IF(\$B\$4="","",SUM(D7:D18))'],
    [],
    [
      'Includes trips marked "Estimate" in the Source column, which were '
          'logged before Google driving distances were set up.',
    ],
  ];
}
