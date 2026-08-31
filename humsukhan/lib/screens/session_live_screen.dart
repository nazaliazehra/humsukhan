import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/providers.dart';
import '../theme/app_theme.dart';
import '../models/models.dart';
import '../widgets/reusable_widgets.dart';
import '../l10n/app_strings.dart';

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
  late DateTime _startTime;

  // STT lifecycle tracking — drives the UI status banner.
  bool _sttReady = false;
  bool _isListening = false;
  String? _sttError;
  String _partialCaptionId = '';
  String _sessionLanguage = 'English';
  bool _isStopping = false;

  @override
  void initState() {
    super.initState();
    _startTime = DateTime.now();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _initSession());
  }

  void _initSession() async {
    final s = AppStrings.of(context);
    final pro = context.read<ProfessionalProvider>();
    pro.startSessionRecording(widget.sessionId);

    // Resolve the session's caption language for the STT engine.
    final session = pro.sessions.firstWhere(
      (s) => s.id == widget.sessionId,
      orElse: () => ProfessionalSession(title: 'Session', status: SessionStatus.inProgress),
    );
    _sessionLanguage = session.captionLanguage;

    // Initialize the speech engine with the session's language.
    final speech = context.read<SpeechProvider>();
    await speech.initialize(preferredLanguage: _sessionLanguage);

    if (speech.isLiveStt) {
      try {
        await speech.startListening(language: _sessionLanguage);
        if (!mounted) return;
        setState(() {
          _sttReady = true;
          _isListening = true;
          _sttError = null;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() => _sttError = e.toString());
        debugPrint('[SessionLive] STT start failed: $e');
      }
    } else {
      if (mounted) {
        setState(() => _sttError = s.sttUnavailableForLang(_sessionLanguage));
      }
      debugPrint('[SessionLive] STT not available — mode: ${speech.currentMode}');
    }

    // Subscribe to results (partials + finals) after starting.
    _speechSubscription = speech.onResult.listen((result) {
      if (!mounted) return;
      if (result.isFinal && result.text.trim().isNotEmpty) {
        _removePartialCaption();
        context.read<ProfessionalProvider>().addCaptionToSession(
          widget.sessionId,
          Caption(text: result.text, speaker: 'Speaker 1', language: _sessionLanguage),
        );
        _scrollToBottom();
      } else if (!result.isFinal && result.text.trim().isNotEmpty) {
        final caption = Caption(
          id: _partialCaptionId,
          text: result.text,
          speaker: 'Speaker 1',
          language: _sessionLanguage,
          isPartial: true,
        );
        context.read<ProfessionalProvider>().setPartialCaption(
          widget.sessionId, caption, _partialCaptionId,
        );
        _scrollToBottom();
      }
    });
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(_scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  /// Remove the current partial caption before a final result is committed.
  void _removePartialCaption() {
    context.read<ProfessionalProvider>().removePartialCaption(
      widget.sessionId, _partialCaptionId,
    );
  }

  String get _duration {
    final diff = DateTime.now().difference(_startTime);
    return '${diff.inMinutes}:${(diff.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _speechSubscription?.cancel();
    _durationTimer?.cancel();
    _captionController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pro = context.watch<ProfessionalProvider>();
    final session = pro.sessions.firstWhere(
      (s) => s.id == widget.sessionId,
      orElse: () => ProfessionalSession(title: 'Session', status: SessionStatus.inProgress),
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
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: AppTheme.successLight.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(AppTheme.radiusFull),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.circle, size: 8, color: AppTheme.successLight),
                  const SizedBox(width: 6),
                  Text(_duration, style: TextStyle(color: AppTheme.successLight, fontWeight: FontWeight.w700, fontSize: 14)),
                ]),
              ),
            ),
          ),
        ],
      ),
      body: Column(children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: AppTheme.successLight.withValues(alpha: 0.1),
          child: Row(children: [
            Icon(Icons.mic, color: AppTheme.successLight, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text('${s.liveSession} · ${session.captionLanguage} · ${session.type.name}',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppTheme.successLight),
                maxLines: 1, overflow: TextOverflow.ellipsis)),
          ]),
        ),
        Expanded(
          child: _isListening || _sttError != null
              ? Column(children: [
                  // Real STT status banner — no fake spinner.
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                    color: _sttError != null
                        ? Colors.redAccent.withValues(alpha: 0.1)
                        : AppTheme.successLight.withValues(alpha: 0.08),
                    child: Row(children: [
                      if (_sttError == null) ...[
                        Icon(Icons.fiber_manual_record, size: 10,
                            color: AppTheme.successLight),
                        const SizedBox(width: 8),
                        Text(s.listeningIn(_sessionLanguage),
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                                color: AppTheme.successLight)),
                      ] else ...[
                        const Icon(Icons.error_outline, size: 16, color: Colors.redAccent),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(_sttError!, style: const TextStyle(
                              fontSize: 13, color: Colors.redAccent),
                              maxLines: 2, overflow: TextOverflow.ellipsis),
                        ),
                      ],
                    ]),
                  ),
                  // Caption list
                  Expanded(
                    child: session.captions.isEmpty
                        ? Center(child: Text(s.waitingForSpeech,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.grey[400], fontSize: 16)))
                        : ListView.builder(
                            controller: _scrollController, padding: const EdgeInsets.all(16),
                            itemCount: session.captions.length,
                            itemBuilder: (context, index) {
                              final c = session.captions[index];
                              return Padding(padding: const EdgeInsets.only(bottom: 12),
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text('${c.speaker} · ${c.timestamp.hour.toString().padLeft(2, '0')}:${c.timestamp.minute.toString().padLeft(2, '0')}',
                                      style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
                                  const SizedBox(height: 4),
                                  Text(c.text, style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                      fontStyle: c.isPartial ? FontStyle.italic : null,
                                      color: c.isPartial ? Colors.grey[600] : null)),
                                ]));
                            }),
                  ),
                ])
              : Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const SizedBox(width: 40, height: 40, child: CircularProgressIndicator(strokeWidth: 3)),
                  const SizedBox(height: 16),
                  Text(s.startingSpeechEngine, textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey[400], fontSize: 16)),
                ])),
        ),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Theme.of(context).scaffoldBackgroundColor,
              border: Border(top: BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: 0.3)))),
          child: Row(children: [
            Expanded(child: TextField(controller: _captionController,
                decoration: InputDecoration(hintText: s.addCaptionManually, hintStyle: TextStyle(color: Colors.grey[400]),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppTheme.radiusFull), borderSide: BorderSide.none),
                    filled: true, fillColor: Theme.of(context).cardColor,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12)),
                onSubmitted: _addManualCaption)),
            const SizedBox(width: 8),
            Container(decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, shape: BoxShape.circle),
                child: Semantics(
                  label: s.addCaptionLabel,
                  button: true,
                  child: IconButton(
                    tooltip: s.addCaptionLabel,
                    icon: const Icon(Icons.add, color: Colors.white),
                    onPressed: () => _addManualCaption(_captionController.text),
                  ),
                )),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: PrimaryActionButton(
            label: _isStopping ? s.stoppingLabel : s.stopSession,
            icon: Icons.stop,
            onPressed: _isStopping ? null : () async {
              setState(() => _isStopping = true);
              try {
                // 1. Stop the microphone and STT engine.
                await context.read<SpeechProvider>().stopListening();
                // 2. Flush any remaining partial caption as a final caption.
                final pro = context.read<ProfessionalProvider>();
                final session = pro.sessions.firstWhere(
                  (sess) => sess.id == widget.sessionId,
                  orElse: () => ProfessionalSession(title: 'Session', status: SessionStatus.inProgress),
                );
                final partial = session.captions.where((c) => c.isPartial && c.text.trim().isNotEmpty).toList();
                for (final p in partial) {
                  pro.addCaptionToSession(widget.sessionId,
                      Caption(text: p.text, speaker: p.speaker, language: _sessionLanguage));
                }
                _removePartialCaption();
                // 3. Complete the session and persist.
                await pro.stopSession(widget.sessionId);
              } catch (e) {
                debugPrint('[SessionLive] stop error: $e');
              } finally {
                _isStopping = false;
                if (mounted) {
                  setState(() {});
                  Navigator.pop(context);
                }
              }
            },
          ),
        ),
      ]),
    );
  }

  void _addManualCaption(String text) {
    if (text.trim().isEmpty) return;
    context.read<ProfessionalProvider>().addCaptionToSession(widget.sessionId,
        Caption(text: text.trim(), speaker: 'Speaker 1', language: _sessionLanguage));
    _captionController.clear();
    _scrollToBottom();
  }
}
