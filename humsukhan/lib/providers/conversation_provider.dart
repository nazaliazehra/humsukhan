import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';
import '../services/supabase_service.dart';
import '../services/database_service.dart';
import '../services/scoped_preferences.dart';

/// Manages the Everyday push-to-talk conversation.
///
/// Interaction model:
///  1. Speaker presses & holds the mic → [startSpeakerTurn]
///  2. STT partials update a single [activePartial] message
///  3. Speaker releases the mic → [endSpeakerTurn] commits the message
///  4. User types / picks a quick reply → [addUserMessage]
///  5. Repeat
///
/// Ordering is guaranteed by a monotonically increasing [sequenceCounter].
/// Each committed message receives the next sequence number, so the UI can
/// render a stable ordered list regardless of async callback timing.
class ConversationProvider extends ChangeNotifier {
  ConversationState _state = ConversationState.idle;

  /// Committed messages in insertion order (stable, append-only).
  final List<ConversationMessage> _messages = [];

  /// The single active partial while the speaker holds the mic.
  ConversationMessage? _activePartial;

  bool _isMicHeld = false;
  int _turnId = 0;
  int _sequenceCounter = 0;
  String _currentLanguage = 'English';
  DateTime? _conversationStartedAt;
  String? _currentSessionId;

  // ── Getters ──────────────────────────────────────────────────────

  ConversationState get state => _state;
  List<ConversationMessage> get messages => List.unmodifiable(_messages);
  ConversationMessage? get activePartial => _activePartial;
  bool get isMicHeld => _isMicHeld;
  String get currentLanguage => _currentLanguage;
  DateTime? get conversationStartedAt => _conversationStartedAt;

  /// True when the mic is held and STT should be active.
  bool get isListening => _isMicHeld && _state == ConversationState.active;

  String get listeningStatus {
    if (_isMicHeld) return 'Listening';
    if (_state == ConversationState.active) return 'Waiting for speaker';
    return 'Not listening';
  }

  String get formattedDuration {
    if (_conversationStartedAt == null) return '0:00';
    final diff = DateTime.now().difference(_conversationStartedAt!);
    final minutes = diff.inMinutes;
    final seconds = diff.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  // ── Conversation lifecycle ───────────────────────────────────────

  void startConversation() {
    _state = ConversationState.active;
    _conversationStartedAt = DateTime.now();
    _currentSessionId = _generateSessionId();
    notifyListeners();
  }

  void stopConversation() {
    // Finalize any active speech turn.
    if (_isMicHeld) {
      _isMicHeld = false;
      _commitActivePartial();
    }
    _state = ConversationState.stopping;
    notifyListeners();

    _state = ConversationState.saveDecision;
    notifyListeners();
  }

  void cancelStop() {
    _state = ConversationState.active;
    notifyListeners();
  }

  // ── Push-to-talk ─────────────────────────────────────────────────

  /// Called when the speaker **presses and holds** the mic button.
  ///
  /// Increments the turn counter and creates a fresh [activePartial].
  void startSpeakerTurn() {
    if (_state != ConversationState.active) return;
    _turnId++;
    _isMicHeld = true;
    _activePartial = ConversationMessage(
      text: '',
      owner: 'speaker',
      turnStartedAt: DateTime.now(),
      sequenceNumber: _sequenceCounter, // provisional; finalised on commit
      isPartial: true,
      language: _currentLanguage,
    );
    notifyListeners();
  }

  /// Called with each STT partial result while the mic is held.
  ///
  /// Updates the **same** [activePartial] message — never creates a new one.
  void updatePartialCaption(String text, {String language = 'English'}) {
    if (_activePartial == null || !_isMicHeld) return;
    _currentLanguage = language;
    _activePartial = _activePartial!.copyWith(text: text, language: language);
    notifyListeners();
  }

  /// Called when the speaker **releases** the mic button.
  ///
  /// Commits the active partial as a permanent message (if non-empty) and
  /// clears the partial state.
  void endSpeakerTurn() {
    _isMicHeld = false;
    _commitActivePartial();
    notifyListeners();
  }

  /// Moves [_activePartial] into [_messages] if it has content.
  void _commitActivePartial() {
    if (_activePartial == null) return;
    if (_activePartial!.text.trim().isNotEmpty) {
      _sequenceCounter++;
      _messages.add(_activePartial!.copyWith(
        isPartial: false,
        sequenceNumber: _sequenceCounter,
      ));
    }
    _activePartial = null;
  }

  // ── User messages ────────────────────────────────────────────────

  /// Append a user-typed or quick-reply message.
  ///
  /// The message is assigned the next sequence number so it always appears
  /// after the most recent speaker message, regardless of timing.
  void addUserMessage(String text) {
    if (text.trim().isEmpty || _state != ConversationState.active) return;
    _sequenceCounter++;
    _messages.add(ConversationMessage(
      text: text.trim(),
      owner: 'user',
      turnStartedAt: DateTime.now(),
      sequenceNumber: _sequenceCounter,
      language: _currentLanguage,
    ));
    notifyListeners();
  }

  // ── Persistence ──────────────────────────────────────────────────

  Future<void> saveConversation() async {
    if (_messages.isEmpty) {
      _resetState();
      return;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final scoped = ScopedPreferences.instance;
      final raw =
          prefs.getString(scoped.scopedKey('everydayConversations')) ?? '[]';
      final List<dynamic> conversations = jsonDecode(raw);

      final session = {
        'id': _currentSessionId ?? _generateSessionId(),
        'messages': _messages.map((m) => m.toJson()).toList(),
        'startedAt': _conversationStartedAt?.toIso8601String(),
        'savedAt': DateTime.now().toIso8601String(),
        'language': _currentLanguage,
      };

      conversations.add(session);
      await prefs.setString(
        scoped.scopedKey('everydayConversations'),
        jsonEncode(conversations),
      );

      // Sync to Supabase if authenticated.
      if (SupabaseService.instance.isAuthenticated) {
        final transcript = _messages
            .map((m) => '${m.owner == "speaker" ? "Speaker" : "You"}: ${m.text}')
            .join('\n');
        final professionalSession = ProfessionalSession(
          title: 'Everyday Conversation — ${_formatDate(_conversationStartedAt)}',
          type: SessionType.meeting,
          captionLanguage: _currentLanguage,
          retentionDays: 7,
          status: SessionStatus.completed,
          captions: _messages
              .map((m) => Caption(
                    text: m.text,
                    speaker: m.owner == 'speaker' ? 'Speaker 1' : 'You',
                    language: m.language,
                    isOwn: m.owner == 'user',
                  ))
              .toList(),
          transcriptText: transcript,
        );
        await DatabaseService.instance.upsertSession(professionalSession);
      }

      debugPrint('Everyday conversation saved: ${_messages.length} messages');
    } catch (e) {
      debugPrint('Error saving everyday conversation: $e');
    }

    _resetState();
  }

  void deleteConversation() {
    _resetState();
  }

  // ── Saved conversations ─────────────────────────────────────────

  /// Return all saved everyday conversations from SharedPreferences.
  ///
  /// Each entry contains 'id', 'messages', 'startedAt', 'savedAt',
  /// 'language'.  Messages are ordered by their [sequenceNumber].
  Future<List<Map<String, dynamic>>> getSavedConversations() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final scoped = ScopedPreferences.instance;
      final raw =
          prefs.getString(scoped.scopedKey('everydayConversations')) ?? '[]';
      final List<dynamic> conversations = jsonDecode(raw);
      return conversations.cast<Map<String, dynamic>>();
    } catch (e) {
      debugPrint('Error loading saved conversations: $e');
      return [];
    }
  }

  /// Load a previously saved conversation into the active state.
  ///
  /// Messages are restored in [sequenceNumber] order so the display
  /// matches the original conversation exactly.
  Future<bool> loadConversation(String sessionId) async {
    try {
      final saved = await getSavedConversations();
      final session = saved.firstWhere(
        (s) => s['id'] == sessionId,
        orElse: () => {},
      );
      if (session.isEmpty) return false;

      final messagesRaw = session['messages'] as List<dynamic>? ?? [];
      final messages = messagesRaw
          .map((m) => ConversationMessage.fromJson(m as Map<String, dynamic>))
          .toList();

      // Sort by sequenceNumber to guarantee stable ordering.
      messages.sort((a, b) => a.sequenceNumber.compareTo(b.sequenceNumber));

      _state = ConversationState.active;
      _messages
        ..clear()
        ..addAll(messages);
      _sequenceCounter = messages.isEmpty
          ? 0
          : messages.last.sequenceNumber;
      _currentSessionId = session['id'] as String?;
      _currentLanguage = session['language'] as String? ?? 'English';
      _conversationStartedAt = session['startedAt'] != null
          ? DateTime.tryParse(session['startedAt'] as String)
          : null;
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Error loading conversation: $e');
      return false;
    }
  }

  /// Delete a single saved conversation by its session ID.
  Future<bool> deleteSavedConversation(String sessionId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final scoped = ScopedPreferences.instance;
      final raw =
          prefs.getString(scoped.scopedKey('everydayConversations')) ?? '[]';
      final List<dynamic> conversations = jsonDecode(raw);

      final before = conversations.length;
      conversations.removeWhere((s) => s['id'] == sessionId);
      if (conversations.length == before) return false;

      await prefs.setString(
        scoped.scopedKey('everydayConversations'),
        jsonEncode(conversations),
      );
      return true;
    } catch (e) {
      debugPrint('Error deleting saved conversation: $e');
      return false;
    }
  }

  // ── Reload (user switch) ─────────────────────────────────────────

  Future<void> reload() async {
    _resetState();
  }

  // ── Internal helpers ─────────────────────────────────────────────

  void _resetState() {
    _state = ConversationState.idle;
    _messages.clear();
    _activePartial = null;
    _isMicHeld = false;
    _turnId = 0;
    _sequenceCounter = 0;
    _currentLanguage = 'English';
    _conversationStartedAt = null;
    _currentSessionId = null;
    notifyListeners();
  }

  String _generateSessionId() {
    return 'everyday_${DateTime.now().millisecondsSinceEpoch}';
  }

  String _formatDate(DateTime? dt) {
    if (dt == null) return '';
    return '${dt.day}/${dt.month}/${dt.year} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
