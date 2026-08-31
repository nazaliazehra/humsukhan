import 'package:uuid/uuid.dart';

const _uuid = Uuid();

// ===================== USER =====================
class UserProfile {
  final String id;
  final String name;
  final String avatarEmoji;
  final String preferredLanguage;
  final String tutorName;
  final DateTime createdAt;

  UserProfile({
    String? id,
    this.name = 'User',
    this.avatarEmoji = '👤',
    this.preferredLanguage = 'English',
    this.tutorName = 'Sam',
    DateTime? createdAt,
  }) : id = id ?? _uuid.v4(),
       createdAt = createdAt ?? DateTime.now();

  UserProfile copyWith({
    String? name,
    String? avatarEmoji,
    String? preferredLanguage,
    String? tutorName,
  }) {
    return UserProfile(
      id: id,
      name: name ?? this.name,
      avatarEmoji: avatarEmoji ?? this.avatarEmoji,
      preferredLanguage: preferredLanguage ?? this.preferredLanguage,
      tutorName: tutorName ?? this.tutorName,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'avatarEmoji': avatarEmoji,
    'preferredLanguage': preferredLanguage,
    'tutorName': tutorName,
    'createdAt': createdAt.toIso8601String(),
  };

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
    id: json['id'],
    name: json['name'] ?? 'User',
    avatarEmoji: json['avatarEmoji'] ?? '👤',
    preferredLanguage: json['preferredLanguage'] ?? 'English',
    tutorName: json['tutorName'] ?? 'Sam',
    createdAt: DateTime.parse(json['createdAt']),
  );
}

// ===================== CONVERSATION STATE =====================
enum ConversationState { idle, starting, active, stopping, saveDecision }

enum SaveAction { deleteNow, save }

// ===================== CAPTION =====================
class Caption {
  final String id;
  final String text;
  final String speaker;
  final DateTime timestamp;
  final String language;
  final bool isPartial;
  final bool isOwn;

  Caption({
    String? id,
    required this.text,
    this.speaker = 'Speaker 1',
    DateTime? timestamp,
    this.language = 'English',
    this.isPartial = false,
    this.isOwn = false,
  }) : id = id ?? _uuid.v4(),
       timestamp = timestamp ?? DateTime.now();

  Caption copyWith({String? text, bool? isPartial, String? speaker}) {
    return Caption(
      id: id,
      text: text ?? this.text,
      speaker: speaker ?? this.speaker,
      timestamp: timestamp,
      language: language,
      isPartial: isPartial ?? this.isPartial,
      isOwn: isOwn,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'speaker': speaker,
    'timestamp': timestamp.toIso8601String(),
    'language': language,
    'isPartial': isPartial,
    'isOwn': isOwn,
  };

  factory Caption.fromJson(Map<String, dynamic> json) => Caption(
    id: json['id'],
    text: json['text'] ?? '',
    speaker: json['speaker'] ?? 'Speaker 1',
    timestamp: DateTime.parse(json['timestamp']),
    language: json['language'] ?? 'English',
    isPartial: json['isPartial'] ?? false,
    isOwn: json['isOwn'] ?? false,
  );
}

// ===================== QUICK REPLY =====================
class QuickReply {
  final String id;
  final String text;
  final String category;
  final bool isFavorite;
  final DateTime createdAt;

  QuickReply({
    String? id,
    required this.text,
    this.category = 'General',
    this.isFavorite = false,
    DateTime? createdAt,
  }) : id = id ?? _uuid.v4(),
       createdAt = createdAt ?? DateTime.now();

  QuickReply copyWith({String? text, String? category, bool? isFavorite}) {
    return QuickReply(
      id: id,
      text: text ?? this.text,
      category: category ?? this.category,
      isFavorite: isFavorite ?? this.isFavorite,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'category': category,
    'isFavorite': isFavorite,
    'createdAt': createdAt.toIso8601String(),
  };

  factory QuickReply.fromJson(Map<String, dynamic> json) => QuickReply(
    id: json['id'],
    text: json['text'] ?? '',
    category: json['category'] ?? 'General',
    isFavorite: json['isFavorite'] ?? false,
    createdAt: DateTime.parse(json['createdAt']),
  );
}

// ===================== PROFESSIONAL SESSION =====================
enum SessionType { meeting, lecture, class_ }

enum SessionStatus { inProgress, completed, archived }

/// Human-readable label for a [SessionType] — avoids showing "class_" in the UI.
String sessionTypeLabel(SessionType type) => switch (type) {
  SessionType.meeting => 'Meeting',
  SessionType.lecture => 'Lecture',
  SessionType.class_ => 'Class',
};

class ProfessionalSession {
  final String id;
  final String title;
  final SessionType type;
  final String? folderId;
  final String captionLanguage;
  final int retentionDays;
  final DateTime createdAt;
  final DateTime expiresAt;
  final DateTime updatedAt;
  final SessionStatus status;
  final List<Caption> captions;
  final String? transcriptText;

  ProfessionalSession({
    String? id,
    required this.title,
    this.type = SessionType.meeting,
    this.folderId,
    this.captionLanguage = 'English',
    int retentionDays = 7,
    DateTime? createdAt,
    DateTime? expiresAt,
    DateTime? updatedAt,
    this.status = SessionStatus.inProgress,
    List<Caption>? captions,
    this.transcriptText,
  }) : id = id ?? _uuid.v4(),
       retentionDays = retentionDays.clamp(1, RetentionPolicy.maxRetentionDays),
       createdAt = createdAt ?? DateTime.now(),
       expiresAt = expiresAt ?? (createdAt ?? DateTime.now()).add(Duration(days: retentionDays)),
       updatedAt = updatedAt ?? DateTime.now(),
       captions = captions ?? [];

  ProfessionalSession copyWith({
    String? title,
    SessionType? type,
    String? folderId,
    String? captionLanguage,
    int? retentionDays,
    SessionStatus? status,
    List<Caption>? captions,
    String? transcriptText,
    DateTime? expiresAt,
    DateTime? updatedAt,
  }) {
    return ProfessionalSession(
      id: id,
      title: title ?? this.title,
      type: type ?? this.type,
      folderId: folderId ?? this.folderId,
      captionLanguage: captionLanguage ?? this.captionLanguage,
      retentionDays: retentionDays ?? this.retentionDays,
      createdAt: createdAt,
      expiresAt: expiresAt ?? this.expiresAt,
      updatedAt: updatedAt ?? DateTime.now(),
      status: status ?? this.status,
      captions: captions ?? this.captions,
      transcriptText: transcriptText ?? this.transcriptText,
    );
  }

  bool get isExpired => DateTime.now().isAfter(expiresAt);
  int get daysRemaining => expiresAt.difference(DateTime.now()).inDays;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'type': type.index,
    'folderId': folderId,
    'captionLanguage': captionLanguage,
    'retentionDays': retentionDays,
    'createdAt': createdAt.toIso8601String(),
    'expiresAt': expiresAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'status': status.index,
    'captions': captions.map((c) => c.toJson()).toList(),
    'transcriptText': transcriptText,
  };

  factory ProfessionalSession.fromJson(Map<String, dynamic> json) => ProfessionalSession(
    id: json['id'],
    title: json['title'] ?? '',
    type: SessionType.values[json['type'] ?? 0],
    folderId: json['folderId'],
    captionLanguage: json['captionLanguage'] ?? 'English',
    retentionDays: json['retentionDays'] ?? 7,
    createdAt: DateTime.parse(json['createdAt']),
    expiresAt: DateTime.parse(json['expiresAt']),
    updatedAt: json['updatedAt'] != null ? DateTime.parse(json['updatedAt']) : DateTime.parse(json['createdAt']),
    status: SessionStatus.values[json['status'] ?? 1],
    captions: (json['captions'] as List?)?.map((c) => Caption.fromJson(c)).toList() ?? [],
    transcriptText: json['transcriptText'],
  );
}

// ===================== FOLDER =====================
class Folder {
  final String id;
  final String name;
  final DateTime createdAt;

  Folder({
    String? id,
    required this.name,
    DateTime? createdAt,
  }) : id = id ?? _uuid.v4(),
       createdAt = createdAt ?? DateTime.now();

  Folder copyWith({String? name}) {
    return Folder(id: id, name: name ?? this.name, createdAt: createdAt);
  }

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'createdAt': createdAt.toIso8601String()};
  factory Folder.fromJson(Map<String, dynamic> json) => Folder(id: json['id'], name: json['name'] ?? '', createdAt: DateTime.parse(json['createdAt']));
}

// ===================== PROFESSIONAL INSIGHT =====================

/// How an insight was produced — distinguishes AI-generated analysis from
/// the deterministic local keyword-extraction fallback.
enum InsightSource { ai, local }

class ProfessionalInsight {
  final String id;
  final String sessionId;
  final String summary;
  final List<String> vocabulary;
  final List<String> themes;
  final List<String> actionItems;
  final List<String> deadlines;
  final List<String> mentionedPeople;
  final DateTime generatedAt;
  final bool isAvailable;

  /// How this insight was produced: [InsightSource.ai] for Gemini-generated
  /// analysis, [InsightSource.local] for the offline keyword-extraction fallback.
  final InsightSource source;

  /// The language of the source transcript (e.g. 'English', 'Urdu',
  /// 'Hindi', 'Roman Urdu'). Preserved so the UI can display the context
  /// in which insights were generated.
  final String language;

  ProfessionalInsight({
    String? id,
    required this.sessionId,
    this.summary = '',
    List<String>? vocabulary,
    List<String>? themes,
    List<String>? actionItems,
    List<String>? deadlines,
    List<String>? mentionedPeople,
    DateTime? generatedAt,
    this.isAvailable = false,
    this.source = InsightSource.local,
    this.language = 'English',
  }) : id = id ?? _uuid.v4(),
       vocabulary = vocabulary ?? [],
       themes = themes ?? [],
       actionItems = actionItems ?? [],
       deadlines = deadlines ?? [],
       mentionedPeople = mentionedPeople ?? [],
       generatedAt = generatedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'id': id,
    'sessionId': sessionId,
    'summary': summary,
    'vocabulary': vocabulary,
    'themes': themes,
    'actionItems': actionItems,
    'deadlines': deadlines,
    'mentionedPeople': mentionedPeople,
    'generatedAt': generatedAt.toIso8601String(),
    'isAvailable': isAvailable,
    'source': source.index,
    'language': language,
  };

  factory ProfessionalInsight.fromJson(Map<String, dynamic> json) => ProfessionalInsight(
    id: json['id'],
    sessionId: json['sessionId'],
    summary: json['summary'] ?? '',
    vocabulary: List<String>.from(json['vocabulary'] ?? []),
    themes: List<String>.from(json['themes'] ?? []),
    actionItems: List<String>.from(json['actionItems'] ?? []),
    deadlines: List<String>.from(json['deadlines'] ?? []),
    mentionedPeople: List<String>.from(json['mentionedPeople'] ?? []),
    generatedAt: DateTime.parse(json['generatedAt']),
    isAvailable: json['isAvailable'] ?? false,
    source: InsightSource.values[json['source'] ?? 1],
    language: json['language'] ?? 'English',
  );
}

// ===================== SOUND EVENT / ALERT =====================
class SoundEvent {
  final String id;
  final String type;
  final double confidence;
  final DateTime timestamp;
  final String severity;
  final bool dismissed;

  SoundEvent({
    String? id,
    required this.type,
    this.confidence = 0.8,
    DateTime? timestamp,
    this.severity = 'warning',
    this.dismissed = false,
  }) : id = id ?? _uuid.v4(),
       timestamp = timestamp ?? DateTime.now();

  SoundEvent copyWith({bool? dismissed}) {
    return SoundEvent(
      id: id,
      type: type,
      confidence: confidence,
      timestamp: timestamp,
      severity: severity,
      dismissed: dismissed ?? this.dismissed,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'confidence': confidence,
    'timestamp': timestamp.toIso8601String(),
    'severity': severity,
    'dismissed': dismissed,
  };

  factory SoundEvent.fromJson(Map<String, dynamic> json) => SoundEvent(
    id: json['id'],
    type: json['type'] ?? 'Unknown',
    confidence: (json['confidence'] ?? 0.8).toDouble(),
    timestamp: DateTime.parse(json['timestamp']),
    severity: json['severity'] ?? 'warning',
    dismissed: json['dismissed'] ?? false,
  );
}

// ===================== RETENTION =====================
class RetentionPolicy {
  final int days;
  final String label;
  const RetentionPolicy({required this.days, required this.label});

  static const options = [
    RetentionPolicy(days: 1, label: '1 day'),
    RetentionPolicy(days: 7, label: '7 days'),
    RetentionPolicy(days: 15, label: '15 days (maximum)'),
  ];

  static const maxRetentionDays = 15;
}

// ===================== LANGUAGE =====================
class LanguageResult {
  final String language;
  final double confidence;
  final String script;

  const LanguageResult({required this.language, required this.confidence, required this.script});
}

// ===================== ALERT POLICY =====================

/// Normalized, immutable snapshot of alert presentation preferences.
///
/// This is the single source of truth for "how should a detected event be
/// presented to the user?" — consumed by both the Flutter alert pipeline
/// and the Android foreground service.
///
/// Detection (SoundDetectionService) is intentionally kept independent of
/// presentation preferences.  Filtering by [allowedAlerts] happens in
/// EnvironmentalProvider.processSoundEvent(), before the event enters
/// alert history or triggers feedback.
class AlertPolicy {
  final bool haptic;
  final bool visual;
  final bool screenFlash;
  final bool flashlight;
  final Set<String> allowedAlerts;

  const AlertPolicy({
    this.haptic = true,
    this.visual = true,
    this.screenFlash = true,
    this.flashlight = false,
    this.allowedAlerts = const {},
  });

  /// Whether [eventType] is allowed to enter alert history and trigger feedback.
  bool isAllowed(String eventType) => allowedAlerts.contains(eventType);

  /// True when no feedback mechanism is enabled.
  bool get isSilent => !haptic && !visual && !screenFlash && !flashlight;

  Map<String, dynamic> toJson() => {
    'haptic': haptic,
    'visual': visual,
    'screenFlash': screenFlash,
    'flashlight': flashlight,
    'allowedAlerts': allowedAlerts.toList()..sort(),
  };

  factory AlertPolicy.fromJson(Map<String, dynamic> json) => AlertPolicy(
    haptic: json['haptic'] as bool? ?? true,
    visual: json['visual'] as bool? ?? true,
    screenFlash: json['screenFlash'] as bool? ?? true,
    flashlight: json['flashlight'] as bool? ?? false,
    allowedAlerts: (json['allowedAlerts'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toSet() ??
        const {},
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AlertPolicy &&
          haptic == other.haptic &&
          visual == other.visual &&
          screenFlash == other.screenFlash &&
          flashlight == other.flashlight &&
          _setEquals(allowedAlerts, other.allowedAlerts);

  @override
  int get hashCode => Object.hash(
        haptic,
        visual,
        screenFlash,
        flashlight,
        Object.hashAll(allowedAlerts.toList()..sort()),
      );

  static bool _setEquals<T>(Set<T> a, Set<T> b) {
    if (a.length != b.length) return false;
    return a.containsAll(b);
  }
}
