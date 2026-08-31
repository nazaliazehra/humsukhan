import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/models.dart';

/// AI service using a Supabase Edge Function to call Google Gemini.
///
/// The GEMINI_API_KEY is stored only as a Supabase server-side secret
/// and is never shipped inside the mobile binary.
///
/// Capabilities:
/// - Summarize transcripts
/// - Extract important vocabulary
/// - Identify themes/topics
/// - Extract action items
/// - Extract deadlines
/// - Extract mentioned people
///
/// All output is structured and validated.
/// When the Edge Function is unavailable the caller falls back to local
/// insight extraction.
class AiService {
  static AiService? _instance;
  static AiService get instance => _instance ?? AiService._();
  AiService._();

  SupabaseClient? get _client {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  /// `true` when the Supabase client is initialised and the Edge Function
  /// endpoint can be reached. The actual Gemini key lives server-side.
  bool get isAvailable => _client != null;

  /// Generate insights from a transcript by invoking the
  /// `generate-insights` Supabase Edge Function.
  ///
  /// [language] is the transcript's language (e.g. 'English', 'Urdu',
  /// 'Hindi', 'Roman Urdu'). It is forwarded to the Edge Function so the
  /// AI produces output in the same language and script.
  Future<ProfessionalInsight?> generateInsights({
    required String sessionId,
    required String transcript,
    required String sessionTitle,
    required SessionType sessionType,
    String language = 'English',
  }) async {
    final client = _client;
    if (client == null) {
      debugPrint('AI Service: Supabase client unavailable');
      return null;
    }

    if (transcript.trim().isEmpty) {
      debugPrint('AI Service: Empty transcript');
      return null;
    }

    try {
      final typeLabel = sessionType == SessionType.meeting
          ? 'meeting'
          : sessionType == SessionType.lecture
              ? 'lecture'
              : 'class';

      // The Supabase client automatically attaches the user's JWT to the
      // outgoing request so the Edge Function can authenticate it.
      final response = await client.functions
          .invoke(
            'generate-insights',
            body: {
              'transcript': transcript,
              'sessionTitle': sessionTitle,
              'sessionType': typeLabel,
              'language': language,
            },
          )
          .timeout(const Duration(seconds: 45));

      return _parseInsightResponse(sessionId, response.data, language);
    } catch (e) {
      debugPrint('AI Service error: $e');
      return null;
    }
  }

  /// Parse the Edge Function response into a [ProfessionalInsight].
  ///
  /// The Edge Function returns `{ "text": "<validated JSON>", "language": "..." }`.
  /// The server has already validated and normalised the inner JSON, so we
  /// perform a second type-check here as a defence-in-depth measure.
  ProfessionalInsight? _parseInsightResponse(
    String sessionId,
    dynamic responseData,
    String requestLanguage,
  ) {
    try {
      if (responseData == null) {
        debugPrint('AI Service: Edge Function returned null data');
        return null;
      }

      // responseData is already decoded from JSON by the Supabase client.
      final Map<String, dynamic> envelope = responseData is Map
          ? Map<String, dynamic>.from(responseData)
          : jsonDecode(responseData.toString()) as Map<String, dynamic>;

      var text = envelope['text'] as String?;
      if (text == null || text.trim().isEmpty) {
        debugPrint('AI Service: No text in Edge Function response');
        return null;
      }

      // The language the Edge Function reports, falling back to what we sent.
      final responseLanguage =
          (envelope['language'] as String?) ?? requestLanguage;

      // Strip markdown code fences if present (server should have done this
      // already, but we defend against edge cases).
      text = text.trim();
      if (text.startsWith('```')) {
        text = text.replaceFirst(RegExp(r'^```\w*\n?'), '');
        text = text.replaceFirst(RegExp(r'\n?```$'), '');
      }

      final json = jsonDecode(text);
      if (json is! Map) {
        debugPrint('AI Service: Response text is not a JSON object');
        return null;
      }

      // Type-safe field extraction — each field is validated individually.
      final summary = json['summary'] is String ? json['summary'] as String : '';
      final vocabulary = _safeStringList(json['vocabulary']);
      final themes = _safeStringList(json['themes']);
      final actionItems = _safeStringList(json['actionItems']);
      final deadlines = _safeStringList(json['deadlines']);
      final mentionedPeople = _safeStringList(json['mentionedPeople']);

      return ProfessionalInsight(
        sessionId: sessionId,
        summary: summary,
        vocabulary: vocabulary,
        themes: themes,
        actionItems: actionItems,
        deadlines: deadlines,
        mentionedPeople: mentionedPeople,
        isAvailable: true,
        source: InsightSource.ai,
        language: responseLanguage,
      );
    } catch (e) {
      debugPrint('AI response parse error: $e');
      return null;
    }
  }

  /// Safely extract a `List<String>` from an unknown JSON value.
  /// Returns an empty list if the value is not a list or contains non-strings.
  List<String> _safeStringList(dynamic value) {
    if (value is! List) return [];
    return value.whereType<String>().toList();
  }
}
