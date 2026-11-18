import 'place.dart';

/// Time at one client during a session: arrived, and left (null while
/// there).
class ClientVisit {
  const ClientVisit(this.client, this.arrived, [this.left]);

  /// The stop's name: the client's, or "Client (Storage unit)".
  final String client;
  final DateTime arrived;
  final DateTime? left;

  ClientVisit leaving(DateTime at) => ClientVisit(client, arrived, at);

  /// How long, counting an open visit until [until].
  Duration length(DateTime until) {
    final d = (left ?? until).difference(arrived);
    return d.isNegative ? Duration.zero : d;
  }

  /// True if this visit was to [clientName] (any of their addresses).
  bool isTo(String clientName) =>
      client == clientName || client.startsWith('$clientName (');

  Map<String, dynamic> toJson() => {
    'client': client,
    'arrived': arrived.toIso8601String(),
    if (left != null) 'left': left!.toIso8601String(),
  };

  factory ClientVisit.fromJson(Map<String, dynamic> json) => ClientVisit(
    json['client'] as String,
    DateTime.parse(json['arrived'] as String),
    json['left'] == null ? null : DateTime.parse(json['left'] as String),
  );
}

/// A session: time with clients, from arriving at the first client until
/// leaving the last one, including the drives between them (and any
/// donation or gas stops on the way). The drives to the first client and
/// home from the last are logged as mileage but aren't session time.
/// Becomes one row on the spreadsheet's Sessions tab.
class Job {
  const Job({
    required this.id,
    required this.start,
    this.end,
    this.startEstimated = false,
    this.clients = const [],
    this.lastActivity,
    this.atClient = false,
    this.leftClientAt,
    this.visits = const [],
    this.synced = false,
  });

  final String id;

  /// When you arrived at the first client.
  final DateTime start;

  /// When you left the last client. Null while the session is running.
  final DateTime? end;

  /// Only for sessions recorded before sessions were client time: the
  /// departure from home wasn't seen and [start] was worked out instead.
  final bool startEstimated;

  /// Clients visited, in order, without repeats.
  final List<String> clients;

  /// The last stop logged during the job (to close a job left open
  /// overnight).
  final DateTime? lastActivity;

  /// True while the last stop was a client (you're with them now).
  final bool atClient;

  /// When you last left a client, as seen by the phone or estimated from
  /// the drive. The session ends here.
  final DateTime? leftClientAt;

  /// Each stop at a client, in order. Empty for sessions recorded before
  /// visits were kept.
  final List<ClientVisit> visits;

  /// Time spent at [clientName]'s addresses, or null if this session
  /// didn't record visits.
  Duration? timeWith(String clientName, DateTime now) {
    if (visits.isEmpty) return null;
    final until = end ?? now;
    return visits
        .where((v) => v.isTo(clientName))
        .fold<Duration>(Duration.zero, (sum, v) => sum + v.length(until));
  }

  /// [visits] with the open one (if any) closed at [at].
  List<ClientVisit> visitsLeftAt(DateTime at) => [
    for (final v in visits) v.left == null ? v.leaving(at) : v,
  ];

  /// True once the row is on the spreadsheet.
  final bool synced;

  bool get isActive => end == null;

  /// Where the session ends if it ends now: still with a client, [now];
  /// otherwise when you left the last client.
  DateTime endingAt(DateTime now) =>
      atClient ? now : (leftClientAt ?? lastActivity ?? start);

  Duration get duration => (end ?? DateTime.now()).difference(start);

  Job copyWith({
    DateTime? start,
    DateTime? end,
    List<String>? clients,
    DateTime? lastActivity,
    bool? atClient,
    DateTime? leftClientAt,
    List<ClientVisit>? visits,
    bool? synced,
  }) => Job(
    id: id,
    start: start ?? this.start,
    end: end ?? this.end,
    startEstimated: startEstimated,
    clients: clients ?? this.clients,
    lastActivity: lastActivity ?? this.lastActivity,
    atClient: atClient ?? this.atClient,
    leftClientAt: leftClientAt ?? this.leftClientAt,
    visits: visits ?? this.visits,
    synced: synced ?? this.synced,
  );

  /// Adds [client] to the visited list (once).
  Job visiting(String client) =>
      clients.contains(client) ? this : copyWith(clients: [...clients, client]);

  Map<String, dynamic> toJson() => {
    'id': id,
    'start': start.toIso8601String(),
    if (end != null) 'end': end!.toIso8601String(),
    if (startEstimated) 'startEstimated': true,
    if (clients.isNotEmpty) 'clients': clients,
    if (lastActivity != null) 'lastActivity': lastActivity!.toIso8601String(),
    if (atClient) 'atClient': true,
    if (leftClientAt != null) 'leftClientAt': leftClientAt!.toIso8601String(),
    if (visits.isNotEmpty) 'visits': [for (final v in visits) v.toJson()],
    'synced': synced,
  };

  factory Job.fromJson(Map<String, dynamic> json) => Job(
    id: json['id'] as String,
    start: DateTime.parse(json['start'] as String),
    end: json['end'] == null ? null : DateTime.parse(json['end'] as String),
    startEstimated: json['startEstimated'] as bool? ?? false,
    clients: [for (final c in (json['clients'] as List?) ?? const []) '$c'],
    lastActivity: json['lastActivity'] == null
        ? null
        : DateTime.parse(json['lastActivity'] as String),
    atClient: json['atClient'] as bool? ?? false,
    leftClientAt: json['leftClientAt'] == null
        ? null
        : DateTime.parse(json['leftClientAt'] as String),
    visits: [
      for (final v in (json['visits'] as List?) ?? const [])
        ClientVisit.fromJson(v as Map<String, dynamic>),
    ],
    synced: json['synced'] as bool? ?? false,
  );
}

/// A place the phone was at, and when (arrived or left).
class PlaceVisit {
  const PlaceVisit(this.place, this.at);

  final Place place;
  final DateTime at;

  Map<String, dynamic> toJson() => {
    'place': place.toJson(),
    'at': at.toIso8601String(),
  };

  factory PlaceVisit.fromJson(Map<String, dynamic> json) => PlaceVisit(
    Place.fromJson(json['place'] as Map<String, dynamic>),
    DateTime.parse(json['at'] as String),
  );
}

/// A job with what happened during it: the stops made and the miles
/// driven. This is what syncs to the other device (which doesn't have
/// this device's trips), so it can show the job on client pages.
class JobSummary {
  const JobSummary(this.job, {required this.miles, required this.stops});

  final Job job;
  final double miles;

  /// Where each drive during the job went, in order.
  final List<Place> stops;

  /// The newest moment in the job, so a change reaches the other device.
  DateTime get changedAt {
    var t = job.start;
    for (final x in [job.lastActivity, job.end]) {
      if (x != null && x.isAfter(t)) t = x;
    }
    return t;
  }

  Map<String, dynamic> toJson() => {
    ...job.toJson()..remove('synced'),
    'miles': miles,
    'stops': [for (final p in stops) p.toJson()],
  };

  factory JobSummary.fromJson(Map<String, dynamic> json) => JobSummary(
    Job.fromJson({...json, 'synced': true}),
    miles: (json['miles'] as num?)?.toDouble() ?? 0,
    stops: [
      for (final p in (json['stops'] as List?) ?? const [])
        Place.fromJson(p as Map<String, dynamic>),
    ],
  );
}
