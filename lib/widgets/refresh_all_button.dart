import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../state/refresh_all.dart';

/// Refreshes everything (see [RefreshAllNotifier.run]). Shown at the top
/// of every page; spins while a refresh is running.
class RefreshAllButton extends ConsumerWidget {
  const RefreshAllButton({super.key, this.onDone});

  /// Called after refreshing, for a page that keeps its own copy of
  /// something.
  final VoidCallback? onDone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final running = ref.watch(refreshAllProvider);
    return IconButton(
      tooltip: 'Refresh',
      icon: running
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.refresh),
      onPressed: running
          ? null
          : () async {
              await ref.read(refreshAllProvider.notifier).run();
              onDone?.call();
            },
    );
  }
}
