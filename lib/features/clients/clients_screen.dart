import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/saved_address.dart';
import '../../services/client_list.dart';
import '../../state/providers.dart';
import '../../widgets/client_dialog.dart';
import '../../widgets/page_body.dart';
import '../policy_forms/policy_forms_page.dart';
import 'client_page.dart';
import 'client_status.dart';

/// The client list, and the app's first screen. Tap a client to open their
/// page. Each client's address is where appointments happen: logging a trip
/// there is one tap, and arriving there logs it on its own.
class ClientsScreen extends ConsumerStatefulWidget {
  const ClientsScreen({super.key});

  @override
  ConsumerState<ClientsScreen> createState() => _ClientsScreenState();
}

class _ClientsScreenState extends ConsumerState<ClientsScreen> {
  /// The status shown, or null for everyone not archived.
  ClientStatus? _show;
  final _search = TextEditingController();
  late ClientSort _sort =
      ClientSort.values
          .where((s) => s.name == ref.read(localStoreProvider).clientSort)
          .firstOrNull ??
      ClientSort.nameAZ;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _setSort(ClientSort sort) {
    setState(() => _sort = sort);
    ref.read(localStoreProvider).setClientSort(sort.name);
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final input = await showClientDialog(context, title: 'New client');
    if (input == null) return;
    await ref
        .read(addressesProvider.notifier)
        .add(
          name: input.name,
          place: input.place,
          email: input.email,
          phone: input.phone,
        );
  }

  void _openClient(BuildContext context, SavedAddress client) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ClientPage(clientId: client.id),
        ),
      );

  Future<bool> _confirmDelete(BuildContext context, SavedAddress c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${c.name}"?'),
        content: const Text('Trips already logged to this client are kept.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(addressesProvider);
    final query = _search.text;
    // Counts follow the search, so each chip says how many match.
    final found = [
      for (final c in all)
        if (clientMatches(c, query)) c,
    ];
    int count(ClientStatus s) => found.where((c) => c.status == s).length;
    final current = found.length - count(ClientStatus.archived);
    final clients = sortClients(
      [
        for (final c in found)
          if (_show == null
              ? c.status != ClientStatus.archived
              : c.status == _show)
            c,
      ],
      _sort,
      ref.read(clockProvider)(),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Clients'),
        actions: [
          PopupMenuButton<ClientSort>(
            tooltip: 'Sort',
            icon: const Icon(Icons.sort),
            onSelected: _setSort,
            itemBuilder: (_) => [
              for (final s in ClientSort.values)
                CheckedPopupMenuItem(
                  value: s,
                  checked: s == _sort,
                  child: Text(s.label),
                ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _add(context, ref),
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Add client'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PolicyFormsBanner(),
          Expanded(
            child: all.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Add your clients and where you meet them. Trips to a '
                      'client\'s address are logged with the driving miles.',
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final width = constraints.maxWidth;
                      final small = Theme.of(context).textTheme.bodyMedium;
                      const pill = OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(28)),
                      );
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: readablePadding(
                              width,
                              const EdgeInsets.fromLTRB(16, 4, 16, 8),
                            ),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: width < 480 ? 150 : 210,
                                  child: DropdownButtonFormField<int>(
                                    initialValue: _show?.index ?? -1,
                                    isExpanded: true,
                                    style: small,
                                    decoration: const InputDecoration(
                                      border: pill,
                                      isDense: true,
                                      contentPadding: EdgeInsets.fromLTRB(
                                        16,
                                        12,
                                        8,
                                        12,
                                      ),
                                    ),
                                    // Closed, it shows the short name and count.
                                    selectedItemBuilder: (_) => [
                                      Text(
                                        'All clients ($current)',
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      for (final s in ClientStatus.values)
                                        Text(
                                          '${s.shortLabel} (${count(s)})',
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                    ],
                                    items: [
                                      DropdownMenuItem(
                                        value: -1,
                                        child: Text('All clients ($current)'),
                                      ),
                                      for (final s in ClientStatus.values)
                                        DropdownMenuItem(
                                          value: s.index,
                                          child: Row(
                                            children: [
                                              Icon(statusIcon(s), size: 18),
                                              const SizedBox(width: 8),
                                              Flexible(
                                                child: Text(
                                                  '${s.label} (${count(s)})',
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                    ],
                                    onChanged: (i) => setState(
                                      () => _show = i == null || i < 0
                                          ? null
                                          : ClientStatus.values[i],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: TextField(
                                    controller: _search,
                                    style: small,
                                    textInputAction: TextInputAction.search,
                                    decoration: InputDecoration(
                                      hintText: 'Search clients',
                                      hintStyle: small,
                                      prefixIcon: const Icon(
                                        Icons.search,
                                        size: 20,
                                      ),
                                      suffixIcon: query.isEmpty
                                          ? null
                                          : IconButton(
                                              tooltip: 'Clear search',
                                              icon: const Icon(
                                                Icons.close,
                                                size: 20,
                                              ),
                                              onPressed: () => setState(
                                                () => _search.clear(),
                                              ),
                                            ),
                                      border: pill,
                                      isDense: true,
                                    ),
                                    onChanged: (_) => setState(() {}),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: clients.isEmpty
                                ? Padding(
                                    padding: readablePadding(
                                      width,
                                      const EdgeInsets.all(24),
                                    ),
                                    child: Text(
                                      query.trim().isNotEmpty
                                          ? 'No clients match "${query.trim()}"'
                                                '${_show == null ? '' : ' in "${_show!.label}"'}.'
                                          : _show == null
                                          ? 'Everyone is archived.'
                                          : 'No clients are "${_show!.label}".',
                                    ),
                                  )
                                : ListView.separated(
                                    padding: readablePadding(
                                      width,
                                      const EdgeInsets.only(bottom: 88),
                                    ),
                                    itemCount: clients.length,
                                    separatorBuilder: (_, _) =>
                                        const Divider(height: 1),
                                    itemBuilder: (context, i) {
                                      final c = clients[i];
                                      return Dismissible(
                                        key: ValueKey(c.id),
                                        direction: DismissDirection.endToStart,
                                        background: Container(
                                          alignment: Alignment.centerRight,
                                          padding: const EdgeInsets.only(
                                            right: 16,
                                          ),
                                          color: Theme.of(context)
                                              .colorScheme
                                              .errorContainer,
                                          child: const Icon(
                                            Icons.delete_outline,
                                          ),
                                        ),
                                        confirmDismiss: (_) =>
                                            _confirmDelete(context, c),
                                        onDismissed: (_) => ref
                                            .read(addressesProvider.notifier)
                                            .remove(c.id),
                                        child: _ClientTile(
                                          client: c,
                                          onTap: () => _openClient(context, c),
                                          onCall: c.phone.isEmpty
                                              ? null
                                              : () => openClientLink(
                                                  context,
                                                  Uri(
                                                    scheme: 'tel',
                                                    path: c.phone,
                                                  ),
                                                ),
                                          onEmail: c.email.isEmpty
                                              ? null
                                              : () => openClientLink(
                                                  context,
                                                  Uri(
                                                    scheme: 'mailto',
                                                    path: c.email,
                                                  ),
                                                ),
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _ClientTile extends StatelessWidget {
  const _ClientTile({
    required this.client,
    required this.onTap,
    required this.onCall,
    required this.onEmail,
  });

  final SavedAddress client;
  final VoidCallback onTap;
  final VoidCallback? onCall;
  final VoidCallback? onEmail;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = client;
    final contact = [c.phone, c.email].where((s) => s.isNotEmpty).join(' · ');
    return ListTile(
      onTap: onTap,
      leading: c.isVerified
          ? CircleAvatar(child: Text(clientInitials(c.name)))
          : CircleAvatar(
              backgroundColor: scheme.errorContainer,
              child: Icon(Icons.warning_amber, color: scheme.error),
            ),
      title: Text(c.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!c.isActive)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: ClientStatusBadge(client: c),
            ),
          Text(
            [
              c.address,
              if (c.locations.isNotEmpty)
                c.locations.length == 1
                    ? '+ 1 more address'
                    : '+ ${c.locations.length} more addresses',
              if (contact.isNotEmpty) contact,
              if (!c.isVerified)
                'Address not verified. Tap to pick it from '
                    'Google Maps.',
            ].join('\n'),
          ),
        ],
      ),
      isThreeLine: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onCall != null)
            IconButton(
              tooltip: 'Call ${c.name}',
              icon: const Icon(Icons.phone_outlined),
              onPressed: onCall,
            ),
          if (onEmail != null)
            IconButton(
              tooltip: 'Email ${c.name}',
              icon: const Icon(Icons.email_outlined),
              onPressed: onEmail,
            ),
        ],
      ),
    );
  }
}
