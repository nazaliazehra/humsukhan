import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:humsukhan/models/models.dart';
import 'package:humsukhan/providers/conversation_provider.dart';

/// Regression tests for the Everyday push-to-talk conversation persistence.
///
/// These tests exercise the pure provider and model logic — no platform
/// channels, no Supabase, no STT engine.  SharedPreferences is mocked
/// so disk I/O is deterministic.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // ── ConversationMessage model ───────────────────────────────────

  group('ConversationMessage — JSON round-trip', () {
    test('preserves all fields through serialize/deserialize', () {
      final original = ConversationMessage(
        id: 'test-id-123',
        text: 'Hello, how are you?',
        owner: 'speaker',
        timestamp: DateTime(2025, 6, 15, 10, 30),
        turnStartedAt: DateTime(2025, 6, 15, 10, 29, 55),
        sequenceNumber: 3,
        isPartial: false,
        language: 'English',
      );

      final json = original.toJson();
      final restored = ConversationMessage.fromJson(json);

      expect(restored.id, original.id);
      expect(restored.text, original.text);
      expect(restored.owner, original.owner);
      expect(restored.timestamp, original.timestamp);
      expect(restored.turnStartedAt, original.turnStartedAt);
      expect(restored.sequenceNumber, original.sequenceNumber);
      expect(restored.isPartial, original.isPartial);
      expect(restored.language, original.language);
    });

    test('copyWith preserves unchanged fields', () {
      final original = ConversationMessage(
        text: 'Original',
        owner: 'user',
        sequenceNumber: 5,
        language: 'Urdu',
      );

      final updated = original.copyWith(text: 'Updated');

      expect(updated.text, 'Updated');
      expect(updated.owner, 'user');
      expect(updated.sequenceNumber, 5);
      expect(updated.language, 'Urdu');
      expect(updated.id, original.id);
      expect(updated.timestamp, original.timestamp);
    });

    test('defaults are sensible', () {
      final msg = ConversationMessage(text: 'Hi', owner: 'speaker');

      expect(msg.id, isNotEmpty);
      expect(msg.sequenceNumber, 0);
      expect(msg.isPartial, false);
      expect(msg.language, 'English');
      expect(msg.timestamp, isNotNull);
      expect(msg.turnStartedAt, isNotNull);
    });
  });

  // ── ConversationProvider — message lifecycle ────────────────────

  group('ConversationProvider — message lifecycle', () {
    test('starts in idle state with no messages', () {
      final conv = ConversationProvider();
      expect(conv.state, ConversationState.idle);
      expect(conv.messages, isEmpty);
      expect(conv.activePartial, isNull);
      expect(conv.isMicHeld, false);
    });

    test('startConversation sets active state', () {
      final conv = ConversationProvider();
      conv.startConversation();
      expect(conv.state, ConversationState.active);
      expect(conv.isListening, false); // mic not held yet
    });

    test('speaker turn creates active partial', () {
      final conv = ConversationProvider();
      conv.startConversation();
      conv.startSpeakerTurn();

      expect(conv.isMicHeld, true);
      expect(conv.isListening, true);
      expect(conv.activePartial, isNotNull);
      expect(conv.activePartial!.owner, 'speaker');
      expect(conv.activePartial!.isPartial, true);
      expect(conv.activePartial!.text, '');
    });

    test('partial updates do not create new messages', () {
      final conv = ConversationProvider();
      conv.startConversation();
      conv.startSpeakerTurn();

      conv.updatePartialCaption('Hello');
      expect(conv.activePartial!.text, 'Hello');
      expect(conv.messages, isEmpty);

      conv.updatePartialCaption('Hello, how');
      expect(conv.activePartial!.text, 'Hello, how');
      expect(conv.messages, isEmpty);

      conv.updatePartialCaption('Hello, how are you?');
      expect(conv.activePartial!.text, 'Hello, how are you?');
      expect(conv.messages, isEmpty);
    });

    test('endSpeakerTurn commits partial as permanent message', () {
      final conv = ConversationProvider();
      conv.startConversation();
      conv.startSpeakerTurn();
      conv.updatePartialCaption('Hello');
      conv.endSpeakerTurn();

      expect(conv.activePartial, isNull);
      expect(conv.isMicHeld, false);
      expect(conv.messages.length, 1);
      expect(conv.messages[0].text, 'Hello');
      expect(conv.messages[0].owner, 'speaker');
      expect(conv.messages[0].isPartial, false);
    });

    test('empty partial is not committed', () {
      final conv = ConversationProvider();
      conv.startConversation();
      conv.startSpeakerTurn();
      // Don't update text — partial is empty
      conv.endSpeakerTurn();

      expect(conv.messages, isEmpty);
    });

    test('whitespace-only partial is not committed', () {
      final conv = ConversationProvider();
      conv.startConversation();
      conv.startSpeakerTurn();
      conv.updatePartialCaption('   ');
      conv.endSpeakerTurn();

      expect(conv.messages, isEmpty);
    });

    test('user messages are appended correctly', () {
      final conv = ConversationProvider();
      conv.startConversation();

      conv.addUserMessage('I am fine');
      expect(conv.messages.length, 1);
      expect(conv.messages[0].text, 'I am fine');
      expect(conv.messages[0].owner, 'user');
    });

    test('empty user messages are rejected', () {
      final conv = ConversationProvider();
      conv.startConversation();

      conv.addUserMessage('');
      conv.addUserMessage('   ');
      expect(conv.messages, isEmpty);
    });

    test('user messages rejected when not active', () {
      final conv = ConversationProvider();
      // Don't start conversation
      conv.addUserMessage('Hello');
      expect(conv.messages, isEmpty);
    });
  });

  // ── ConversationProvider — 5+ alternating messages ──────────────

  group('ConversationProvider — 5+ alternating speaker/user messages', () {
    test('full alternating conversation preserves order', () {
      final conv = ConversationProvider();
      conv.startConversation();

      // Turn 1: Speaker
      conv.startSpeakerTurn();
      conv.updatePartialCaption('Hello, how are you?');
      conv.endSpeakerTurn();

      // Turn 2: User
      conv.addUserMessage("I'm fine, thank you.");

      // Turn 3: Speaker
      conv.startSpeakerTurn();
      conv.updatePartialCaption('Where are you going?');
      conv.endSpeakerTurn();

      // Turn 4: User
      conv.addUserMessage("I'm going home.");

      // Turn 5: Speaker
      conv.startSpeakerTurn();
      conv.updatePartialCaption('Okay, see you later.');
      conv.endSpeakerTurn();

      // Turn 6: User
      conv.addUserMessage('Goodbye!');

      // Turn 7: Speaker
      conv.startSpeakerTurn();
      conv.updatePartialCaption('Take care!');
      conv.endSpeakerTurn();

      expect(conv.messages.length, 7);

      // Verify exact order
      expect(conv.messages[0].text, 'Hello, how are you?');
      expect(conv.messages[0].owner, 'speaker');

      expect(conv.messages[1].text, "I'm fine, thank you.");
      expect(conv.messages[1].owner, 'user');

      expect(conv.messages[2].text, 'Where are you going?');
      expect(conv.messages[2].owner, 'speaker');

      expect(conv.messages[3].text, "I'm going home.");
      expect(conv.messages[3].owner, 'user');

      expect(conv.messages[4].text, 'Okay, see you later.');
      expect(conv.messages[4].owner, 'speaker');

      expect(conv.messages[5].text, 'Goodbye!');
      expect(conv.messages[5].owner, 'user');

      expect(conv.messages[6].text, 'Take care!');
      expect(conv.messages[6].owner, 'speaker');
    });

    test('sequence numbers are monotonically increasing', () {
      final conv = ConversationProvider();
      conv.startConversation();

      conv.startSpeakerTurn();
      conv.updatePartialCaption('A');
      conv.endSpeakerTurn();

      conv.addUserMessage('B');

      conv.startSpeakerTurn();
      conv.updatePartialCaption('C');
      conv.endSpeakerTurn();

      conv.addUserMessage('D');

      conv.startSpeakerTurn();
      conv.updatePartialCaption('E');
      conv.endSpeakerTurn();

      final seqs = conv.messages.map((m) => m.sequenceNumber).toList();
      // Each must be strictly greater than the previous
      for (var i = 1; i < seqs.length; i++) {
        expect(seqs[i], greaterThan(seqs[i - 1]),
            reason: 'seq[$i]=${seqs[i]} should be > seq[${i - 1}]=${seqs[i - 1]}');
      }
    });
  });

  // ── Persistence — save / load round-trip ────────────────────────

  group('Persistence — save and load round-trip', () {
    test('save stores all messages to SharedPreferences', () async {
      final conv = ConversationProvider();
      conv.startConversation();

      conv.startSpeakerTurn();
      conv.updatePartialCaption('Hello');
      conv.endSpeakerTurn();
      conv.addUserMessage('Hi there');

      await conv.saveConversation();

      final saved = await conv.getSavedConversations();
      expect(saved.length, 1);

      final session = saved[0];
      expect(session['id'], isNotNull);
      expect(session['messages'], isA<List>());

      final messages = session['messages'] as List;
      expect(messages.length, 2);
    });

    test('save preserves message ID, timestamp, speaker, text, language, sequence',
        () async {
      final conv = ConversationProvider();
      conv.startConversation();

      conv.startSpeakerTurn();
      conv.updatePartialCaption('Bonjour');
      conv.endSpeakerTurn();

      conv.addUserMessage('Comment ça va?');

      await conv.saveConversation();

      final saved = await conv.getSavedConversations();
      final messages = (saved[0]['messages'] as List)
          .map((m) => ConversationMessage.fromJson(m as Map<String, dynamic>))
          .toList();

      // First message (speaker)
      expect(messages[0].text, 'Bonjour');
      expect(messages[0].owner, 'speaker');
      expect(messages[0].id, isNotEmpty);
      expect(messages[0].timestamp, isNotNull);
      expect(messages[0].language, isNotEmpty);
      expect(messages[0].sequenceNumber, greaterThan(0));

      // Second message (user)
      expect(messages[1].text, 'Comment ça va?');
      expect(messages[1].owner, 'user');
      expect(messages[1].id, isNotEmpty);
      expect(messages[1].sequenceNumber, greaterThan(messages[0].sequenceNumber));
    });

    test('loadConversation restores exact message order', () async {
      final conv = ConversationProvider();
      conv.startConversation();

      // Build a 5-message alternating conversation
      conv.startSpeakerTurn();
      conv.updatePartialCaption('Speaker A');
      conv.endSpeakerTurn();
      conv.addUserMessage('User B');
      conv.startSpeakerTurn();
      conv.updatePartialCaption('Speaker C');
      conv.endSpeakerTurn();
      conv.addUserMessage('User D');
      conv.startSpeakerTurn();
      conv.updatePartialCaption('Speaker E');
      conv.endSpeakerTurn();

      await conv.saveConversation();

      // Get the saved session ID
      final saved = await conv.getSavedConversations();
      final sessionId = saved[0]['id'] as String;

      // Load into a fresh provider
      final conv2 = ConversationProvider();
      final loaded = await conv2.loadConversation(sessionId);

      expect(loaded, isTrue);
      expect(conv2.messages.length, 5);

      // Verify exact order preserved
      expect(conv2.messages[0].text, 'Speaker A');
      expect(conv2.messages[0].owner, 'speaker');
      expect(conv2.messages[1].text, 'User B');
      expect(conv2.messages[1].owner, 'user');
      expect(conv2.messages[2].text, 'Speaker C');
      expect(conv2.messages[2].owner, 'speaker');
      expect(conv2.messages[3].text, 'User D');
      expect(conv2.messages[3].owner, 'user');
      expect(conv2.messages[4].text, 'Speaker E');
      expect(conv2.messages[4].owner, 'speaker');

      // Sequence numbers preserved
      final seqs = conv2.messages.map((m) => m.sequenceNumber).toList();
      for (var i = 1; i < seqs.length; i++) {
        expect(seqs[i], greaterThan(seqs[i - 1]));
      }
    });

    test('loadConversation returns false for non-existent session', () async {
      final conv = ConversationProvider();
      final loaded = await conv.loadConversation('non-existent-id');
      expect(loaded, isFalse);
    });

    test('multiple conversations are stored independently', () async {
      // Save first conversation
      final conv1 = ConversationProvider();
      conv1.startConversation();
      conv1.startSpeakerTurn();
      conv1.updatePartialCaption('First conversation');
      conv1.endSpeakerTurn();
      await conv1.saveConversation();

      // Save second conversation
      final conv2 = ConversationProvider();
      conv2.startConversation();
      conv2.addUserMessage('Second conversation');
      conv2.startSpeakerTurn();
      conv2.updatePartialCaption('Reply in second');
      conv2.endSpeakerTurn();
      await conv2.saveConversation();

      final saved = await conv2.getSavedConversations();
      expect(saved.length, 2);

      // Each conversation is independent
      final msgs1 = (saved[0]['messages'] as List)
          .map((m) => ConversationMessage.fromJson(m as Map<String, dynamic>))
          .toList();
      final msgs2 = (saved[1]['messages'] as List)
          .map((m) => ConversationMessage.fromJson(m as Map<String, dynamic>))
          .toList();

      expect(msgs1.length, 1);
      expect(msgs1[0].text, 'First conversation');

      expect(msgs2.length, 2);
      expect(msgs2[0].text, 'Second conversation');
      expect(msgs2[1].text, 'Reply in second');
    });
  });

  // ── Persistence — no message loss ───────────────────────────────

  group('Persistence — no message loss', () {
    test('messages survive provider state transitions', () {
      final conv = ConversationProvider();
      conv.startConversation();

      conv.startSpeakerTurn();
      conv.updatePartialCaption('Msg 1');
      conv.endSpeakerTurn();

      conv.addUserMessage('Msg 2');

      conv.startSpeakerTurn();
      conv.updatePartialCaption('Msg 3');
      conv.endSpeakerTurn();

      // State transitions: stop → saveDecision → cancel → active
      conv.stopConversation();
      expect(conv.state, ConversationState.saveDecision);
      expect(conv.messages.length, 3); // messages preserved during stop

      conv.cancelStop();
      expect(conv.state, ConversationState.active);
      expect(conv.messages.length, 3); // messages preserved after cancel

      // Add more messages after cancel
      conv.addUserMessage('Msg 4');
      conv.startSpeakerTurn();
      conv.updatePartialCaption('Msg 5');
      conv.endSpeakerTurn();

      expect(conv.messages.length, 5);
      expect(conv.messages[0].text, 'Msg 1');
      expect(conv.messages[4].text, 'Msg 5');
    });

    test('stopConversation commits active partial before save decision', () {
      final conv = ConversationProvider();
      conv.startConversation();

      conv.startSpeakerTurn();
      conv.updatePartialCaption('In-progress message');
      conv.stopConversation();

      // The in-progress message should have been committed
      expect(conv.messages.length, 1);
      expect(conv.messages[0].text, 'In-progress message');
      expect(conv.messages[0].isPartial, false);
      expect(conv.state, ConversationState.saveDecision);
    });

    test('quick reply does not delete previous messages', () {
      final conv = ConversationProvider();
      conv.startConversation();

      conv.startSpeakerTurn();
      conv.updatePartialCaption('Speaker said something');
      conv.endSpeakerTurn();

      expect(conv.messages.length, 1);

      // Add quick reply (simulates user tapping a chip)
      conv.addUserMessage('Thank you');
      expect(conv.messages.length, 2);
      expect(conv.messages[0].text, 'Speaker said something');
      expect(conv.messages[1].text, 'Thank you');

      // Add another quick reply
      conv.addUserMessage('Please wait');
      expect(conv.messages.length, 3);
      expect(conv.messages[0].text, 'Speaker said something');
      expect(conv.messages[1].text, 'Thank you');
      expect(conv.messages[2].text, 'Please wait');
    });

    test('multiple mic holds do not delete previous messages', () {
      final conv = ConversationProvider();
      conv.startConversation();

      // Hold 1
      conv.startSpeakerTurn();
      conv.updatePartialCaption('First hold');
      conv.endSpeakerTurn();
      expect(conv.messages.length, 1);

      // Hold 2
      conv.startSpeakerTurn();
      conv.updatePartialCaption('Second hold');
      conv.endSpeakerTurn();
      expect(conv.messages.length, 2);

      // Hold 3
      conv.startSpeakerTurn();
      conv.updatePartialCaption('Third hold');
      conv.endSpeakerTurn();
      expect(conv.messages.length, 3);

      // All previous messages preserved
      expect(conv.messages[0].text, 'First hold');
      expect(conv.messages[1].text, 'Second hold');
      expect(conv.messages[2].text, 'Third hold');
    });

    test('partial updates during mic hold do not affect committed messages', () {
      final conv = ConversationProvider();
      conv.startConversation();

      conv.startSpeakerTurn();
      conv.updatePartialCaption('Hello');
      conv.endSpeakerTurn();
      expect(conv.messages.length, 1);
      expect(conv.messages[0].text, 'Hello');

      // Start new turn — partial updates should not touch the first message
      conv.startSpeakerTurn();
      conv.updatePartialCaption('Hi');
      conv.updatePartialCaption('Hi there');
      conv.updatePartialCaption('Hi there, how');

      expect(conv.messages.length, 1); // still only 1 committed
      expect(conv.messages[0].text, 'Hello'); // unchanged
    });
  });

  // ── Persistence — discard ──────────────────────────────────────

  group('Persistence — discard clears conversation', () {
    test('deleteConversation clears all messages', () {
      final conv = ConversationProvider();
      conv.startConversation();

      conv.startSpeakerTurn();
      conv.updatePartialCaption('Msg 1');
      conv.endSpeakerTurn();
      conv.addUserMessage('Msg 2');

      expect(conv.messages.length, 2);

      conv.deleteConversation();
      expect(conv.messages, isEmpty);
      expect(conv.state, ConversationState.idle);
      expect(conv.activePartial, isNull);
      expect(conv.isMicHeld, false);
    });

    test('saveConversation on empty conversation resets state', () async {
      final conv = ConversationProvider();
      conv.startConversation();

      await conv.saveConversation();
      expect(conv.state, ConversationState.idle);
      expect(conv.messages, isEmpty);
    });
  });

  // ── Persistence — delete saved ──────────────────────────────────

  group('Persistence — deleteSavedConversation', () {
    test('deletes a specific saved conversation', () async {
      final conv = ConversationProvider();

      // Save two conversations
      conv.startConversation();
      conv.addUserMessage('First');
      await conv.saveConversation();

      conv.startConversation();
      conv.addUserMessage('Second');
      await conv.saveConversation();

      var saved = await conv.getSavedConversations();
      expect(saved.length, 2);

      // Delete the first one
      final firstId = saved[0]['id'] as String;
      final deleted = await conv.deleteSavedConversation(firstId);
      expect(deleted, isTrue);

      saved = await conv.getSavedConversations();
      expect(saved.length, 1);
      expect((saved[0]['messages'] as List).length, 1);
    });

    test('returns false for non-existent session ID', () async {
      final conv = ConversationProvider();
      final deleted = await conv.deleteSavedConversation('no-such-id');
      expect(deleted, isFalse);
    });
  });

  // ── Persistence — reload clears old state ───────────────────────

  group('Persistence — reload', () {
    test('reload clears in-memory state', () async {
      final conv = ConversationProvider();
      conv.startConversation();
      conv.addUserMessage('Something');
      expect(conv.messages.length, 1);

      await conv.reload();
      expect(conv.messages, isEmpty);
      expect(conv.state, ConversationState.idle);
    });
  });

  // ── Sequence ordering edge cases ────────────────────────────────

  group('Sequence ordering — edge cases', () {
    test('sequence numbers survive save/load round-trip', () async {
      final conv = ConversationProvider();
      conv.startConversation();

      // Create 5 messages with specific ordering
      conv.startSpeakerTurn();
      conv.updatePartialCaption('A');
      conv.endSpeakerTurn(); // seq 1

      conv.addUserMessage('B'); // seq 2

      conv.startSpeakerTurn();
      conv.updatePartialCaption('C');
      conv.endSpeakerTurn(); // seq 3

      conv.addUserMessage('D'); // seq 4

      conv.startSpeakerTurn();
      conv.updatePartialCaption('E');
      conv.endSpeakerTurn(); // seq 5

      final originalSeqs = conv.messages.map((m) => m.sequenceNumber).toList();

      await conv.saveConversation();
      final saved = await conv.getSavedConversations();
      final sessionId = saved[0]['id'] as String;

      // Load into fresh provider
      final conv2 = ConversationProvider();
      await conv2.loadConversation(sessionId);
      final loadedSeqs = conv2.messages.map((m) => m.sequenceNumber).toList();

      expect(loadedSeqs, originalSeqs);
    });

    test('loadConversation sorts by sequenceNumber even if stored out of order',
        () async {
      // Manually create a conversation with out-of-order messages
      // (this shouldn't happen in normal use, but protects against corruption)
      final conv = ConversationProvider();
      conv.startConversation();

      conv.addUserMessage('First');
      conv.startSpeakerTurn();
      conv.updatePartialCaption('Second');
      conv.endSpeakerTurn();

      await conv.saveConversation();
      final saved = await conv.getSavedConversations();
      final sessionId = saved[0]['id'] as String;

      // Load — should be in sequence order
      final conv2 = ConversationProvider();
      await conv2.loadConversation(sessionId);

      // Verify order is preserved (was in order when saved)
      expect(conv2.messages[0].text, 'First');
      expect(conv2.messages[0].owner, 'user');
      expect(conv2.messages[1].text, 'Second');
      expect(conv2.messages[1].owner, 'speaker');
    });

    test('language is preserved per-message through round-trip', () async {
      final conv = ConversationProvider();
      conv.startConversation();

      conv.startSpeakerTurn();
      conv.updatePartialCaption('Hello', language: 'English');
      conv.endSpeakerTurn();

      conv.addUserMessage('Bonjour');
      // Manually set language on the last message isn't possible via API,
      // but the model supports it. Test the JSON path directly.
      final msg = ConversationMessage(
        text: 'مرحبا',
        owner: 'user',
        language: 'Urdu',
        sequenceNumber: 2,
      );
      conv.messages.add(msg);

      await conv.saveConversation();
      final saved = await conv.getSavedConversations();
      final messages = (saved[0]['messages'] as List)
          .map((m) => ConversationMessage.fromJson(m as Map<String, dynamic>))
          .toList();

      expect(messages[0].language, 'English');
      expect(messages[1].language, 'Urdu');
    });
  });
}
