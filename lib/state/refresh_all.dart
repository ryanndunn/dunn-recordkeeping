import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../background/job_watcher.dart';
import 'calendar_provider.dart';
import 'providers.dart';
import 'stripe_provider.dart';

final refreshAllProvider = NotifierProvider<RefreshAllNotifier, bool>(
  RefreshAllNotifier.new,
);

/// The refresh button at the top of every page. True while refreshing.
class RefreshAllNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  /// Picks up everything new: trips and sessions the phone logged in the
  /// background, the other device's changes, leads and form responses,
  /// the spreadsheet, Stripe payments and the calendar.
  Future<void> run() async {
    if (state) return;
    state = true;
    Future<void> step(String name, Future<void> Function() f) async {
      try {
        await f();
      } catch (e) {
        debugPrint('Dunn Record Keeping: refreshing $name failed: $e');
      }
    }

    try {
      await step('trips', () async {
        await ref.read(jobsProvider.notifier).refresh();
        await ref.read(tripsProvider.notifier).mergeInbox();
      });
      await step('tracking', () async {
        await ref.read(autoTripProvider.notifier).refresh();
        await syncJobWatcher(ref.read(localStoreProvider));
      });
      await step('sync', () => ref.read(syncProvider.notifier).syncNow());
      await step(
        'Stripe',
        () => ref.read(stripeProvider.notifier).refresh(force: true),
      );
      if (ref.read(calendarProvider).connected == true) {
        await step(
          'calendar',
          () => ref.read(calendarProvider.notifier).refresh(),
        );
      }
    } finally {
      state = false;
    }
  }
}
