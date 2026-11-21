/// One Let's Get This Dunn Club webinar. Added by hand; synced between
/// devices.
class Webinar {
  const Webinar({
    required this.id,
    required this.start,
    this.topic = '',
    this.link = '',
    this.emailedAt,
  });

  final String id;

  /// When it starts (local time).
  final DateTime start;

  /// What it's about, e.g. "Holiday decorations".
  final String topic;

  /// Where to join (Zoom, Google Meet, …).
  final String link;

  /// When the invite was last drafted to the mailing list.
  final DateTime? emailedAt;

  bool isUpcoming(DateTime now) => start.isAfter(now);

  Webinar copyWith({
    DateTime? start,
    String? topic,
    String? link,
    DateTime? emailedAt,
  }) => Webinar(
    id: id,
    start: start ?? this.start,
    topic: topic ?? this.topic,
    link: link ?? this.link,
    emailedAt: emailedAt ?? this.emailedAt,
  );

  Map<String, dynamic> toJson() => {
    'start': start.toIso8601String(),
    if (topic.isNotEmpty) 'topic': topic,
    if (link.isNotEmpty) 'link': link,
    if (emailedAt != null) 'emailedAt': emailedAt!.toIso8601String(),
  };

  factory Webinar.fromJson(String id, Map<String, dynamic> json) => Webinar(
    id: id,
    start: DateTime.parse(json['start'] as String),
    topic: json['topic'] as String? ?? '',
    link: json['link'] as String? ?? '',
    emailedAt: json['emailedAt'] == null
        ? null
        : DateTime.parse(json['emailedAt'] as String),
  );
}
