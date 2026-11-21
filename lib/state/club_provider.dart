import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/club_member.dart';
import '../models/money.dart';
import '../models/webinar.dart';
import '../services/club.dart';
import '../services/local_store.dart';
import 'money_provider.dart';
import 'providers.dart';

/// Webinars added by hand, synced between devices (`webinar:<id>`).
class WebinarsNotifier extends SyncedRecordsNotifier {
  @override
  String get prefix => 'webinar:';
  @override
  String get storeKey => LocalStore.webinarsKey;

  Future<void> save(Webinar w) => put(w.id, w.toJson());
}

/// Members added or edited by hand, and removals (`member:<id>`).
class MembersNotifier extends SyncedRecordsNotifier {
  @override
  String get prefix => 'member:';
  @override
  String get storeKey => LocalStore.clubMembersKey;

  Future<void> save(ClubMember m) => put(m.id, m.toJson());
}

/// Each member's payment for each webinar
/// (`clubpay:<webinar>|<member>`).
class ClubSeatsNotifier extends SyncedRecordsNotifier {
  @override
  String get prefix => 'clubpay:';
  @override
  String get storeKey => LocalStore.clubSeatsKey;

  Future<void> decide(String webinarId, String memberId, ClubDecision d) =>
      put(seatKey(webinarId, memberId), d.toJson());
}

final webinarRecordsProvider = NotifierProvider<WebinarsNotifier, Records>(
  WebinarsNotifier.new,
);
final memberRecordsProvider = NotifierProvider<MembersNotifier, Records>(
  MembersNotifier.new,
);
final clubSeatRecordsProvider = NotifierProvider<ClubSeatsNotifier, Records>(
  ClubSeatsNotifier.new,
);

final webinarsProvider = Provider<List<Webinar>>(
  (ref) => [
    for (final e in ref.watch(webinarRecordsProvider).entries)
      if (e.value.value case final Map<String, dynamic> v)
        Webinar.fromJson(e.key, v),
  ],
);

final clubSeatsProvider = Provider<Map<String, ClubDecision>>(
  (ref) => {
    for (final e in ref.watch(clubSeatRecordsProvider).entries)
      if (e.value.value case final Map<String, dynamic> v)
        e.key: ClubDecision.fromJson(v),
  },
);

/// Every member, by name.
final clubMembersProvider = Provider<List<ClubMember>>(
  (ref) => clubMembers(
    records: {
      for (final e in ref.watch(memberRecordsProvider).entries)
        e.key: e.value.value,
    },
    responses: ref.watch(clubRegistrationsProvider),
    clients: ref.watch(addressesProvider),
  ),
);

/// Upcoming and past webinars with who paid and the money.
final webinarSummariesProvider =
    Provider<({List<WebinarSummary> upcoming, List<WebinarSummary> past})>(
      (ref) => summarizeWebinars(
        webinars: ref.watch(webinarsProvider),
        members: ref.watch(clubMembersProvider),
        seats: ref.watch(clubSeatsProvider),
        now: ref.read(clockProvider)(),
      ),
    );

/// Paid webinars, for Billing and the spreadsheet.
final clubPaymentsProvider = Provider<List<LedgerPayment>>(
  (ref) => clubPayments(
    webinars: ref.watch(webinarsProvider),
    members: ref.watch(clubMembersProvider),
    seats: ref.watch(clubSeatsProvider),
  ),
);
