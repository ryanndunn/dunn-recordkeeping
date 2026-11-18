import 'place.dart';

/// Time out on a job: from leaving for the first client until arriving
/// where the job ends (home, or any stop that isn't a client, donation
/// center or gas station). Becomes one row on the spreadsheet's Jobs tab.
class Job {
  const Job({
    required this.id,
    required this.start,
    this.end,
    this.startEstimated = false,
    this.clients = const [],
    this.lastActivity,
    this.synced = false,
  });

  final String id;

  /// When you left for the first client.
  final DateTime start;

  /// When you arrived where the job ended. Null while the job is running.
  final DateTime? end;

  /// True when the departure time wasn't seen and [start] is worked out
  /// from the drive instead.
  final bool startEstimated;

  /// Clients visited, in order, without repeats.
  final List<String> clients;

  /// The last stop logged during the job (to close a job left open
  /// overnight).
  final DateTime? lastActivity;

  /// True once the row is on the spreadsheet.
  final bool synced;

  bool get isActive => end == null;

  Duration get duration => (end ?? DateTime.now()).difference(start);

  Job copyWith({
    DateTime? start,
    DateTime? end,
    List<String>? clients,
    DateTime? lastActivity,
    bool? synced,
  }) => Job(
    id: id,
    start: start ?? this.start,
    end: end ?? this.end,
    startEstimated: startEstimated,
    clients: clients ?? this.clients,
    lastActivity: lastActivity ?? this.lastActivity,
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
