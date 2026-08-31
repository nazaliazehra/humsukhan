import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/providers.dart';
import '../theme/app_theme.dart';
import '../models/models.dart';
import '../widgets/reusable_widgets.dart';
import '../l10n/app_strings.dart';

/// Professional Mode live session screen.
///
/// Architectural guarantee: the recognizer lifecycle is DECOUPLED from the
/// professional session lifecycle.  When Android stops the speech recognizer
/// (recognition window, timeout, transient failure), this screen restarts the
/// recognizer while preserving the SAME session ID, the SAME transcript, and
/// ALL previously-finalised captions.
///
/// Key design decisions:
///  - Each partial caption gets a **fresh UUID** so that stale partials from
///    a previous recognition cycle are never silently overwritten.
///  - When a new partial arrives and the previous partial was never finalised
///    (e.g. the recognizer restarted), the old partial is committed first.
///  - A heartbeat timer detects stalled STT and triggers a recovery restart.
///  - Every finalised caption is persisted to SharedPreferences AND Supabase
///    immediately — not deferred to Stop Session.
class SessionLiveScreen extends StatefulWidget {
  final String sessionId;
  const SessionLiveScreen({super.key, required this.sessionId});

  @override
  State<SessionLiveScreen> createState() => _SessionLiveScreenState();
}

class _SessionLiveScreenState extends State<SessionLiveScreen> {
  final TextEditingController _captionController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  StreamSubscription? _speechSubscription;
  Timer? _durationTimer;
  Timer? _heartbeatTimer;
  late DateTime _startTime;

  // ── STT lifecycle state ──────────────────────────────────────────

  /// Whether the STT engine has been initialised and started at least once.
  bool _sttInitialised = false;

  /// Whether the recognizer is actively listening (may be temporarily false
  /// during a recovery restart).
  bool _isListening = false;

  /// Non-null when the STT engine is in an unrecoverable error state.
  String? _sttError;

  /// The current partial caption's UUID.  Freshly generated for every
  /// new utterance / recognition cycle so stale partials are never overwritten.
  String _partialCaptionId = _newPartialId();

  /// Text of the current partial — used to detect whether a new partial
  /// is a continuation of the previous one or a brand-new utterance.
  String _partialText = '';

  String _sessionLanguage = 'English';
  bool _isStopping = false;

  /// How many times the recognizer has been restarted (for UI feedback).
  int _restartCount = 0;

  // ── Partial ID generator ─────────────────────────────────────────

  static String _newPartialId() => 'partial_${DateTime.now().microsecondsSinceEpoch}';

  // ── Lifecycle ────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _startTime = DateTime.now();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _initSession());
  }

  Future<void> _initSession() async {
    final pro = context.read<ProfessionalProvider>();
    pro.startSessionRecording(widget.sessionId);

    // Resolve the session's caption language for the STT engine.
    final session = pro.sessions.firstWhere(
      (s) => s.id == widget.sessionId,
      orElse: () => ProfessionalSession(
          title: 'Session', status: SessionStatus.inProgress),
    );
    _sessionLanguage = session.captionLanguage;

    // Initialise the speech engine with the session's language.
    final speech = context.read<SpeechProvider>();
    await speech.initialize(preferredLanguage: _sessionLanguage);

    if (!mounted) return;

    if (speech.isLiveStt) {
      await _startListening(speech);
    } else {
      setState(() => _sttError =
          AppStrings.of(context).sttUnavailableForLang(_sessionLanguage));
    }

    // Subscribe to STT results (partials + finals).
    _speechSubscription = speech.onResult.listen(_onSpeechResult);

    // Start the heartbeat that detects stalled STT.
    _resetHeartbeat();
  }

  // ── STT start / restart ──────────────────────────────────────────

  Future<void> _startListening(SpeechProvider speech) async {
    try {
      await speech.startListening(language: _sessionLanguage);
      if (!mounted) return;
      setState(() {
        _sttInitialised = true;
        _isListening = true;
        _sttError = null;
      });
      _resetHeartbeat();
    } catch (e) {
      if (!mounted) return;
      setState(() => _sttError = e.toString());
      debugPrint('[SessionLive] STT start failed: $e');
    }
  }

  /// Restart the recognizer after a transient failure or recognition-window
  /// timeout.  The session, transcript, and all previous captions are
  /// preserved — only the STT engine is recycled.
  Future<void> _restartListening() async {
    if (_isStopping || !mounted) return;

    debugPrint('[SessionLive] Restarting recognizer (attempt ${_restartCount + 1})');
    setState(() {
      _isListening = false; // briefly shows "Recovering…" in the banner
    });

    // Commit any orphaned partial before restarting.
    _finalizeOrphanedPartial();

    final speech = context.read<SpeechProvider>();
    try {
      await speech.stopListening();
    } catch (_) {}

    // Brief pause so the platform can release the audio session.
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;

    await _startListening(speech);

    if (_isListening) {
      _restartCount++;
    }
  }

  // ── Heartbeat — detects stalled STT ──────────────────────────────

  /// If no STT result arrives within [_heartbeatTimeout], the recognizer
  /// is assumed to have died silently and a recovery restart is triggered.
  static const _heartbeatTimeout = Duration(seconds: 8);

  void _resetHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer(_heartbeatTimeout, _onHeartbeatTimeout);
  }

  void _onHeartbeatTimeout() {
    if (!mounted || _isStopping || !_isListening) return;
    debugPrint('[SessionLive] Heartbeat timeout — restarting recognizer');
    _restartListening();
  }

  // ── Speech result handler ────────────────────────────────────────

  void _onSpeechResult(dynamic result) {
    if (!mounted || _isStopping) return;

    // Reset heartbeat — recognizer is alive.
    _resetHeartbeat();

    final text = result.text as String? ?? '';
    final isFinal = result.isFinal as bool? ?? false;

    if (isFinal && text.trim().isNotEmpty) {
      // ── Final result ──────────────────────────────────────────
      // Finalise the old partial (if still present) then commit
      // the final text as a permanent caption.
      _finalizeOrphanedPartial();
      _commitFinalCaption(text.trim(), result.language as String? ?? _sessionLanguage);
      // Reset partial state for the next utterance.
      _partialCaptionId = _newPartialId();
      _partialText = '';
    } else if (!isFinal && text.trim().isNotEmpty) {
      // ── Partial result ────────────────────────────────────────
      // If the new partial text does NOT start with the previous
      // partial text, the recognizer has started a fresh utterance
      // (e.g. after a restart).  Finalise the old partial first.
      if (_partialText.isNotEmpty && !text.startsWith(_partialText)) {
        _finalizeOrphanedPartial();
        _partialCaptionId = _newPartialId();
      }
      _partialText = text;
      _updatePartialCaption(text, result.language as String? ?? _sessionLanguage);
    }

    _scrollToBottom();
  }

  // ── Caption operations ───────────────────────────────────────────

  /// Commit a final caption to the session.  The caption is persisted
  /// to SharedPreferences AND synced to Supabase immediately.
  void _commitFinalCaption(String text, String language) {
    context.read<ProfessionalProvider>().addCaptionToSession(
      widget.sessionId,
      Caption(
        text: text,
        speaker: 'Speaker 1',
        language: language,
        isPartial: false,
      ),
    );
  }

  /// Update (or create) the current partial caption bubble.
  void _updatePartialCaption(String text, String language) {
    final caption = Caption(
      id: _partialCaptionId,
      text: text,
      speaker: 'Speaker 1',
      language: language,
      isPartial: true,
    );
    context.read<ProfessionalProvider>().setPartialCaption(
      widget.sessionId,
      caption,
      _partialCaptionId,
    );
  }

  /// Finalise any orphaned partial caption — i.e. a partial that was never
  /// followed by a final result (e.g. because the recognizer restarted).
  void _finalizeOrphanedPartial() {
    final pro = context.read<ProfessionalProvider>();
    final session = pro.sessions.firstWhere(
      (s) => s.id == widget.sessionId,
      orElse: () => ProfessionalSession(
          title: 'Session', status: SessionStatus.inProgress),
    );

    // Find any remaining partial captions.
    final partials = session.captions
        .where((c) => c.isPartial && c.text.trim().isNotEmpty)
        .toList();

    for (final p in partials) {
      // Commit the partial text as a final caption.
      pro.addCaptionToSession(
        widget.sessionId,
        Caption(
          text: p.text,
          speaker: p.speaker,
          language: p.language,
          isPartial: false,
        ),
      );
      // Remove the partial.
      pro.removePartialCaption(widget.sessionId, p.id);
    }
  }

  /// Auto-scroll to the bottom only when the user is already near the
  /// bottom (within 200 px).  If the user has deliberately scrolled up
  /// to read older captions, we do NOT yank them back down.
  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollController.hasClients && !_isStopping) {
        final pos = _scrollController.position;
        final distanceFromBottom = pos.maxScrollExtent - pos.pixels;
        // Only auto-scroll if user is within 200 px of the bottom.
        if (distanceFromBottom < 200) {
          _scrollController.animateTo(
            pos.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      }
    });
  }

  String get _duration {
    final diff = DateTime.now().difference(_startTime);
    return '${diff.inMinutes}:${(diff.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _speechSubscription?.cancel();
    _durationTimer?.cancel();
    _heartbeatTimer?.cancel();
    _captionController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // ── Build ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final pro = context.watch<ProfessionalProvider>();
    final session = pro.sessions.firstWhere(
      (s) => s.id == widget.sessionId,
      orElse: () => ProfessionalSession(
          title: 'Session', status: SessionStatus.inProgress),
    );
    final s = AppStrings.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(session.title),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: AppTheme.successLight.withValues(alpha: 0.15),
                  borderRadius:
                      BorderRadius.circular(AppTheme.radiusFull),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.circle,
                      size: 8, color: AppTheme.successLight),
                  const SizedBox(width: 6),
                  Text(_duration,
                      style: TextStyle(
                          color: AppTheme.successLight,
                          fontWeight: FontWeight.w700,
                          fontSize: 14)),
                ]),
              ),
            ),
          ),
        ],
      ),
      body: Column(children: [
        // ── Session info banner ─────────────────────────────────
        Container(
          width: double.infinity,
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: AppTheme.successLight.withValues(alpha: 0.1),
          child: Row(children: [
            Icon(Icons.mic, color: AppTheme.successLight, size: 18),
            const SizedBox(width: 8),
            Expanded(
                child: Text(
                    '${s.liveSession} · ${session.captionLanguage} · ${session.type.name}',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: AppTheme.successLight),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis)),
          ]),
        ),

        // ── Main content ────────────────────────────────────────
        Expanded(
          child: _sttError != null
              ? _buildErrorState(s)
              : Column(children: [
                  // Status banner — listening / recovering
                  _buildStatusBanner(s),
                  // Caption list
                  Expanded(
                    child: session.captions.isEmpty
                        ? Center(
                            child: Text(s.waitingForSpeech,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color: Colors.grey[400],
                                    fontSize: 16)))
                        : ListView.builder(
                            key: const ValueKey('professional_transcript_list'),
                            controller: _scrollController,
                            padding: const EdgeInsets.all(16),
                            // No artificial cap — a session with hundreds or
                            // thousands of captions remains one continuous list.
                            itemCount: session.captions.length,
                            itemBuilder: (context, index) {
                              final c = session.captions[index];
                              // Stable key per caption ensures Flutter preserves
                              // widget state for existing items when new ones are
                              // appended at the bottom.
                              return Padding(
                                  key: ValueKey('caption_${c.id}'),
                                  padding:
                                      const EdgeInsets.only(bottom: 12),
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                            '${c.speaker} · ${c.timestamp.hour.toString().padLeft(2, '0')}:${c.timestamp.minute.toString().padLeft(2, '0')}',
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.copyWith(
                                                    fontWeight:
                                                        FontWeight.w600)),
                                        const SizedBox(height: 4),
                                        Text(c.text,
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodyLarge
                                                ?.copyWith(
                                                    fontStyle: c.isPartial
                                                        ? FontStyle.italic
                                                        : null,
                                                    color: c.isPartial
                                                        ? Colors.grey[600]
                                                        : null)),
                                      ]));
                            }),
                  ),
                ]),
        ),

        // ── Manual caption input ────────────────────────────────
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: Theme.of(context).scaffoldBackgroundColor,
              border: Border(
                  top: BorderSide(
                      color: Theme.of(context)
                          .dividerColor
                          .withValues(alpha: 0.3)))),
          child: Row(children: [
            Expanded(
                child: TextField(
                    controller: _captionController,
                    decoration: InputDecoration(
                        hintText: s.addCaptionManually,
                        hintStyle: TextStyle(color: Colors.grey[400]),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(
                                AppTheme.radiusFull),
                            borderSide: BorderSide.none),
                        filled: true,
                        fillColor: Theme.of(context).cardColor,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12)),
                    onSubmitted: _addManualCaption)),
            const SizedBox(width: 8),
            Container(
                decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    shape: BoxShape.circle),
                child: Semantics(
                  label: s.addCaptionLabel,
                  button: true,
                  child: IconButton(
                    tooltip: s.addCaptionLabel,
                    icon: const Icon(Icons.add, color: Colors.white),
                    onPressed: () =>
                        _addManualCaption(_captionController.text),
                  ),
                )),
          ]),
        ),

        // ── Stop button ─────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: PrimaryActionButton(
            label: _isStopping ? s.stoppingLabel : s.stopSession,
            icon: Icons.stop,
            onPressed: _isStopping ? null : _onStopPressed,
          ),
        ),
      ]),
    );
  }

  // ── Status banner ──────────────────────────────────────────────

  Widget _buildStatusBanner(AppStrings s) {
    final cs = Theme.of(context).colorScheme;
    Color bgColor;
    Color fgColor;
    IconData icon;
    String text;

    if (_isListening) {
      bgColor = AppTheme.successLight.withValues(alpha: 0.08);
      fgColor = AppTheme.successLight;
      icon = Icons.fiber_manual_record;
      text = s.listeningIn(_sessionLanguage);
    } else if (_sttInitialised) {
      // STT was started but is currently not listening (recovery in progress).
      bgColor = AppTheme.warningLight.withValues(alpha: 0.1);
      fgColor = AppTheme.warningLight;
      icon = Icons.hourglass_empty;
      text = 'Recovering… ($_restartCount restarts)';
    } else {
      bgColor = cs.surfaceContainerHighest.withValues(alpha: 0.3);
      fgColor = cs.onSurfaceVariant;
      icon = Icons.mic_none;
      text = s.startingSpeechEngine;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      color: bgColor,
      child: Row(children: [
        Icon(icon, size: 10, color: fgColor),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: fgColor)),
        ),
      ]),
    );
  }

  // ── Error state ────────────────────────────────────────────────

  Widget _buildErrorState(AppStrings s) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
          const SizedBox(height: 16),
          Text('Speech Recognition Unavailable',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(_sttError!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 13),
              textAlign: TextAlign.center),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () async {
              setState(() => _sttError = null);
              final speech = context.read<SpeechProvider>();
              await speech.initialize(preferredLanguage: _sessionLanguage);
              if (mounted) {
                if (speech.isLiveStt) {
                  await _startListening(speech);
                  _speechSubscription?.cancel();
                  _speechSubscription = speech.onResult.listen(_onSpeechResult);
                } else {
                  setState(() => _sttError =
                      s.sttUnavailableForLang(_sessionLanguage));
                }
              }
            },
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ]),
      ),
    );
  }

  // ── Stop session ──────────────────────────────────────────────

  Future<void> _onStopPressed() async {
    if (_isStopping) return;
    setState(() => _isStopping = true);

    try {
      // 1. Stop the STT engine.
      await context.read<SpeechProvider>().stopListening();

      // 2. Finalise any remaining partial captions.
      _finalizeOrphanedPartial();

      // 3. Complete the session and persist final state.
      await context.read<ProfessionalProvider>().stopSession(widget.sessionId);
    } catch (e) {
      debugPrint('[SessionLive] stop error: $e');
    } finally {
      _isStopping = false;
      if (mounted) {
        setState(() {});
        Navigator.pop(context);
      }
    }
  }

  // ── Manual caption ────────────────────────────────────────────

  void _addManualCaption(String text) {
    if (text.trim().isEmpty) return;
    context.read<ProfessionalProvider>().addCaptionToSession(
      widget.sessionId,
      Caption(
          text: text.trim(),
          speaker: 'Speaker 1',
          language: _sessionLanguage),
    );
    _captionController.clear();
    _scrollToBottom();
  }
}
