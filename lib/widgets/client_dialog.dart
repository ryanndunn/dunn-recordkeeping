import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../models/place.dart';
import '../models/saved_address.dart';
import 'address_search_field.dart';

typedef ClientInput = ({String name, String email, String phone, Place place});

/// Asks for a client's name, Google-verified address, phone and email.
/// Returns null if cancelled.
///
/// Pass [client] to edit one, or [initialPlace] to start a new client at an
/// address the user already picked. [prefill] fills in details someone
/// gave (e.g. on the website's form); its address is shown as a hint to
/// search for. An address counts as already picked
/// only if it carries a Google place ID; older unverified entries must be
/// searched again.
Future<ClientInput?> showClientDialog(
  BuildContext context, {
  required String title,
  SavedAddress? client,
  Place? initialPlace,
  String saveLabel = 'Save',
  ({String name, String phone, String email, String address})? prefill,
}) {
  return showDialog<ClientInput>(
    context: context,
    builder: (_) => _ClientDialog(
      title: title,
      client: client,
      initialPlace: client?.toPlace() ?? initialPlace,
      saveLabel: saveLabel,
      prefill: prefill,
    ),
  );
}

/// A loose check that catches typos like a missing @, not a full validator.
bool looksLikeEmail(String s) =>
    RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(s.trim());

class _ClientDialog extends StatefulWidget {
  const _ClientDialog({
    required this.title,
    required this.client,
    required this.initialPlace,
    required this.saveLabel,
    this.prefill,
  });

  final ({String name, String phone, String email, String address})? prefill;
  final String title;
  final SavedAddress? client;
  final Place? initialPlace;
  final String saveLabel;

  @override
  State<_ClientDialog> createState() => _ClientDialogState();
}

class _ClientDialogState extends State<_ClientDialog> {
  late final _name = TextEditingController(
    text:
        widget.client?.name ??
        widget.prefill?.name ??
        widget.initialPlace?.label ??
        '',
  );
  late final _phone = TextEditingController(
    text: widget.client?.phone ?? widget.prefill?.phone ?? '',
  );
  late final _email = TextEditingController(
    text: widget.client?.email ?? widget.prefill?.email ?? '',
  );
  late Place? _picked = widget.initialPlace?.placeId != null
      ? widget.initialPlace
      : null;
  bool _nameError = false;
  bool _emailError = false;

  bool get _unverifiedOriginal =>
      widget.initialPlace != null && widget.initialPlace!.placeId == null;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _email.dispose();
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
    final email = _email.text.trim();
    setState(() {
      _nameError = name.isEmpty;
      _emailError = email.isNotEmpty && !looksLikeEmail(email);
    });
    if (_nameError || _emailError || _picked == null) return;
    Navigator.of(context).pop((
      name: name,
      email: email,
      phone: _phone.text.trim(),
      place: _picked!,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                autofocus: _name.text.isEmpty,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: 'Name',
                  hintText: 'e.g. Jane Smith',
                  prefixIcon: const Icon(Icons.person_outline),
                  errorText: _nameError ? 'Required' : null,
                ),
                onChanged: (_) {
                  if (_nameError) setState(() => _nameError = false);
                },
              ),
              const SizedBox(height: 16),
              AddressSearchField(
                labelText: 'Address',
                initialText: _picked?.address ?? '',
                onPicked: _onPicked,
                onEdited: () => setState(() => _picked = null),
              ),
              if (widget.prefill case final p?
                  when p.address.isNotEmpty && _picked == null) ...[
                const SizedBox(height: 8),
                Text(
                  'From the form: "${p.address}". Search for it to pick it '
                  'from Google Maps.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
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
                controller: _phone,
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.next,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9+()\-. x]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Phone (optional)',
                  prefixIcon: Icon(Icons.phone_outlined),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: 'Email (optional)',
                  prefixIcon: const Icon(Icons.email_outlined),
                  errorText: _emailError ? 'Check the email address' : null,
                ),
                onChanged: (_) {
                  if (_emailError) setState(() => _emailError = false);
                },
                onSubmitted: (_) => _submit(),
              ),
            ],
          ),
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
