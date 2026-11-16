import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';

import '../models/place.dart';
import '../models/saved_address.dart';
import '../services/places_service.dart';
import '../state/providers.dart';

const _uuid = Uuid();

/// A row in the dropdown: one of the user's saved addresses, or a Google
/// Maps result.
sealed class AddressOption {
  const AddressOption();
}

class SavedOption extends AddressOption {
  const SavedOption(this.address);
  final SavedAddress address;
}

class GoogleOption extends AddressOption {
  const GoogleOption(this.suggestion);
  final PlaceSuggestion suggestion;
}

/// Called with the chosen place. [saved] is set when the user picked one of
/// their saved addresses.
typedef AddressPicked = Future<void> Function(Place place, SavedAddress? saved);

/// Address box that only accepts addresses picked from Google Maps
/// autocomplete (or, with [includeSaved], from the saved list, whose entries
/// came from Google too). Free-typed text is never accepted.
class AddressSearchField extends ConsumerStatefulWidget {
  const AddressSearchField({
    super.key,
    required this.onPicked,
    this.onEdited,
    this.includeSaved = false,
    this.clearAfterPick = false,
    this.enabled = true,
    this.busy = false,
    this.autofocus = false,
    this.labelText = 'Address',
    this.initialText = '',
    this.biasNear,
  });

  final AddressPicked onPicked;

  /// Called when the user changes the text after picking, so the parent can
  /// forget the earlier pick.
  final VoidCallback? onEdited;

  final bool includeSaved;
  final bool clearAfterPick;
  final bool enabled;
  final bool busy;
  final bool autofocus;
  final String labelText;
  final String initialText;

  /// Prefer Google results near here (usually home).
  final Place? biasNear;

  @override
  ConsumerState<AddressSearchField> createState() => _AddressSearchFieldState();
}

class _AddressSearchFieldState extends ConsumerState<AddressSearchField> {
  late final _controller = TextEditingController(text: widget.initialText);
  final _focus = FocusNode();

  /// Google bills autocomplete keystrokes + the final details lookup as one
  /// session when they share a token.
  String _session = _uuid.v4();
  int _generation = 0;
  bool _resolving = false;
  String? _error;

  /// Text in the box right after a pick; editing away from it un-picks.
  String? _pickedText;

  @override
  void initState() {
    super.initState();
    if (widget.initialText.isNotEmpty) _pickedText = widget.initialText;
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    if (_pickedText != null && _controller.text != _pickedText) {
      _pickedText = null;
      widget.onEdited?.call();
    }
    if (_error != null) setState(() => _error = null);
  }

  void _setError(String? message) {
    if (mounted && message != _error) setState(() => _error = message);
  }

  Future<Iterable<AddressOption>> _options(TextEditingValue value) async {
    final text = value.text.trim();
    if (text.isEmpty || value.text == _pickedText) return const [];

    final savedList = ref.read(addressesProvider);
    final local = widget.includeSaved
        ? ref
              .read(addressMatcherProvider)
              .suggestions(text, savedList)
              .take(4)
              .toList()
        : <SavedAddress>[];
    final localOptions = [for (final s in local) SavedOption(s)];

    final places = ref.read(placesServiceProvider);
    if (places == null || text.length < 3) return localOptions;

    // Wait for a pause in typing before calling Google.
    final generation = ++_generation;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted || generation != _generation) return localOptions;

    final List<PlaceSuggestion> results;
    try {
      results = await places.autocomplete(
        text,
        sessionToken: _session,
        near: widget.biasNear,
      );
    } on PlacesException catch (e) {
      _setError(e.message);
      return localOptions;
    }
    if (!mounted || generation != _generation) return localOptions;
    _setError(null);

    // A Google result that is already saved shows as the saved entry.
    final savedByPlaceId = {
      for (final s in savedList)
        if (s.placeId != null) s.placeId!: s,
    };
    final shownSavedIds = {for (final s in local) s.id};
    final options = <AddressOption>[...localOptions];
    for (final r in results) {
      final saved = widget.includeSaved ? savedByPlaceId[r.placeId] : null;
      if (saved == null) {
        options.add(GoogleOption(r));
      } else if (shownSavedIds.add(saved.id)) {
        options.add(SavedOption(saved));
      }
    }
    return options;
  }

  Future<void> _onSelected(AddressOption option) async {
    switch (option) {
      case SavedOption(:final address):
        await _complete(address.toPlace(), address);
      case GoogleOption(:final suggestion):
        final places = ref.read(placesServiceProvider);
        if (places == null) return;
        setState(() => _resolving = true);
        final Place place;
        try {
          place = await places.details(
            suggestion.placeId,
            sessionToken: _session,
          );
          _session = _uuid.v4();
        } on PlacesException catch (e) {
          _setError(e.message);
          return;
        } finally {
          if (mounted) setState(() => _resolving = false);
        }
        if (mounted) await _complete(place, null);
    }
  }

  Future<void> _complete(Place place, SavedAddress? saved) async {
    _pickedText = _controller.text;
    _focus.unfocus();
    await widget.onPicked(place, saved);
    if (widget.clearAfterPick && mounted) {
      _pickedText = null;
      _controller.clear();
    }
  }

  void _onSubmitted() {
    final text = _controller.text;
    if (text.trim().isNotEmpty && text != _pickedText) {
      _setError('Choose an address from the list.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasGoogle = ref.watch(placesServiceProvider) != null;
    final usable = widget.enabled && (hasGoogle || widget.includeSaved);
    final working = widget.busy || _resolving;

    final String helper;
    if (!hasGoogle) {
      helper = widget.includeSaved
          ? 'Clients only. Add a Google Maps API key in Settings '
                'to search any address.'
          : 'Add a Google Maps API key in Settings to search addresses.';
    } else {
      helper = widget.includeSaved
          ? 'Pick a client or a Google Maps result'
          : 'Pick a Google Maps result';
    }

    return RawAutocomplete<AddressOption>(
      textEditingController: _controller,
      focusNode: _focus,
      optionsBuilder: _options,
      displayStringForOption: (o) => switch (o) {
        SavedOption(:final address) => address.name,
        GoogleOption(:final suggestion) => suggestion.fullText,
      },
      onSelected: _onSelected,
      fieldViewBuilder: (context, controller, focusNode, _) => TextField(
        controller: controller,
        focusNode: focusNode,
        autofocus: widget.autofocus,
        enabled: usable && !working,
        textInputAction: TextInputAction.search,
        textCapitalization: TextCapitalization.words,
        decoration: InputDecoration(
          labelText: widget.labelText,
          hintText: !widget.includeSaved
              ? 'Search Google Maps'
              : hasGoogle
              ? 'Client name or any address'
              : 'Client name or address',
          helperText: helper,
          helperMaxLines: 2,
          errorText: _error,
          errorMaxLines: 3,
          prefixIcon: const Icon(Icons.search),
          border: const OutlineInputBorder(),
          suffixIcon: working
              ? const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : ListenableBuilder(
                  listenable: controller,
                  builder: (context, _) => controller.text.isEmpty
                      ? const SizedBox.shrink()
                      : IconButton(
                          tooltip: 'Clear',
                          icon: const Icon(Icons.clear),
                          onPressed: controller.clear,
                        ),
                ),
        ),
        onSubmitted: (_) => _onSubmitted(),
      ),
      optionsViewBuilder: (context, onPick, options) =>
          _OptionsList(options: options.toList(), onPick: onPick),
    );
  }
}

class _OptionsList extends StatelessWidget {
  const _OptionsList({required this.options, required this.onPick});

  final List<AddressOption> options;
  final ValueChanged<AddressOption> onPick;

  @override
  Widget build(BuildContext context) {
    final showsGoogle = options.any((o) => o is GoogleOption);
    return Align(
      alignment: Alignment.topLeft,
      child: Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: ListView(
            padding: EdgeInsets.zero,
            shrinkWrap: true,
            children: [
              for (final o in options)
                switch (o) {
                  SavedOption(:final address) => ListTile(
                    leading: const Icon(Icons.person),
                    title: Text(address.name),
                    subtitle: Text(address.address),
                    onTap: () => onPick(o),
                  ),
                  GoogleOption(:final suggestion) => ListTile(
                    leading: const Icon(Icons.place_outlined),
                    title: Text(suggestion.mainText),
                    subtitle: suggestion.secondaryText.isEmpty
                        ? null
                        : Text(suggestion.secondaryText),
                    onTap: () => onPick(o),
                  ),
                },
              if (showsGoogle)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Text(
                    'Powered by Google',
                    textAlign: TextAlign.end,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
