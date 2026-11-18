import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../background/job_watcher.dart';
import '../models/job.dart';
import '../models/saved_address.dart';
import '../models/trip.dart';
import '../services/jobs.dart';
import '../services/settings_sync.dart';
import 'providers.dart';

const _uuid = Uuid();

final jobsProvider = NotifierProvider<JobsNotifier, List<Job>>(
  JobsNotifier.new,
);

/// Sessions: time with clients, from arriving at the first client until
/// leaving the last. The phone's background handlers start and end them;
/// trips logged by hand follow the same rules. Every change
/// re-reads storage first, since the background may have written.
class JobsNotifier extends Notifier<List<Job>> {
  @override
  List<Job> build() => ref.read(localStoreProvider).loadJobs();

  DateTime _now() => ref.read(clockProvider)();

  /// Picks up jobs started or ended in the background.
  Future<void> refresh() async {
    final store = ref.read(localStoreProvider);
    await store.reload();
    final next = closeStaleJobs(store.loadJobs(), _now());
    final changed =
        jsonEncode([for (final j in next) j.toJson()]) !=
        jsonEncode([for (final j in state) j.toJson()]);
    state = next;
    // Started or ended in the background: send it to the other device.
    if (changed) ref.read(syncProvider.notifier).localChanged();
  }

  /// The running job, if any.
  Job? get running => activeJob(state, _now());

  /// A trip logged by hand: to a client starts a job; during a job, to
  /// anywhere but a client, donation center or gas station ends it.
  Future<void> afterManualTrip(Trip trip) async {
    final store = ref.read(localStoreProvider);
    await store.reload();
    final jobs = closeStaleJobs(store.loadJobs(), trip.date);
    final known = classifyKnownPlace(
      trip.to,
      home: ref.read(settingsProvider).home,
      clientStops: clientStops(ref.read(addressesProvider)),
      donationCenters: ref.read(donationCentersProvider),
    );
    final decision = decideStop(
      kind: known.kind,
      place: trip.to,
      start: trip.from,
      onJob: activeJob(jobs, trip.date) != null,
      lastDeparture: store.lastDeparture,
      arrivedAt: trip.date,
    );
    final next = applyStop(
      jobs: jobs,
      decision: decision,
      kind: known.kind,
      place: trip.to,
      arrivedAt: trip.date,
      miles: trip.miles,
      newId: _uuid.v4,
    );
    await store.setLastStop(PlaceVisit(trip.to, trip.date));
    await _save(next);
    await syncJobWatcher(store);
  }

  /// Ends the running session (e.g. the phone missed where it ended):
  /// now if you're still with a client, else when you left the last one.
  Future<void> endNow() async {
    final store = ref.read(localStoreProvider);
    await store.reload();
    final now = _now();
    await _save([
      for (final j in closeStaleJobs(store.loadJobs(), now))
        j.isActive
            ? j.copyWith(
                end: j.endingAt(now),
                visits: j.visitsLeftAt(j.endingAt(now)),
              )
            : j,
    ]);
    await stopJobWatcher();
    ref.read(syncProvider.notifier).localChanged();
  }

  /// Marks jobs as written to the spreadsheet.
  Future<void> markSynced(Set<String> ids) async {
    final store = ref.read(localStoreProvider);
    await store.reload();
    await _save([
      for (final j in store.loadJobs())
        ids.contains(j.id) ? j.copyWith(synced: true) : j,
    ]);
  }

  /// Every finished job needs uploading again (e.g. a new spreadsheet).
  Future<void> markAllUnsynced() async {
    final store = ref.read(localStoreProvider);
    await store.reload();
    await _save([for (final j in store.loadJobs()) j.copyWith(synced: false)]);
  }

  Future<void> _save(List<Job> jobs) async {
    state = jobs;
    await ref.read(localStoreProvider).saveJobs(jobs);
  }
}

/// Jobs the other device recorded (from sync). Shown on client pages;
/// never changed or uploaded here.
final otherDeviceJobsProvider =
    NotifierProvider<OtherDeviceJobsNotifier, SyncDoc>(
      OtherDeviceJobsNotifier.new,
    );

class OtherDeviceJobsNotifier extends Notifier<SyncDoc> {
  @override
  SyncDoc build() {
    final raw = ref.read(localStoreProvider).otherDeviceJobsRaw;
    return raw == null ? {} : decodeDoc(raw);
  }

  Future<void> replace(SyncDoc entries) async {
    state = entries;
    await ref
        .read(localStoreProvider)
        .setOtherDeviceJobsRaw(encodeDoc(entries));
  }
}

/// Every job, from both devices, with stops and miles: this device's from
/// its trips, the other device's as synced.
final allJobSummariesProvider = Provider<List<JobSummary>>((ref) {
  final now = ref.read(clockProvider)();
  final trips = ref.watch(tripsProvider);
  final local = [
    for (final j in ref.watch(jobsProvider)) summarizeJob(j, trips, now),
  ];
  final ids = {for (final j in local) j.job.id};
  return [
    ...local,
    for (final j in jobsFromDoc(ref.watch(otherDeviceJobsProvider)))
      if (!ids.contains(j.job.id)) j,
  ];
});
