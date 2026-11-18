import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:http/http.dart' as http;

import '../models/job.dart';
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
const jobsTabTitle = 'Jobs';
const summaryTabTitle = 'Summary';
const _logSheetId = 1;
const _jobsSheetId = 3;
const _jobIdColumn = 'H';

/// Column layout of the "Jobs" tab: one row per job, from leaving for the
/// first client until arriving where the job ended.
const jobHeaders = <String>[
  'Date',
  'Start',
  'End',
  'Hours',
  'Miles',
  'Clients',
  'Notes',
  'Job ID',
];

/// A finished job and the miles driven during it.
typedef JobRecord = ({Job job, double miles});

/// One Jobs-tab row.
List<Object> jobRow(JobRecord r) {
  final s = r.job.start.toLocal();
  final e = (r.job.end ?? r.job.start).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  final hours = e.difference(s).inMinutes / 60;
  return [
    '${s.year}-${two(s.month)}-${two(s.day)}',
    '${two(s.hour)}:${two(s.minute)}',
    '${two(e.hour)}:${two(e.minute)}',
    (hours * 100).round() / 100,
    r.miles,
    r.job.clients.join(', '),
    r.job.startEstimated
        ? 'Start estimated (the phone didn\'t see you leave)'
        : '',
    r.job.id,
  ];
}

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

  /// Adds finished jobs as rows on the Jobs tab, sorted by date and time.
  Future<void> addJobs(String spreadsheetId, List<JobRecord> jobs);

  /// Brings a spreadsheet made by an older version up to date: adds the
  /// Jobs tab if missing, and fixes the trip rows' look (see
  /// [restyleRequests]).
  Future<void> restyle(String spreadsheetId);
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
          _jobsSheet(),
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
          sheets.ValueRange(range: "'$jobsTabTitle'!A1", values: [jobHeaders]),
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
        // Fill the empty rows below instead of inserting new ones: an
        // inserted row copies the formatting of the row above, which for
        // the first trip is the header (white bold text).
        insertDataOption: 'OVERWRITE',
      );
      await _api.spreadsheets.batchUpdate(
        sheets.BatchUpdateSpreadsheetRequest(
          requests: [_sortRequest(_logSheetId)],
        ),
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

  @override
  Future<void> addJobs(String spreadsheetId, List<JobRecord> jobs) async {
    if (jobs.isEmpty) return;
    await _guard(() async {
      await _api.spreadsheets.values.append(
        sheets.ValueRange(values: [for (final j in jobs) jobRow(j)]),
        spreadsheetId,
        "'$jobsTabTitle'!A:$_jobIdColumn",
        valueInputOption: 'USER_ENTERED',
        insertDataOption: 'OVERWRITE',
      );
      await _api.spreadsheets.batchUpdate(
        sheets.BatchUpdateSpreadsheetRequest(
          requests: [_sortRequest(_jobsSheetId)],
        ),
        spreadsheetId,
      );
    });
  }

  @override
  Future<void> restyle(String spreadsheetId) => _guard(() async {
    final existing = await _api.spreadsheets.get(
      spreadsheetId,
      $fields: 'sheets.properties.sheetId',
    );
    final hasJobs = (existing.sheets ?? const []).any(
      (s) => s.properties?.sheetId == _jobsSheetId,
    );
    if (!hasJobs) {
      await _api.spreadsheets.batchUpdate(
        sheets.BatchUpdateSpreadsheetRequest(
          requests: [
            sheets.Request(
              addSheet: sheets.AddSheetRequest(
                properties: _jobsSheet().properties,
              ),
            ),
          ],
        ),
        spreadsheetId,
      );
      await _api.spreadsheets.values.update(
        sheets.ValueRange(values: [jobHeaders]),
        spreadsheetId,
        "'$jobsTabTitle'!A1",
        valueInputOption: 'RAW',
      );
    }
    await _api.spreadsheets.batchUpdate(
      sheets.BatchUpdateSpreadsheetRequest(
        requests: [...restyleRequests(), if (!hasJobs) ...jobsFormatRequests()],
      ),
      spreadsheetId,
    );
  });

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

sheets.Sheet _jobsSheet() => sheets.Sheet(
  properties: sheets.SheetProperties(
    sheetId: _jobsSheetId,
    title: jobsTabTitle,
    index: 1,
    gridProperties: sheets.GridProperties(
      frozenRowCount: 1,
      columnCount: jobHeaders.length,
    ),
  ),
);

sheets.Request _sortRequest(int sheetId) => sheets.Request(
  sortRange: sheets.SortRangeRequest(
    range: _range(sheetId, startRow: 1),
    sortSpecs: [
      sheets.SortSpec(dimensionIndex: 0, sortOrder: 'ASCENDING'),
      sheets.SortSpec(dimensionIndex: 1, sortOrder: 'ASCENDING'),
    ],
  ),
);

const _green = 0x2E7D32;
const _white = 0xFFFFFF;
const _lightGreen = 0xEEF5EA;

/// Near-black text. Set explicitly (not left to the default) so it stays
/// dark on the white and light green bands, including in dark mode.
const _ink = 0x202124;

/// Every row below the header (trips, or [sheetId]'s rows): dark,
/// regular-weight text.
sheets.Request dataRowsStyle({int sheetId = _logSheetId, int columns = 0}) =>
    sheets.Request(
      repeatCell: sheets.RepeatCellRequest(
        range: _range(
          sheetId,
          startRow: 1,
          startCol: 0,
          endCol: columns == 0 ? sheetHeaders.length : columns,
        ),
        cell: sheets.CellData(
          userEnteredFormat: sheets.CellFormat(
            textFormat: sheets.TextFormat(
              bold: false,
              foregroundColorStyle: _color(_ink),
            ),
          ),
        ),
        fields:
            'userEnteredFormat.textFormat.bold,'
            'userEnteredFormat.textFormat.foregroundColorStyle',
      ),
    );

/// Trip dates as mm/dd/yy.
sheets.Request _logDateFormat() =>
    _numberFormat(_logSheetId, 0, 'DATE', 'mm/dd/yy');

/// Trip times as hh:mm AM/PM (e.g. 09:05 AM, 02:30 PM).
sheets.Request _logTimeFormat() =>
    _numberFormat(_logSheetId, 1, 'TIME', 'hh:mm AM/PM');

/// Brings a spreadsheet made by an older version up to the current look:
/// dark trip-row text, mm/dd/yy dates and hh:mm AM/PM times.
List<sheets.Request> restyleRequests() => [
  dataRowsStyle(),
  _logDateFormat(),
  _logTimeFormat(),
];

/// The Jobs tab's look: like the trips tab, with hours to two decimals.
List<sheets.Request> jobsFormatRequests() => [
  _bold(_jobsSheetId, row: 0, background: _green, foreground: _white),
  dataRowsStyle(sheetId: _jobsSheetId, columns: jobHeaders.length),
  sheets.Request(
    addBanding: sheets.AddBandingRequest(
      bandedRange: sheets.BandedRange(
        range: _range(_jobsSheetId, startCol: 0, endCol: jobHeaders.length),
        rowProperties: sheets.BandingProperties(
          headerColorStyle: _color(_green),
          firstBandColorStyle: _color(_white),
          secondBandColorStyle: _color(_lightGreen),
        ),
      ),
    ),
  ),
  _numberFormat(_jobsSheetId, 0, 'DATE', 'mm/dd/yy'),
  _numberFormat(_jobsSheetId, 1, 'TIME', 'hh:mm AM/PM'),
  _numberFormat(_jobsSheetId, 2, 'TIME', 'hh:mm AM/PM'),
  _numberFormat(_jobsSheetId, 3, 'NUMBER', '0.00'),
  _numberFormat(_jobsSheetId, 4, 'NUMBER', '0.0'),
  for (final (col, px) in [
    (0, 100),
    (1, 90),
    (2, 90),
    (3, 70),
    (4, 70),
    (5, 260),
    (6, 280),
  ])
    _width(_jobsSheetId, col, px),
  sheets.Request(
    updateDimensionProperties: sheets.UpdateDimensionPropertiesRequest(
      range: sheets.DimensionRange(
        sheetId: _jobsSheetId,
        dimension: 'COLUMNS',
        startIndex: 7,
        endIndex: 8,
      ),
      properties: sheets.DimensionProperties(hiddenByUser: true),
      fields: 'hiddenByUser',
    ),
  ),
];

/// Formatting for a new spreadsheet: bold green header, banded rows with
/// dark text, readable date/time/miles formats, sized columns, hidden
/// trip ID.
List<sheets.Request> formatRequests() {
  const green = _green;
  const white = _white;
  const lightGreen = _lightGreen;
  return [
    // Mileage Log
    _bold(_logSheetId, row: 0, background: green, foreground: white),
    dataRowsStyle(),
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
    _logDateFormat(),
    _logTimeFormat(),
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
    // Jobs
    ...jobsFormatRequests(),
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
