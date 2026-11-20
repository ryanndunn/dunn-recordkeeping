import 'package:material_ui/material_ui.dart';

import '../../models/saved_address.dart';

String _two(int n) => n.toString().padLeft(2, '0');

/// mm/dd/yy, the same as the spreadsheet.
String formatShortDate(DateTime d) =>
    '${_two(d.month)}/${_two(d.day)}/${_two(d.year % 100)}';

/// "$75" or "$82.50".
String formatDollars(double amount) => amount == amount.roundToDouble()
    ? '\$${amount.toStringAsFixed(0)}'
    : '\$${amount.toStringAsFixed(2)}';

/// The rate as typed into the edit box: "75" or "82.5".
String rateText(double rate) =>
    rate == rate.roundToDouble() ? rate.toStringAsFixed(0) : rate.toString();

/// Parses a typed rate ("75", "$82.50"); null if it isn't a usable amount.
double? parseRate(String text) {
  final v = double.tryParse(text.replaceAll(RegExp(r'[\s$,]'), ''));
  return v == null || v <= 0 ? null : v;
}

/// Icon for each status.
IconData statusIcon(ClientStatus s) => switch (s) {
  ClientStatus.newClient => Icons.fiber_new_outlined,
  ClientStatus.consultation => Icons.event_outlined,
  ClientStatus.policyDoc => Icons.edit_document,
  ClientStatus.active => Icons.check_circle,
  ClientStatus.archived => Icons.inventory_2_outlined,
};

/// Background and text colors for each status.
({Color bg, Color fg}) statusColors(ClientStatus s, ColorScheme scheme) =>
    switch (s) {
      // Pink, so new clients stand out.
      ClientStatus.newClient =>
        scheme.brightness == Brightness.dark
            ? (bg: const Color(0xFF7A2950), fg: const Color(0xFFFFD9E6))
            : (bg: const Color(0xFFFFD9E6), fg: const Color(0xFF7A2950)),
      ClientStatus.consultation || ClientStatus.policyDoc => (
        bg: scheme.tertiaryContainer,
        fg: scheme.onTertiaryContainer,
      ),
      ClientStatus.active => (
        bg: scheme.primaryContainer,
        fg: scheme.onPrimaryContainer,
      ),
      ClientStatus.archived => (
        bg: scheme.surfaceContainerHighest,
        fg: scheme.onSurfaceVariant,
      ),
    };

/// A small status label, e.g. "Pending consultation". With [dropdown], it
/// has an arrow to show it opens a menu.
class ClientStatusBadge extends StatelessWidget {
  const ClientStatusBadge({
    super.key,
    required this.client,
    this.dropdown = false,
  });

  final SavedAddress client;
  final bool dropdown;

  @override
  Widget build(BuildContext context) {
    final status = client.status;
    final c = statusColors(status, Theme.of(context).colorScheme);
    return Container(
      padding: EdgeInsets.fromLTRB(8, 2, dropdown ? 2 : 8, 2),
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(statusIcon(status), size: 14, color: c.fg),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              status.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium
                  ?.copyWith(color: c.fg),
            ),
          ),
          if (dropdown) Icon(Icons.arrow_drop_down, size: 18, color: c.fg),
        ],
      ),
    );
  }
}
