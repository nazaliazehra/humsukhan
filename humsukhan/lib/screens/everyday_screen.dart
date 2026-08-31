import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/providers.dart';
import '../theme/app_theme.dart';
import '../models/models.dart';
import '../widgets/reusable_widgets.dart';
import '../l10n/app_strings.dart';

class EverydayScreen extends StatefulWidget {
  const EverydayScreen({super.key});

  @override
  State<EverydayScreen> createState() => _EverydayScreenState();
}

class _EverydayScreenState extends State<EverydayScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  StreamSubscription? _speechSubscription;
  bool _ttsPreventsStt = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initSpeech();
    });
  }

  void _initSpeech() {
    final speech = context.read<SpeechProvider>();
    speech.initialize();
    _speechSubscription = speech.onResult.listen((result) {
      if (!mounted) return;
      // Ignore STT results while TTS is speaking (feedback prevention).
      if (_ttsPreventsStt) return;
      final conv = context.read<ConversationProvider>();
      if (conv.isMicHeld) {
        // Push-to-talk: update the single active partial.
        conv.updatePartialCaption(result.text, language: result.language);
      }
      _scrollToBottom();
    });
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _speechSubscription?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // ── Push-to-talk handlers ────────────────────────────────────────

  Future<void> _onMicPressed() async {
    final conv = context.read<ConversationProvider>();
    final speech = context.read<SpeechProvider>();
    if (conv.state != ConversationState.active) return;
    conv.startSpeakerTurn();
    await speech.startListening(language: conv.currentLanguage);
  }

  Future<void> _onMicReleased() async {
    final conv = context.read<ConversationProvider>();
    final speech = context.read<SpeechProvider>();
    await speech.stopListening();
    conv.endSpeakerTurn();
    _scrollToBottom();
  }

  // ── TTS with feedback prevention ─────────────────────────────────

  Future<void> _speakMessage(ConversationMessage message) async {
    final speech = context.read<SpeechProvider>();
    final conv = context.read<ConversationProvider>();

    // If this exact message is already speaking, stop it.
    if (speech.isSpeaking && speech.speakingMessageId == message.id) {
      await speech.stopSpeaking();
      return;
    }

    // If a different message is speaking, stop that first.
    if (speech.isSpeaking) {
      await speech.stopSpeaking();
    }

    // Pause STT while TTS is active so HumSukhan never transcribes its
    // own output.
    final wasListening = conv.isMicHeld;
    if (wasListening) {
      _ttsPreventsStt = true;
      await speech.stopListening();
    }

    // Speak the message with its ID for tracking.
    await speech.speak(
      message.text,
      language: message.language,
      messageId: message.id,
    );

    // Resume STT only if the speaker is still holding the mic.
    _ttsPreventsStt = false;
    if (wasListening && conv.isMicHeld) {
      await speech.startListening(language: conv.currentLanguage);
    }
  }

  // ── User text input ──────────────────────────────────────────────

  void _sendTypedText(String text) {
    if (text.trim().isEmpty) return;
    final conv = context.read<ConversationProvider>();
    conv.addUserMessage(text.trim());
    _textController.clear();
    _scrollToBottom();
  }

  // ── Build ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final conv = context.watch<ConversationProvider>();
    final settings = context.watch<SettingsProvider>();
    final quickReplies = context.watch<QuickReplyProvider>();
    final speech = context.watch<SpeechProvider>();
    final s = AppStrings.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(s.everydayTitle),
        leading: IconButton(
          tooltip: s.backLabel,
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          if (conv.state == ConversationState.active)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: StatusIndicator(
                label: '${s.durationLabel}: ${conv.formattedDuration}',
                color: Theme.of(context).colorScheme.primary,
                isActive: true,
                icon: Icons.timer,
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          // ── Listening status banner ──────────────────────────────
          if (conv.state == ConversationState.active)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: conv.isMicHeld
                  ? AppTheme.successLight.withValues(alpha: 0.1)
                  : Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
              child: Row(
                children: [
                  Icon(
                    conv.isMicHeld ? Icons.mic : Icons.mic_none,
                    color: conv.isMicHeld
                        ? AppTheme.successLight
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      conv.isMicHeld ? 'Listening — speak now' : conv.listeningStatus,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: conv.isMicHeld
                            ? AppTheme.successLight
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // STT mode indicator
                  Consumer<SpeechProvider>(
                    builder: (_, sp, _) => Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: sp.isOfflineMode
                            ? AppTheme.successLight.withValues(alpha: 0.2)
                            : sp.isOnlineMode
                                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.2)
                                : AppTheme.warningLight.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(AppTheme.radiusFull),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            sp.isOfflineMode ? Icons.wifi_off : Icons.wifi,
                            size: 12,
                            color: sp.isOfflineMode
                                ? AppTheme.successLight
                                : sp.isOnlineMode
                                    ? Theme.of(context).colorScheme.primary
                                    : AppTheme.warningLight,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              sp.sttModeLabel,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: sp.isOfflineMode
                                    ? AppTheme.successLight
                                    : sp.isOnlineMode
                                        ? Theme.of(context).colorScheme.primary
                                        : AppTheme.warningLight,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // ── Privacy banner (idle) ────────────────────────────────
          if (conv.state == ConversationState.idle)
            PrivacyNotice(text: s.privacyNote),

          // ── Main content area ────────────────────────────────────
          Expanded(
            child: conv.state == ConversationState.idle
                ? _buildIdleState(context, s)
                : conv.state == ConversationState.saveDecision
                    ? _buildSaveDecision(context, s)
                    : _buildConversationArea(context, conv, settings, s, speech),
          ),

          // ── Quick replies ────────────────────────────────────────
          if (conv.state == ConversationState.active)
            Container(
              constraints: const BoxConstraints(minHeight: 44, maxHeight: 56),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  ...quickReplies.replies.take(6).map((reply) => Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: QuickReplyChip(
                          reply: reply,
                          isHighContrast: settings.isHighContrast,
                          onTap: () {
                            conv.addUserMessage(reply.text);
                            _scrollToBottom();
                          },
                        ),
                      )),
                ],
              ),
            ),

          // ── Text input area ──────────────────────────────────────
          if (conv.state == ConversationState.active)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).scaffoldBackgroundColor,
                border: Border(
                  top: BorderSide(
                      color: Theme.of(context).dividerColor.withValues(alpha: 0.3)),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      decoration: InputDecoration(
                        hintText: s.typeResponse,
                        hintStyle: TextStyle(color: Colors.grey[400]),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppTheme.radiusFull),
                          borderSide: BorderSide.none,
                        ),
                        filled: true,
                        fillColor: Theme.of(context).cardColor,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12),
                      ),
                      onSubmitted: _sendTypedText,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Send button
                  Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                    child: Semantics(
                      label: s.sendMessage,
                      button: true,
                      child: IconButton(
                        tooltip: s.sendLabel,
                        icon: const Icon(Icons.send, color: Colors.white),
                        onPressed: () => _sendTypedText(_textController.text),
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // ── Mic button (push-to-talk) ────────────────────────────
          if (conv.state == ConversationState.active)
            _buildMicButton(context, conv, speech, s),

          // ── Stop button ──────────────────────────────────────────
          if (conv.state == ConversationState.active)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: PrimaryActionButton(
                label: s.stopConversation,
                icon: Icons.stop,
                onPressed: () {
                  context.read<SpeechProvider>().stopListening();
                  conv.stopConversation();
                },
              ),
            ),
        ],
      ),
    );
  }

  // ── Mic button widget ────────────────────────────────────────────

  Widget _buildMicButton(
      BuildContext context, ConversationProvider conv, SpeechProvider speech, AppStrings s) {
    final cs = Theme.of(context).colorScheme;
    final isActive = conv.isMicHeld;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: GestureDetector(
        onLongPressStart: (_) => _onMicPressed(),
        onLongPressEnd: (_) => _onMicReleased(),
        onLongPressCancel: () => _onMicReleased(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: double.infinity,
          height: 64,
          decoration: BoxDecoration(
            color: isActive
                ? AppTheme.successLight
                : cs.primary,
            borderRadius: BorderRadius.circular(AppTokens.radiusMd),
            boxShadow: [
              if (isActive)
                BoxShadow(
                  color: AppTheme.successLight.withValues(alpha: 0.4),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                isActive ? Icons.mic : Icons.mic_none,
                color: Colors.white,
                size: 28,
              ),
              const SizedBox(width: 12),
              Text(
                isActive ? 'Listening — release to send' : s.holdToSpeak,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Idle state ───────────────────────────────────────────────────

  Widget _buildIdleState(BuildContext context, AppStrings s) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline,
                size: 80, color: Colors.grey[300]),
            const SizedBox(height: 24),
            Text(
              s.startConversation,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 12),
            Text(
              s.listeningDots,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Theme.of(context).textTheme.bodySmall?.color,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            PrimaryActionButton(
              label: s.startListening,
              icon: Icons.mic,
              onPressed: () {
                context.read<ConversationProvider>().startConversation();
              },
            ),
          ],
        ),
      ),
    );
  }

  // ── Conversation area (WhatsApp-like) ────────────────────────────

  Widget _buildConversationArea(
    BuildContext context,
    ConversationProvider conv,
    SettingsProvider settings,
    AppStrings s,
    SpeechProvider speech,
  ) {
    return Column(
      children: [
        // Language indicator
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              LanguageBadge(language: conv.currentLanguage),
              const SizedBox(width: 8),
              Consumer<ConnectivityProvider>(
                builder: (_, conn, _) =>
                    OfflineBadge(isOnline: conn.isOnline),
              ),
            ],
          ),
        ),

        // Messages list
        Expanded(
          child: conv.messages.isEmpty && conv.activePartial == null
              ? Center(
                  child: Text(
                    conv.isMicHeld
                        ? 'Listening — speak now'
                        : s.holdToSpeak,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: Colors.grey[400],
                        ),
                  ),
                )
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount:
                      conv.messages.length + (conv.activePartial != null ? 1 : 0),
                  itemBuilder: (context, index) {
                    // Active partial is always the last item.
                    if (index == conv.messages.length &&
                        conv.activePartial != null) {
                      return _MessageBubble(
                        message: conv.activePartial!,
                        textSize: settings.captionTextSize,
                        isHighContrast: settings.isHighContrast,
                        onSpeak: () => _speakMessage(conv.activePartial!),
                        isSpeaking: speech.speakingMessageId == conv.activePartial!.id,
                      );
                    }
                    final msg = conv.messages[index];
                    return _MessageBubble(
                      message: msg,
                      textSize: settings.captionTextSize,
                      isHighContrast: settings.isHighContrast,
                      onSpeak: () => _speakMessage(msg),
                      isSpeaking: speech.speakingMessageId == msg.id,
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ── Save decision ────────────────────────────────────────────────

  Widget _buildSaveDecision(BuildContext context, AppStrings s) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.save_alt,
                size: 64, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 24),
            Text(
              s.saveConversation,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 12),
            Text(
              s.saveConversationDesc,
              style: Theme.of(context).textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            PrimaryActionButton(
              label: s.save,
              icon: Icons.save,
              onPressed: () =>
                  context.read<ConversationProvider>().saveConversation(),
            ),
            const SizedBox(height: 12),
            SecondaryActionButton(
              label: s.delete,
              icon: Icons.delete_outline,
              onPressed: () => _showDeleteConfirmation(context, s),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () =>
                  context.read<ConversationProvider>().cancelStop(),
              child: Text(s.continueListening),
            ),
          ],
        ),
      ),
    );
  }

  void _showDeleteConfirmation(BuildContext context, AppStrings s) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.deleteConversation),
        content: Text(s.deleteConversationDesc),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(s.cancel),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              context.read<ConversationProvider>().deleteConversation();
            },
            child: Text(s.delete, style: const TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
// Message Bubble (WhatsApp-style)
// ═══════════════════════════════════════════════════════════════════

class _MessageBubble extends StatelessWidget {
  final ConversationMessage message;
  final double textSize;
  final bool isHighContrast;
  final VoidCallback onSpeak;
  final bool isSpeaking;

  const _MessageBubble({
    required this.message,
    required this.textSize,
    required this.isHighContrast,
    required this.onSpeak,
    this.isSpeaking = false,
  });

  bool get _isUser => message.owner == 'user';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final s = AppStrings.of(context);

    final bubbleColor = _isUser
        ? (isDark ? AppTokens.deepSage : AppTokens.deepSage)
        : (isDark ? cs.surfaceContainerHighest : AppTokens.pureWhite);

    final textColor = _isUser
        ? AppTokens.warmIvory
        : (isHighContrast ? AppTokens.pureWhite : cs.onSurface);

    final labelColor = _isUser
        ? AppTokens.warmIvory.withValues(alpha: 0.8)
        : cs.primary;

    final speakerLabel = _isUser ? s.youLabel : s.speakerLabel2;

    return Align(
      alignment: _isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.symmetric(
          vertical: 4,
          horizontal: 12,
        ),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        child: Column(
          crossAxisAlignment:
              _isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            // Speaker label
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Text(
                speakerLabel,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: labelColor,
                ),
              ),
            ),
            // Bubble
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: bubbleColor,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(_isUser ? 16 : 4),
                  bottomRight: Radius.circular(_isUser ? 4 : 16),
                ),
                border: isHighContrast
                    ? Border.all(color: AppTokens.pureWhite, width: 1)
                    : null,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Message text
                  Text(
                    message.text.isEmpty ? '...' : message.text,
                    style: TextStyle(
                      fontSize: textSize,
                      color: textColor,
                      fontWeight: message.isPartial
                          ? FontWeight.normal
                          : FontWeight.w500,
                      fontStyle: message.isPartial
                          ? FontStyle.italic
                          : FontStyle.normal,
                    ),
                  ),
                  const SizedBox(height: 6),
                  // Bottom row: language + speak button
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (message.language.isNotEmpty &&
                          message.language != 'English')
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: LanguageBadge(language: message.language),
                        ),
                      // Speak button
                      Semantics(
                        label: isSpeaking ? s.stopSpeaking : s.readAloud,
                        button: true,
                        child: InkWell(
                          onTap: onSpeak,
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Icon(
                              isSpeaking ? Icons.stop_circle : Icons.volume_up,
                              size: 18,
                              color: isSpeaking
                                  ? AppTokens.error
                                  : labelColor.withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
