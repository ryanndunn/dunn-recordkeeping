import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/saved_address.dart';
import '../../services/policy_docs.dart';
import '../../state/policy_docs_provider.dart';
import '../../state/providers.dart';
import '../../widgets/page_body.dart';
import '../clients/client_page.dart' show openClientLink;
import '../clients/client_status.dart';

/// The signed PDF in Drive.
Uri signedDocUri(SignedDoc doc) =>
    Uri.https('drive.google.com', '/file/d/${doc.id}/view');

void openSignedDocs(BuildContext context) =>
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const SignedDocsPage()));

/// Signed policy docs found in Drive: the ones that need a client picked,
/// and the ones already matched (which can be changed).
class SignedDocsPage extends ConsumerWidget {
  const SignedDocsPage({super.key});

  Future<void> _pick(BuildContext context, WidgetRef ref, SignedDoc doc) async {
    final clients = [...ref.read(addressesProvider)]
      ..sort((a, b) {
        // Clients still waiting on the policy doc first.
        final wa = a.policiesSignedOn == null ? 0 : 1;
        final wb = b.policiesSignedOn == null ? 0 : 1;
        if (wa != wb) return wa.compareTo(wb);
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Whose policy doc is "${doc.name}"?'),
        children: [
          for (final c in clients)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, c.id),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(c.name),
                subtitle: Text(
                  c.policiesSignedOn == null
                      ? c.status.label
                      : 'Signed ${formatShortDate(c.policiesSignedOn!)}',
                ),
              ),
            ),
          const Divider(),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, ''),
            child: const Text('Not a client\'s policy doc'),
          ),
        ],
      ),
    );
    if (choice == null) return;
    final docs = ref.read(signedDocsProvider.notifier);
    if (choice.isEmpty) {
      await docs.ignore(doc);
    } else {
      await docs.assign(doc, choice);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final docs = ref.watch(signedDocsProvider).docs;
    final decisions = ref.watch(signedDocDecisionsProvider);
    final names = {for (final c in ref.watch(addressesProvider)) c.id: c.name};
    final theme = Theme.of(context);
    final unmatched = [
      for (final d in docs)
        if (!decisions.containsKey(d.id)) d,
    ];
    final handled = [
      for (final d in docs)
        if (decisions.containsKey(d.id)) d,
    ];

    Widget tile(SignedDoc d) {
      final decision = decisions[d.id]?.decision;
      final String status;
      if (decision == null) {
        status = 'Needs a client';
      } else if (decision.clientId == null) {
        status = 'Not a client\'s policy doc';
      } else {
        final who = names[decision.clientId] ?? 'a deleted client';
        status = decision.automatic ? '$who (matched by name)' : who;
      }
      return ListTile(
        leading: const Icon(Icons.picture_as_pdf_outlined),
        title: Text(d.name),
        subtitle: Text('Signed ${formatShortDate(d.at.toLocal())} · $status'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Open the PDF',
              icon: const Icon(Icons.open_in_new),
              onPressed: () => openClientLink(context, signedDocUri(d)),
            ),
            decision == null
                ? FilledButton(
                    onPressed: () => _pick(context, ref, d),
                    child: const Text('Match'),
                  )
                : TextButton(
                    onPressed: () => _pick(context, ref, d),
                    child: const Text('Change'),
                  ),
          ],
        ),
      );
    }

    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Signed policy docs')),
      body: PageListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          if (docs.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No signed policy docs found in Drive yet.'),
            ),
          if (unmatched.isNotEmpty) ...[
            heading('Needs a client'),
            for (final d in unmatched) tile(d),
          ],
          if (handled.isNotEmpty) ...[
            heading('Matched'),
            for (final d in handled) tile(d),
          ],
        ],
      ),
    );
  }
}

/// On the client list: signed docs the app couldn't match by name.
class SignedDocsBanner extends ConsumerWidget {
  const SignedDocsBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.watch(unmatchedSignedDocsProvider).length;
    if (n == 0) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.tertiaryContainer,
      child: ListTile(
        leading: Icon(Icons.edit_document, color: scheme.onTertiaryContainer),
        title: Text(
          n == 1
              ? '1 signed policy doc needs a client'
              : '$n signed policy docs need a client',
          style: TextStyle(color: scheme.onTertiaryContainer),
        ),
        trailing: TextButton(
          onPressed: () => openSignedDocs(context),
          child: const Text('Match'),
        ),
        onTap: () => openSignedDocs(context),
      ),
    );
  }
}

/// Settings: let the app spot signed policy docs in Drive.
class PolicyDocsSettings extends ConsumerWidget {
  const PolicyDocsSettings({super.key});

  Future<void> _editName(BuildContext context, WidgetRef ref) async {
    final current =
        ref.read(settingsProvider).policyDocName ?? defaultPolicyDocName;
    final controller = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Policy doc file name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Signed PDFs have this in their name',
            helperText:
                'The start of a word is enough: "Polic" finds '
                '"Policy" and "Policies".',
            helperMaxLines: 2,
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    final name = result?.trim() ?? '';
    if (name.isEmpty || name == current) return;
    await ref.read(settingsProvider.notifier).setPolicyDocName(name);
    await ref.read(signedDocsProvider.notifier).check();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(signedDocsProvider);
    final signedIn = ref.watch(syncProvider.select((s) => s.signedIn));
    final name =
        ref.watch(settingsProvider.select((s) => s.policyDocName)) ??
        defaultPolicyDocName;
    final unmatched = ref.watch(unmatchedSignedDocsProvider).length;
    final scheme = Theme.of(context).colorScheme;

    if (!signedIn) {
      return const ListTile(
        leading: Icon(Icons.edit_document),
        title: Text('Detect signed policy docs'),
        subtitle: Text('Sign in to Google above first.'),
      );
    }
    if (state.connected != true) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: const Icon(Icons.edit_document),
            title: const Text('Detect signed policy docs'),
            subtitle: const Text(
              'When a client finishes signing with Google eSignature, '
              'Google saves the signed PDF to your Drive. Connect to let '
              'the app see your Drive\'s file names (read only, not what\'s '
              'in them) and mark that client signed.',
            ),
            isThreeLine: true,
            trailing: FilledButton(
              onPressed: () => ref.read(signedDocsProvider.notifier).connect(),
              child: const Text('Connect'),
            ),
          ),
          if (state.error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(state.error!, style: TextStyle(color: scheme.error)),
            ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: Icon(Icons.verified_outlined, color: scheme.primary),
          title: const Text('Detecting signed policy docs'),
          subtitle: Text(
            'PDFs in Drive named "$name…" · ${state.docs.length} found'
            '${unmatched == 0 ? '' : ' · $unmatched need a client'}',
          ),
          trailing: state.checking
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : IconButton(
                  tooltip: 'Check now',
                  icon: const Icon(Icons.refresh),
                  onPressed: () =>
                      ref.read(signedDocsProvider.notifier).check(),
                ),
          onTap: () => openSignedDocs(context),
        ),
        ListTile(
          leading: const Icon(Icons.text_fields),
          title: const Text('File name'),
          subtitle: Text('Contains "$name"'),
          trailing: const Icon(Icons.edit_outlined),
          onTap: () => _editName(context, ref),
        ),
        if (state.error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(state.error!, style: TextStyle(color: scheme.error)),
          ),
      ],
    );
  }
}

/// For the client page: the signed doc matched to [client], if any.
SignedDoc? signedDocOf(WidgetRef ref, SavedAddress client) => signedDocFor(
  client.id,
  ref.watch(signedDocsProvider).docs,
  ref.watch(signedDocDecisionsProvider),
);
