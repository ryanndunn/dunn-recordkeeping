import 'package:flutter_test/flutter_test.dart';
import 'package:mileage_log/models/lead.dart';

void main() {
  const header = [
    'Timestamp',
    'Name',
    'Phone number',
    'Email',
    'Address',
    'What can I help you with?',
    'How did you hear about me? If one of my previous clients referred '
        'you, please include their name.',
  ];

  test('form responses become leads, newest first', () {
    final leads = parseFormResponses([
      header,
      [
        '11/2/2026 9:15:00',
        'Pat Example',
        '555-0100',
        '',
        '1 Main St',
        'Garage',
        'Instagram',
      ],
      ['11/17/2026 14:03:22', 'Sam Sample', '555-0199', 's@example.com'],
    ]);
    expect([for (final l in leads) l.name], ['Sam Sample', 'Pat Example']);
    final pat = leads.last;
    expect(pat.submittedAt, DateTime(2026, 11, 2, 9, 15));
    expect(pat.phone, '555-0100');
    expect(pat.address, '1 Main St');
    expect(pat.help, 'Garage');
    expect(pat.heardFrom, 'Instagram');
    // Short rows (unanswered questions at the end) are fine.
    expect(leads.first.help, '');
  });

  test('columns are found by question, in any order', () {
    final leads = parseFormResponses([
      ['Email', 'Timestamp', 'Name'],
      ['a@example.com', '11/17/2026 8:00:00', 'Avery'],
    ]);
    expect(leads.single.email, 'a@example.com');
    expect(leads.single.name, 'Avery');
  });

  test('the same response always gets the same ID', () {
    List<Lead> read() => parseFormResponses([
      header,
      ['11/17/2026 14:03:22', 'Sam Sample'],
    ]);
    expect(read().single.id, read().single.id);
  });

  test('client notes keep what they wrote', () {
    final lead = parseFormResponses([
      header,
      ['11/2/2026 9:15:00', 'Pat', '', '', '', 'Garage', 'Jo Client'],
    ]).single;
    expect(
      lead.notesForClient((d) => '${d.month}/${d.day}'),
      'From the website form, 11/2.\n'
      'What can I help you with? Garage\n'
      'How they heard about us: Jo Client',
    );
  });
}
