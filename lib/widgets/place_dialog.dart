import 'package:material_ui/material_ui.dart';

import '../models/place.dart';
import 'address_search_field.dart';

typedef PlaceInput = ({String name, Place place});

/// Asks for a name and a Google-verified address. Returns null if cancelled.
///
/// [initialPlace] counts as already picked only if it carries a Google place
/// ID; older unverified entries must be searched again.
Future<PlaceInput?> showPlaceDialog(
  BuildContext context, {
  required String title,
  String initialName = '',
  Place? initialPlace,
  String nameHint = 'e.g. Dr. Patel, Main St Clinic',
  String saveLabel = 'Save',
}) {
  return showDialog<PlaceInput>(
    context: context,
    builder: (_) => _PlaceDialog(
      title: title,
      initialName: initialName,
      initialPlace: initialPlace,
      nameHint: nameHint,
      saveLabel: saveLabel,
    ),
  );
}

class _PlaceDialog extends StatefulWidget {
  const _PlaceDialog({
    required this.title,
    required this.initialName,
    required this.initialPlace,
    required this.nameHint,
    required this.saveLabel,
  });

  final String title;
  final String initialName;
  final Place? initialPlace;
  final String nameHint;
  final String saveLabel;

  @override
  State<_PlaceDialog> createState() => _PlaceDialogState();
}

class _PlaceDialogState extends State<_PlaceDialog> {
  late final _name = TextEditingController(text: widget.initialName);
  late Place? _picked = widget.initialPlace?.placeId != null
      ? widget.initialPlace
      : null;
  bool _showNameError = false;

  bool get _unverifiedOriginal =>
      widget.initialPlace != null && widget.initialPlace!.placeId == null;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _onPicked(Place place, _) async {
    setState(() {
      _picked = place;
      // Fill the name from Google (business name or street line) if blank.
      if (_name.text.trim().isEmpty) _name.text = place.label;
    });
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _showNameError = true);
      return;
    }
    if (_picked == null) return;
    Navigator.of(context).pop((name: name, place: _picked!));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AddressSearchField(
              labelText: 'Address',
              autofocus: _picked == null,
              initialText: _picked?.address ?? '',
              onPicked: _onPicked,
              onEdited: () => setState(() => _picked = null),
            ),
            if (_unverifiedOriginal && _picked == null) ...[
              const SizedBox(height: 8),
              Text(
                'Currently "${widget.initialPlace!.address}", which wasn\'t '
                'picked from Google Maps. Search for it to verify.',
                style: TextStyle(color: scheme.error),
              ),
            ],
            if (_picked != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.verified, size: 18, color: scheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _picked!.address,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: 'Name',
                hintText: widget.nameHint,
                errorText: _showNameError ? 'Required' : null,
              ),
              onChanged: (_) {
                if (_showNameError) setState(() => _showNameError = false);
              },
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _picked == null ? null : _submit,
          child: Text(widget.saveLabel),
        ),
      ],
    );
  }
}
