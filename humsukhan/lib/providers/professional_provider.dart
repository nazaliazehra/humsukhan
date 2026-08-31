import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';
import '../services/ai_service.dart';
import '../services/database_service.dart';
import '../services/supabase_service.dart';
import '../services/scoped_preferences.dart';

class ProfessionalProvider extends ChangeNotifier {
  List<ProfessionalSession> _sessions = [];
  List<Folder> _folders = [];
  List<ProfessionalInsight> _insights = [];
  ProfessionalSession? _activeSession;
  bool _isLoading = false;
  String? _syncError;

  // Getters
  List<ProfessionalSession> get sessions => List.unmodifiable(_sessions);
  List<Folder> get folders => List.unmodifiable(_folders);
  List<ProfessionalInsight> get insights => List.unmodifiable(_insights);
  ProfessionalSession? get activeSession => _activeSession;
  bool get isLoading => _isLoading;

  /// Non-null when the most recent cloud sync failed.
  /// `null` after a successful sync or when no sync has been attempted.
  String? get syncError => _syncError;

  List<ProfessionalSession> get recentSessions {
    final completed = _sessions.where((s) => s.status == SessionStatus.completed).toList();
    completed.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return completed.take(5).toList();
  }

  List<ProfessionalSession> getSessionsForFolder(String? folderId) {
    return _sessions.where((s) => s.folderId == folderId).toList();
  }

  ProfessionalInsight? getInsightForSession(String sessionId) {
    try {
      return _insights.firstWhere((i) => i.sessionId == sessionId);
    } catch (_) {
      return null;
    }
  }

  ProfessionalProvider() {
    _loadData();
  }

  /// Reload all professional data for the current user scope.
  /// Called by main.dart when the authenticated user changes.
  Future<void> reload() => _loadData();

  Future<void> _loadData() async {
    _isLoading = true;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      final scoped = ScopedPreferences.instance;

      // Load from local first
      final sessionsJson = prefs.getString(scoped.scopedKey('professionalSessions')) ?? '[]';
      _sessions = (jsonDecode(sessionsJson) as List)
          .map((s) => ProfessionalSession.fromJson(s))
          .toList();

      final foldersJson = prefs.getString(scoped.scopedKey('professionalFolders')) ?? '[]';
      _folders = (jsonDecode(foldersJson) as List)
          .map((f) => Folder.fromJson(f))
          .toList();

      final insightsJson = prefs.getString(scoped.scopedKey('professionalInsights')) ?? '[]';
      _insights = (jsonDecode(insightsJson) as List)
          .map((i) => ProfessionalInsight.fromJson(i))
          .toList();

      // Sync from Supabase if authenticated
      if (SupabaseService.instance.isAuthenticated) {
        await _syncFromCloud();
      }

      // Clean expired sessions (both local and cloud)
      await _cleanExpiredSessions();
    } catch (e) {
      debugPrint('Error loading professional data: $e');
    }

    _isLoading = false;
    notifyListeners();
  }

  /// Merge data from Supabase cloud into the local store.
  ///
  /// Returns `true` on success, `false` when any fetch failed (the local
  /// dataset is left untouched so the app remains usable offline).
  Future<bool> _syncFromCloud() async {
    try {
      final cloudSessions = await DatabaseService.instance.fetchSessions();
      final cloudFolders = await DatabaseService.instance.fetchFolders();
      final cloudInsights = await DatabaseService.instance.fetchInsights();

      // A null result means the fetch failed (offline or network error).
      // Skip the entire merge so stale local data is never overwritten.
      if (cloudSessions == null || cloudFolders == null || cloudInsights == null) {
        _syncError = 'Cloud sync failed — some data may be out of date.';
        debugPrint('Cloud sync: one or more fetches returned null');
        return false;
      }

      // ── Sessions ────────────────────────────────────────────────
      final localById = {for (final s in _sessions) s.id: s};
      for (final cs in cloudSessions) {
        final local = localById[cs.id];
        if (local == null) {
          // Cloud-only session → add locally.
          _sessions.add(cs);
        } else {
          // Both sides have this session — keep the more up-to-date one.
          if (_shouldTakeCloud(cs, local)) {
            final idx = _sessions.indexWhere((s) => s.id == cs.id);
            if (idx != -1) _sessions[idx] = cs;
          }
        }
      }
      if (cloudSessions.isNotEmpty) await _saveSessions();

      // ── Folders ─────────────────────────────────────────────────
      final localFolderIds = _folders.map((f) => f.id).toSet();
      for (final cf in cloudFolders) {
        if (!localFolderIds.contains(cf.id)) {
          _folders.add(cf);
        }
      }
      if (cloudFolders.isNotEmpty) await _saveFolders();

      // ── Insights ────────────────────────────────────────────────
      final localInsightBySession = {for (final i in _insights) i.sessionId: i};
      for (final ci in cloudInsights) {
        final local = localInsightBySession[ci.sessionId];
        if (local == null || ci.generatedAt.isAfter(local.generatedAt)) {
          final idx = _insights.indexWhere((i) => i.sessionId == ci.sessionId);
          if (idx != -1) {
            _insights[idx] = ci;
          } else {
            _insights.add(ci);
          }
        }
      }
      if (cloudInsights.isNotEmpty) await _saveInsights();

      _syncError = null;
      debugPrint(
        'Cloud sync complete: ${_sessions.length} sessions, '
        '${_folders.length} folders, ${_insights.length} insights',
      );
      return true;
    } catch (e) {
      _syncError = 'Cloud sync error: $e';
      debugPrint('Cloud sync error: $e');
      return false;
    }
  }

  /// Decide whether the cloud session should overwrite the local copy.
  ///
  ///  1. A higher [SessionStatus] index wins (completed > in-progress).
  ///  2. If statuses are equal, the newer [updatedAt] wins.
  ///  3. If timestamps are equal or unavailable, prefer the version with
  ///     more captions (richer data), then the one with a transcript.
  ///  4. Never overwrite newer local data with stale cloud data.
  bool _shouldTakeCloud(
    ProfessionalSession cloud,
    ProfessionalSession local,
  ) {
    if (cloud.status.index > local.status.index) return true;
    if (cloud.status.index < local.status.index) return false;

    // Same status — compare updatedAt.
    if (cloud.updatedAt.isAfter(local.updatedAt)) return true;
    if (cloud.updatedAt.isBefore(local.updatedAt)) return false;

    // Same timestamp — prefer the richer dataset.
    if (cloud.captions.length > local.captions.length) return true;
    if (cloud.captions.length < local.captions.length) return false;

    // Last resort: transcript presence.
    if ((cloud.transcriptText?.isNotEmpty ?? false) &&
        !(local.transcriptText?.isNotEmpty ?? false)) {
      return true;
    }
    return false;
  }

  Future<void> _saveSessions() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      ScopedPreferences.instance.scopedKey('professionalSessions'),
      jsonEncode(_sessions.map((s) => s.toJson()).toList()),
    );
  }

  Future<void> _saveFolders() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      ScopedPreferences.instance.scopedKey('professionalFolders'),
      jsonEncode(_folders.map((f) => f.toJson()).toList()),
    );
  }

  Future<void> _saveInsights() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      ScopedPreferences.instance.scopedKey('professionalInsights'),
      jsonEncode(_insights.map((i) => i.toJson()).toList()),
    );
  }

  /// Remove expired sessions from both local storage and cloud.
  Future<void> _cleanExpiredSessions() async {
    final expiredIds = <String>[];
    _sessions.removeWhere((s) {
      if (s.isExpired) {
        expiredIds.add(s.id);
        return true;
      }
      return false;
    });
    if (expiredIds.isNotEmpty) {
      await _saveSessions();
      // Also remove expired sessions and their captions/insights from cloud.
      if (SupabaseService.instance.isAuthenticated) {
        for (final id in expiredIds) {
          await DatabaseService.instance.deleteSession(id);
        }
      }
    }
  }

  // Session management
  Future<ProfessionalSession> createSession({
    required String title,
    required SessionType type,
    String? folderId,
    String captionLanguage = 'English',
    int retentionDays = 7,
  }) async {
    // Enforce hard 15-day maximum retention
    final enforcedRetentionDays = retentionDays.clamp(1, 15);
    final session = ProfessionalSession(
      title: title,
      type: type,
      folderId: folderId,
      captionLanguage: captionLanguage,
      retentionDays: enforcedRetentionDays,
    );
    _sessions.add(session);
    _activeSession = session;
    await _saveSessions();

    // Sync to Supabase
    if (SupabaseService.instance.isAuthenticated) {
      await DatabaseService.instance.upsertSession(session);
    }

    notifyListeners();
    return session;
  }

  void startSessionRecording(String sessionId) {
    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    if (idx != -1) {
      _activeSession = _sessions[idx].copyWith(status: SessionStatus.inProgress);
      _sessions[idx] = _activeSession!;
      _saveSessions();
      notifyListeners();
    }
  }

  Future<void> stopSession(String sessionId) async {
    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    if (idx != -1) {
      final session = _sessions[idx];
      final transcript = session.captions.map((c) => '${c.speaker}: ${c.text}').join('\n');
      _sessions[idx] = session.copyWith(
        status: SessionStatus.completed,
        transcriptText: transcript,
      );
      _activeSession = null;
      await _saveSessions();

      // Sync to Supabase
      if (SupabaseService.instance.isAuthenticated) {
        await DatabaseService.instance.upsertSession(_sessions[idx]);
      }

      notifyListeners();
    }
  }

  /// Add a finalized caption to the session and persist immediately.
  ///
  /// Each call: 1) appends to in-memory captions, 2) saves to local
  /// SharedPreferences, 3) syncs to Supabase when authenticated.
  /// This ensures captions survive app crashes and recognizer restarts.
  void addCaptionToSession(String sessionId, Caption caption) {
    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    if (idx != -1) {
      final session = _sessions[idx];
      final updatedCaptions = List<Caption>.from(session.captions)..add(caption);
      _sessions[idx] = session.copyWith(captions: updatedCaptions);
      _saveSessions();
      // Persist to Supabase incrementally (best-effort, non-blocking).
      _syncCaptionToCloud(sessionId, caption);
      notifyListeners();
    }
  }

  /// Best-effort sync of a single caption to Supabase.
  Future<void> _syncCaptionToCloud(String sessionId, Caption caption) async {
    if (!SupabaseService.instance.isAuthenticated) return;
    try {
      final idx = _sessions.indexWhere((s) => s.id == sessionId);
      if (idx == -1) return;
      await DatabaseService.instance.upsertSession(_sessions[idx]);
    } catch (e) {
      debugPrint('[ProfessionalProvider] Caption cloud sync failed: $e');
    }
  }

  /// Replace the current partial caption (or add a new one) for a live session.
  ///
  /// When [partialId] matches an existing caption with `isPartial == true`,
  /// it is updated in-place; otherwise a new partial caption is appended.
  /// Final captions added via [addCaptionToSession] replace partials
  /// naturally because the screen removes the partial before committing.
  void setPartialCaption(String sessionId, Caption caption, String partialId) {
    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    if (idx != -1) {
      final session = _sessions[idx];
      final updatedCaptions = List<Caption>.from(session.captions);
      final partialIdx = updatedCaptions.indexWhere((c) => c.id == partialId && c.isPartial);
      if (partialIdx != -1) {
        updatedCaptions[partialIdx] = caption;
      } else {
        updatedCaptions.add(caption);
      }
      _sessions[idx] = session.copyWith(captions: updatedCaptions);
      notifyListeners();
    }
  }

  /// Remove a partial caption by ID before committing a final result.
  void removePartialCaption(String sessionId, String partialId) {
    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    if (idx != -1) {
      final session = _sessions[idx];
      final remaining = session.captions.where((c) => c.id != partialId).toList();
      if (remaining.length != session.captions.length) {
        _sessions[idx] = session.copyWith(captions: remaining);
        notifyListeners();
      }
    }
  }

  Future<void> deleteSession(String sessionId) async {
    _sessions.removeWhere((s) => s.id == sessionId);
    _insights.removeWhere((i) => i.sessionId == sessionId);
    await _saveSessions();
    await _saveInsights();

    // Delete from Supabase
    if (SupabaseService.instance.isAuthenticated) {
      await DatabaseService.instance.deleteSession(sessionId);
    }

    notifyListeners();
  }

  /// Re-insert a session that was just deleted (for undo). Also restores
  /// its insight if present. Does NOT re-sync to Supabase — the delete
  /// has already propagated; undo simply prevents permanent loss.
  void restoreSession(ProfessionalSession session, {ProfessionalInsight? insight}) {
    if (!_sessions.any((s) => s.id == session.id)) {
      _sessions.add(session);
    }
    if (insight != null && !_insights.any((i) => i.sessionId == insight.sessionId)) {
      _insights.add(insight);
    }
    _saveSessions();
    _saveInsights();
    notifyListeners();
  }

  // Folder management

  /// Create a folder locally and sync to Supabase.
  Future<Folder> createFolder(String name) async {
    final folder = Folder(name: name);
    _folders.add(folder);
    await _saveFolders();

    if (SupabaseService.instance.isAuthenticated) {
      await DatabaseService.instance.upsertFolder(folder);
    }

    notifyListeners();
    return folder;
  }

  /// Delete a folder, move its sessions to "no folder", and sync both
  /// operations to Supabase.
  Future<void> deleteFolder(String folderId) async {
    // Reconstruct sessions with folderId explicitly set to null
    // (copyWith's `??` guard would preserve the old value for nullables).
    final updatedSessions = <ProfessionalSession>[];
    for (var i = 0; i < _sessions.length; i++) {
      if (_sessions[i].folderId == folderId) {
        final s = _sessions[i];
        _sessions[i] = ProfessionalSession(
          id: s.id,
          title: s.title,
          type: s.type,
          captionLanguage: s.captionLanguage,
          retentionDays: s.retentionDays,
          createdAt: s.createdAt,
          expiresAt: s.expiresAt,
          status: s.status,
          captions: s.captions,
          transcriptText: s.transcriptText,
        );
        updatedSessions.add(_sessions[i]);
      }
    }
    _folders.removeWhere((f) => f.id == folderId);
    await _saveFolders();
    await _saveSessions();

    if (SupabaseService.instance.isAuthenticated) {
      // Update moved sessions remotely (clear their folder_id).
      for (final s in updatedSessions) {
        await DatabaseService.instance.upsertSession(s);
      }
      await DatabaseService.instance.deleteFolder(folderId);
    }

    notifyListeners();
  }

  /// Move a session to a different folder (or to no folder when
  /// [folderId] is null) and sync remotely.
  Future<void> moveSessionToFolder(String sessionId, String? folderId) async {
    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    if (idx != -1) {
      final s = _sessions[idx];
      // Reconstruct to allow folderId to be explicitly set to null.
      _sessions[idx] = ProfessionalSession(
        id: s.id,
        title: s.title,
        type: s.type,
        folderId: folderId,
        captionLanguage: s.captionLanguage,
        retentionDays: s.retentionDays,
        createdAt: s.createdAt,
        expiresAt: s.expiresAt,
        status: s.status,
        captions: s.captions,
        transcriptText: s.transcriptText,
      );
      await _saveSessions();

      if (SupabaseService.instance.isAuthenticated) {
        await DatabaseService.instance.upsertSession(_sessions[idx]);
      }

      notifyListeners();
    }
  }

  // AI Insights — uses real AI (Gemini Flash) when available, local extraction as fallback
  Future<void> generateInsights(String sessionId) async {
    final session = _sessions.firstWhere((s) => s.id == sessionId);
    final existingIdx = _insights.indexWhere((i) => i.sessionId == sessionId);

    final allText = session.captions.map((c) => c.text).join('\n');
    if (allText.trim().isEmpty) return;

    // Try real AI first — pass the transcript language so the Edge Function
    // can instruct Gemini to produce output in the correct language/script.
    ProfessionalInsight? aiInsight;
    if (AiService.instance.isAvailable) {
      aiInsight = await AiService.instance.generateInsights(
        sessionId: sessionId,
        transcript: allText,
        sessionTitle: session.title,
        sessionType: session.type,
        language: session.captionLanguage,
      );
    }

    // Fall back to local extraction if AI unavailable
    final insight = aiInsight ?? _generateLocalInsights(session, allText);

    if (existingIdx != -1) {
      _insights[existingIdx] = insight;
    } else {
      _insights.add(insight);
    }
    await _saveInsights();

    // Sync to Supabase
    if (SupabaseService.instance.isAuthenticated) {
      await DatabaseService.instance.upsertInsight(insight);
    }

    notifyListeners();
  }

  // ── Local fallback helpers ──────────────────────────────────────────────
  //
  // These methods provide basic keyword/theme extraction when the AI
  // service is unavailable. They are script-aware so that Urdu (Arabic
  // script) and Hindi (Devanagari script) text is not destroyed.

  /// Local keyword extraction fallback when AI is unavailable.
  ProfessionalInsight _generateLocalInsights(ProfessionalSession session, String allText) {
    final lang = session.captionLanguage;
    return ProfessionalInsight(
      sessionId: session.id,
      summary: _buildLocalOverview(session, allText),
      vocabulary: _extractVocabulary(allText, lang),
      themes: _extractThemes(allText, session.title, lang),
      actionItems: _extractActionItems(allText, lang),
      deadlines: _extractDeadlines(allText, lang),
      // Speaker labels ("Speaker 1", etc.) are NOT mentioned people.
      // Reliable name extraction requires semantic understanding that only
      // the AI path can provide — the local fallback returns an empty list.
      mentionedPeople: [],
      isAvailable: session.captions.isNotEmpty,
      source: InsightSource.local,
      language: lang,
    );
  }

  /// Split text into sentences, handling Latin, Arabic-script, and
  /// Devanagari punctuation.
  List<String> _splitSentences(String text) {
    // U+06D4 = Arabic full stop (۔), U+0964 = Devanagari danda (।)
    return text
        .split(RegExp(r'[.!?\u06D4\u0964]+'))
        .where((s) => s.trim().length > 5)
        .toList();
  }

  /// Detect the dominant script of a text sample.
  bool _hasArabicScript(String text) =>
      RegExp(r'[\u0600-\u06FF\u0750-\u077F\uFB50-\uFDFF\uFE70-\uFEFF]').hasMatch(text);

  bool _hasDevanagariScript(String text) =>
      RegExp(r'[\u0900-\u097F\uA8E0-\uA8FF]').hasMatch(text);

  /// Language-aware vocabulary extraction.
  ///
  /// Preserves Arabic-script characters for Urdu and Devanagari characters
  /// for Hindi, instead of stripping them with the old `[^a-zA-Z\s]` regex.
  List<String> _extractVocabulary(String text, String language) {
    if (text.isEmpty) return [];

    final hasArabic = _hasArabicScript(text);
    final hasDevanagari = _hasDevanagariScript(text);

    // Build a regex that keeps word characters for the dominant script.
    RegExp nonWord;
    if (hasArabic) {
      // Keep Latin + Arabic script letters and whitespace.
      nonWord = RegExp(r'[^a-zA-Z\u0600-\u06FF\u0750-\u077F\s]');
    } else if (hasDevanagari) {
      // Keep Latin + Devanagari letters and whitespace.
      nonWord = RegExp(r'[^a-zA-Z\u0900-\u097F\uA8E0-\uA8FF\s]');
    } else {
      // Latin-only fallback.
      nonWord = RegExp(r'[^a-zA-Z\s]');
    }

    final words = text
        .toLowerCase()
        .replaceAll(nonWord, '')
        .split(RegExp(r'\s+'))
        .where((w) => w.length >= 3)
        .toList();

    final freq = <String, int>{};
    for (final w in words) {
      freq[w] = (freq[w] ?? 0) + 1;
    }

    final stopWords = _getStopWords(language);
    final sorted = freq.entries
        .where((e) => !stopWords.contains(e.key) && e.value >= 1)
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return sorted.take(8).map((e) => e.key).toList();
  }

  /// Language-specific stop words for vocabulary filtering.
  Set<String> _getStopWords(String language) {
    switch (language) {
      case 'Urdu':
        return {
          '\u06CC\u06C1', '\u06C1\u06D2', '\u06A9\u0627', '\u06A9\u06D2',
          '\u06A9\u06CC', '\u0645\u06CC\u06BA', '\u067E\u0631', '\u0633\u06D2',
          '\u0646\u06C1\u06CC\u06BA', '\u0627\u0648\u0631', '\u06CC\u0627',
          '\u0628\u06BE\u06CC', '\u062C\u0628', '\u062A\u0628',
          '\u0627\u0633', '\u0627\u0646', '\u0627\u0646\u06A9\u0627',
          '\u062C\u0648', '\u06A9\u0631', '\u06A9\u0631\u0646\u0627',
          '\u0628\u0627\u062A', '\u06A9\u06CC\u0627',
        };
      case 'Hindi':
        return {
          '\u0915\u093E', '\u0915\u0947', '\u0915\u0940', '\u0915\u094B',
          '\u092E\u0947\u0902', '\u0939\u0948', '\u0939\u0940\u0902',
          '\u092A\u0930', '\u0938\u0947', '\u0928\u0939\u0940\u0902',
          '\u0914\u0930', '\u092F\u093E', '\u092D\u0940',
          '\u092F\u0939', '\u0935\u0939', '\u0907\u0938',
          '\u0909\u0938', '\u091C\u094B', '\u0915\u0930',
          '\u0915\u0930\u0928\u093E', '\u092C\u093E\u0924',
          '\u0915\u094D\u092F\u093E', '\u091C\u092C', '\u0924\u092C',
        };
      case 'Roman Urdu':
        return {
          'ka', 'ke', 'ki', 'ko', 'mein', 'hai', 'hain', 'par', 'se',
          'nahi', 'aur', 'ya', 'bhi', 'yeh', 'woh', 'is', 'us', 'jo',
          'kar', 'karna', 'baat', 'kya', 'jab', 'tab', 'tha', 'thi',
          'the', 'ho', 'hi', 'ne', 'ye', 'wo', 'ek', 'to',
          'this', 'that', 'with', 'from', 'have', 'will',
        };
      default: // English
        return {
          'this', 'that', 'with', 'from', 'have', 'will', 'been', 'were',
          'they', 'their', 'them', 'than', 'then', 'also', 'what', 'when',
          'your', 'just', 'some', 'more', 'very', 'like', 'each', 'much',
          'about', 'would', 'could', 'should', 'there', 'these', 'those',
          'into', 'over', 'only', 'other', 'such', 'after', 'well', 'know',
        };
    }
  }

  /// Language-aware theme extraction.
  ///
  /// Matches keywords in English, Roman Urdu, and common Urdu/Hindi terms
  /// to produce human-readable theme labels.
  List<String> _extractThemes(String text, String title, String language) {
    if (text.isEmpty) return [title];
    final themes = <String>[];
    themes.add(title);

    final sentences = _splitSentences(text);

    // Multilingual keyword → theme label mapping.
    final themeKeywords = <String, String>{
      // English
      'planning': 'Planning & Scheduling',
      'testing': 'Quality Assurance',
      'design': 'Design & Architecture',
      'review': 'Review & Feedback',
      'deploy': 'Deployment',
      'launch': 'Product Launch',
      'meeting': 'Collaboration',
      'discuss': 'Discussion',
      'deadline': 'Timeline Management',
      'team': 'Team Coordination',
      'feature': 'Feature Development',
      'bug': 'Issue Resolution',
      'requirement': 'Requirements',
      'feedback': 'Feedback',
      // Roman Urdu
      'plan': 'Planning & Scheduling',
      'kaam': 'Task Management',
      'masla': 'Issue Resolution',
      'tajweez': 'Proposals',
      'jaiza': 'Review & Feedback',
      // Urdu script
      '\u067E\u0644\u06CC\u0646': 'Planning & Scheduling',
      '\u06A9\u0627\u0645': 'Task Management',
      '\u0645\u0633\u0626\u0644\u06C1': 'Issue Resolution',
      '\u062A\u062C\u0648\u06CC\u0632': 'Proposals',
      '\u062C\u0627\u0626\u0632\u06C1': 'Review & Feedback',
      // Hindi (Devanagari)
      '\u092F\u094B\u091C\u0928\u093E': 'Planning & Scheduling',
      '\u0915\u093E\u092E': 'Task Management',
      '\u0938\u092E\u0938\u094D\u092F\u093E': 'Issue Resolution',
      '\u0938\u0941\u091D\u093E\u0935': 'Proposals',
      '\u0938\u092E\u0940\u0915\u094D\u0937\u093E': 'Review & Feedback',
    };

    for (final sentence in sentences) {
      final lower = sentence.toLowerCase();
      for (final entry in themeKeywords.entries) {
        if (lower.contains(entry.key) && !themes.contains(entry.value)) {
          themes.add(entry.value);
        }
      }
    }

    return themes.take(5).toList();
  }

  /// Language-aware action item extraction.
  List<String> _extractActionItems(String text, String language) {
    if (text.isEmpty) return [];
    final actions = <String>[];
    final sentences = _splitSentences(text);

    // English action triggers.
    final actionPatterns = <RegExp>[
      RegExp(r'\b(need to|must|should|will|going to|plan to|have to)\b', caseSensitive: false),
      RegExp(r'\b(complete|prepare|review|finish|send|update|create|build|fix|check)\b', caseSensitive: false),
    ];

    // Add Roman Urdu / Urdu / Hindi patterns for non-English sessions.
    if (language == 'Roman Urdu') {
      actionPatterns.addAll([
        RegExp(r'\b(karna hai|karna zaroori|karna chahiye|lazmi)\b', caseSensitive: false),
        RegExp(r'\b(tayyar|bhejo|check|dekho|shuru|khatam)\b', caseSensitive: false),
      ]);
    }
    if (language == 'Urdu') {
      actionPatterns.addAll([
        RegExp(r'\u06A9\u0631\u0646\u0627\s*\u06C1\u06D2'), // کرنا ہے
        RegExp(r'\u0644\u0627\u0632\u0645\u06CC'),           // لازمی
        RegExp(r'\u0636\u0631\u0648\u0631\u06CC'),             // ضروری
        RegExp(r'\u0686\u0627\u06C1\u06CC\u06D2'),             // چاہیے
      ]);
    }
    if (language == 'Hindi') {
      actionPatterns.addAll([
        RegExp(r'\u0915\u0930\u0928\u093E\s*\u0939\u0948'),   // करना है
        RegExp(r'\u091C\u0930\u0942\u0930\u0940'),               // ज़रूरी
        RegExp(r'\u091A\u093E\u0939\u093F\u090F'),               // चाहिए
      ]);
    }

    for (final sentence in sentences) {
      final trimmed = sentence.trim();
      if (trimmed.isEmpty) continue;
      for (final pattern in actionPatterns) {
        if (pattern.hasMatch(trimmed) && actions.length < 5) {
          if (!actions.contains(trimmed)) {
            actions.add(trimmed);
          }
          break;
        }
      }
    }

    return actions;
  }

  /// Language-aware deadline extraction.
  List<String> _extractDeadlines(String text, String language) {
    if (text.isEmpty) return [];
    final deadlines = <String>[];
    final sentences = _splitSentences(text);

    // Numeric date patterns — work across all languages.
    final datePatterns = <RegExp>[
      RegExp(r'\b(\d{1,2}/\d{1,2}/\d{2,4})'),
      RegExp(r'\b(\d{4}-\d{2}-\d{2})'),
    ];

    // English temporal terms.
    datePatterns.addAll([
      RegExp(r'\b(january|february|march|april|may|june|july|august|september|october|november|december)\s+\d{1,2}', caseSensitive: false),
      RegExp(r'\b(next week|this week|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b', caseSensitive: false),
      RegExp(r'\b(by\s+\w+\s+\d{1,2})', caseSensitive: false),
    ]);

    // Add language-specific temporal terms.
    if (language == 'Roman Urdu') {
      datePatterns.add(RegExp(r'\b(kal|agle hafte|is hafte|agle mahine)\b', caseSensitive: false));
    }
    if (language == 'Urdu') {
      datePatterns.addAll([
        RegExp(r'\u06A9\u0644'),       // کل (tomorrow/yesterday)
        RegExp(r'\u0627\u06AF\u0644\u06D2\s*\u06C1\u0641\u062A\u06D2'), // اگلے ہفتے (next week)
      ]);
    }
    if (language == 'Hindi') {
      datePatterns.addAll([
        RegExp(r'\u0915\u0932'),                       // कल (tomorrow/yesterday)
        RegExp(r'\u0905\u0917\u0932\u0947\s*\u0939\u092B\u094D\u0924\u0947'), // अगले हफ्ते (next week)
      ]);
    }

    for (final sentence in sentences) {
      final trimmed = sentence.trim();
      for (final pattern in datePatterns) {
        final match = pattern.firstMatch(trimmed);
        if (match != null && deadlines.length < 5) {
          if (!deadlines.any((d) => d == trimmed)) {
            deadlines.add(trimmed);
          }
          break;
        }
      }
    }

    return deadlines;
  }

  /// Build a factual session overview for the local fallback.
  ///
  /// This is NOT a summary (which requires semantic understanding that only
  /// AI can provide). It is a metadata-based overview that honestly describes
  /// the session without pretending to analyse its content.
  String _buildLocalOverview(ProfessionalSession session, String allText) {
    if (allText.isEmpty) {
      return 'No content was captured in this session.';
    }

    final captionCount = session.captions.length;
    final lang = session.captionLanguage;
    final typeLabel = session.type == SessionType.meeting
        ? 'meeting'
        : session.type == SessionType.lecture
            ? 'lecture'
            : 'class';

    return 'This $typeLabel session ("${session.title}") was recorded in $lang '
        'and contains $captionCount captions. '
        'Connect to the internet for AI-generated insights.';
  }

  // Retention check — cleans both local and cloud data.
  Future<void> checkRetention() async {
    await _cleanExpiredSessions();
    notifyListeners();
  }

  // Set a demo session with captions
  void addDemoSession() {
    final session = ProfessionalSession(
      title: 'Product Launch Planning',
      type: SessionType.meeting,
      captionLanguage: 'English',
      retentionDays: 7,
      status: SessionStatus.completed,
      captions: [
        Caption(text: 'Welcome everyone to the product launch planning meeting.', speaker: 'Speaker 1'),
        Caption(text: 'We need to finalize the testing timeline by next week.', speaker: 'Speaker 2'),
        Caption(text: 'I will prepare the launch documentation by September 10th.', speaker: 'Speaker 1'),
        Caption(text: 'Great, let\'s also review the deployment checklist together.', speaker: 'Speaker 2'),
      ],
    );
    _sessions.add(session);
    _saveSessions();
    notifyListeners();
  }
}
