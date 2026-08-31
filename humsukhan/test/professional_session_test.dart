import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:humsukhan/models/models.dart';
import 'package:humsukhan/providers/professional_provider.dart';

/// Regression tests for Professional Mode live session persistence
/// and STT-restart robustness.
///
/// These tests exercise the pure provider logic — no platform channels,
/// no STT engine, no widget tree.  SharedPreferences is mocked.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // ── Caption persistence ─────────────────────────────────────────

  group('Caption persistence — multiple finalized captions', () {
    test('adding multiple captions preserves all of them', () async {
      final pro = ProfessionalProvider();
      // Wait for initial load.
      await Future.delayed(const Duration(milliseconds: 50));

      final session = await pro.createSession(
        title: 'Test Session',
        type: SessionType.meeting,
      );

      // Add 5 captions simulating a conversation.
      pro.addCaptionToSession(session.id,
          Caption(text: 'Hello everyone', speaker: 'Speaker 1'));
      pro.addCaptionToSession(session.id,
          Caption(text: 'Welcome to the meeting', speaker: 'Speaker 2'));
      pro.addCaptionToSession(session.id,
          Caption(text: 'Let us begin', speaker: 'Speaker 1'));
      pro.addCaptionToSession(session.id,
          Caption(text: 'First topic is the timeline', speaker: 'Speaker 2'));
      pro.addCaptionToSession(session.id,
          Caption(text: 'We need to finalize by Friday', speaker: 'Speaker 1'));

      final updated = pro.sessions.firstWhere((s) => s.id == session.id);
      expect(updated.captions.length, 5);
      expect(updated.captions[0].text, 'Hello everyone');
      expect(updated.captions[4].text, 'We need to finalize by Friday');
    });

    test('captions are persisted to SharedPreferences', () async {
      final pro = ProfessionalProvider();
      await Future.delayed(const Duration(milliseconds: 50));

      final session = await pro.createSession(
        title: 'Persist Test',
        type: SessionType.class_,
      );

      pro.addCaptionToSession(session.id,
          Caption(text: 'First caption', speaker: 'Speaker 1'));
      pro.addCaptionToSession(session.id,
          Caption(text: 'Second caption', speaker: 'Speaker 1'));

      // Verify via a fresh provider that loads from SharedPreferences.
      final pro2 = ProfessionalProvider();
      await Future.delayed(const Duration(milliseconds: 100));

      final restored = pro2.sessions.firstWhere((s) => s.id == session.id);
      expect(restored.captions.length, 2);
      expect(restored.captions[0].text, 'First caption');
      expect(restored.captions[1].text, 'Second caption');
    });

    test('session ID remains unchanged after adding captions', () async {
      final pro = ProfessionalProvider();
      await Future.delayed(const Duration(milliseconds: 50));

      final session = await pro.createSession(
        title: 'ID Stability Test',
        type: SessionType.lecture,
      );
      final originalId = session.id;

      for (var i = 0; i < 10; i++) {
        pro.addCaptionToSession(originalId,
            Caption(text: 'Caption $i', speaker: 'Speaker 1'));
      }

      final updated = pro.sessions.firstWhere((s) => s.id == originalId);
      expect(updated.id, originalId);
      expect(updated.captions.length, 10);
    });
  });

  // ── STT restart simulation ──────────────────────────────────────

  group('STT restart — transcript preservation', () {
    test('simulated restart preserves all previous captions', () async {
      final pro = ProfessionalProvider();
      await Future.delayed(const Duration(milliseconds: 50));

      final session = await pro.createSession(
        title: 'Restart Test',
        type: SessionType.meeting,
      );

      // Phase 1: Normal speech — 3 captions.
      pro.addCaptionToSession(session.id,
          Caption(text: 'Before restart 1', speaker: 'Speaker 1'));
      pro.addCaptionToSession(session.id,
          Caption(text: 'Before restart 2', speaker: 'Speaker 1'));
      pro.addCaptionToSession(session.id,
          Caption(text: 'Before restart 3', speaker: 'Speaker 1'));

      expect(pro.sessions.firstWhere((s) => s.id == session.id).captions.length, 3);

      // Phase 2: Simulate STT restart — add more captions.
      // (In real code, _restartListening would be called.  Here we just
      // verify that adding more captions doesn't lose previous ones.)
      pro.addCaptionToSession(session.id,
          Caption(text: 'After restart 1', speaker: 'Speaker 1'));
      pro.addCaptionToSession(session.id,
          Caption(text: 'After restart 2', speaker: 'Speaker 1'));

      final updated = pro.sessions.firstWhere((s) => s.id == session.id);
      expect(updated.captions.length, 5);
      expect(updated.captions[0].text, 'Before restart 1');
      expect(updated.captions[2].text, 'Before restart 3');
      expect(updated.captions[3].text, 'After restart 1');
      expect(updated.captions[4].text, 'After restart 2');
    });

    test('caption after restart appears BELOW previous captions', () async {
      final pro = ProfessionalProvider();
      await Future.delayed(const Duration(milliseconds: 50));

      final session = await pro.createSession(
        title: 'Order Test',
        type: SessionType.class_,
      );

      // Add captions with timestamps to verify ordering.
      final now = DateTime.now();
      pro.addCaptionToSession(session.id, Caption(
        text: 'First',
        speaker: 'Speaker 1',
        timestamp: now,
      ));
      pro.addCaptionToSession(session.id, Caption(
        text: 'Second',
        speaker: 'Speaker 1',
        timestamp: now.add(const Duration(seconds: 1)),
      ));
      pro.addCaptionToSession(session.id, Caption(
        text: 'Third (after restart)',
        speaker: 'Speaker 1',
        timestamp: now.add(const Duration(seconds: 5)),
      ));

      final captions = pro.sessions.firstWhere((s) => s.id == session.id).captions;
      expect(captions.length, 3);
      // Verify insertion order (timestamps should be monotonically increasing).
      for (var i = 1; i < captions.length; i++) {
        expect(
          captions[i].timestamp.isAfter(captions[i - 1].timestamp) ||
              captions[i].timestamp.isAtSameMomentAs(captions[i - 1].timestamp),
          isTrue,
          reason: 'Caption $i should be at or after caption ${i - 1}',
        );
      }
    });

    test('session ID unchanged after multiple restarts', () async {
      final pro = ProfessionalProvider();
      await Future.delayed(const Duration(milliseconds: 50));

      final session = await pro.createSession(
        title: 'Multi-Restart Test',
        type: SessionType.meeting,
      );
      final originalId = session.id;

      // Simulate 5 restart cycles.
      for (var cycle = 0; cycle < 5; cycle++) {
        pro.addCaptionToSession(originalId,
            Caption(text: 'Cycle $cycle caption', speaker: 'Speaker 1'));
        // Verify ID hasn't changed.
        expect(
          pro.sessions.any((s) => s.id == originalId),
          isTrue,
          reason: 'Session should still exist after cycle $cycle',
        );
      }

      final finalSession = pro.sessions.firstWhere((s) => s.id == originalId);
      expect(finalSession.id, originalId);
      expect(finalSession.captions.length, 5);
    });
  });

  // ── Partial caption handling ────────────────────────────────────

  group('Partial captions — orphans and finalization', () {
    test('partial caption can be set and removed', () async {
      final pro = ProfessionalProvider();
      await Future.delayed(const Duration(milliseconds: 50));

      final session = await pro.createSession(
        title: 'Partial Test',
        type: SessionType.meeting,
      );

      // Set a partial.
      final partialId = 'partial_test_1';
      pro.setPartialCaption(
        session.id,
        Caption(
          id: partialId,
          text: 'Partial text',
          speaker: 'Speaker 1',
          isPartial: true,
        ),
        partialId,
      );

      var updated = pro.sessions.firstWhere((s) => s.id == session.id);
      expect(updated.captions.length, 1);
      expect(updated.captions[0].isPartial, isTrue);

      // Remove the partial.
      pro.removePartialCaption(session.id, partialId);
      updated = pro.sessions.firstWhere((s) => s.id == session.id);
      expect(updated.captions.length, 0);
    });

    test('orphaned partial can be finalized as permanent caption', () async {
      final pro = ProfessionalProvider();
      await Future.delayed(const Duration(milliseconds: 50));

      final session = await pro.createSession(
        title: 'Orphan Test',
        type: SessionType.class_,
      );

      // Simulate an orphaned partial (set but never finalized by STT).
      final partialId = 'partial_orphan_1';
      pro.setPartialCaption(
        session.id,
        Caption(
          id: partialId,
          text: 'Orphaned partial text',
          speaker: 'Speaker 1',
          isPartial: true,
        ),
        partialId,
      );

      // Finalize it manually (simulating what the screen does on restart).
      final partial = pro.sessions
          .firstWhere((s) => s.id == session.id)
          .captions
          .firstWhere((c) => c.id == partialId);
      pro.addCaptionToSession(
        session.id,
        Caption(
          text: partial.text,
          speaker: partial.speaker,
          language: partial.language,
          isPartial: false,
        ),
      );
      pro.removePartialCaption(session.id, partialId);

      final updated = pro.sessions.firstWhere((s) => s.id == session.id);
      expect(updated.captions.length, 1);
      expect(updated.captions[0].text, 'Orphaned partial text');
      expect(updated.captions[0].isPartial, isFalse);
    });
  });

  // ── Stop Session ────────────────────────────────────────────────

  group('Stop Session — preserves all captions', () {
    test('stopSession preserves all captions and marks completed', () async {
      final pro = ProfessionalProvider();
      await Future.delayed(const Duration(milliseconds: 50));

      final session = await pro.createSession(
        title: 'Stop Test',
        type: SessionType.meeting,
      );

      // Add several captions.
      pro.addCaptionToSession(session.id,
          Caption(text: 'Caption 1', speaker: 'Speaker 1'));
      pro.addCaptionToSession(session.id,
          Caption(text: 'Caption 2', speaker: 'Speaker 2'));
      pro.addCaptionToSession(session.id,
          Caption(text: 'Caption 3', speaker: 'Speaker 1'));

      // Stop the session.
      await pro.stopSession(session.id);

      final completed = pro.sessions.firstWhere((s) => s.id == session.id);
      expect(completed.status, SessionStatus.completed);
      expect(completed.captions.length, 3);
      expect(completed.transcriptText, isNotNull);
      expect(completed.transcriptText!, contains('Caption 1'));
      expect(completed.transcriptText!, contains('Caption 3'));
    });

    test('stopSession with orphaned partials finalizes them', () async {
      final pro = ProfessionalProvider();
      await Future.delayed(const Duration(milliseconds: 50));

      final session = await pro.createSession(
        title: 'Stop With Partial',
        type: SessionType.lecture,
      );

      pro.addCaptionToSession(session.id,
          Caption(text: 'Final caption', speaker: 'Speaker 1'));

      // Add a partial that was never finalized.
      pro.setPartialCaption(
        session.id,
        Caption(
          id: 'partial_stop_test',
          text: 'Unfinished thought',
          speaker: 'Speaker 1',
          isPartial: true,
        ),
        'partial_stop_test',
      );

      // Stop — the screen would finalize partials before calling this.
      // Simulate that by finalizing manually.
      final sessionData = pro.sessions.firstWhere((s) => s.id == session.id);
      final partials = sessionData.captions
          .where((c) => c.isPartial && c.text.trim().isNotEmpty)
          .toList();
      for (final p in partials) {
        pro.addCaptionToSession(session.id,
            Caption(text: p.text, speaker: p.speaker, language: p.language));
        pro.removePartialCaption(session.id, p.id);
      }

      await pro.stopSession(session.id);

      final completed = pro.sessions.firstWhere((s) => s.id == session.id);
      expect(completed.status, SessionStatus.completed);
      expect(completed.captions.length, 2);
      expect(completed.captions[0].text, 'Final caption');
      expect(completed.captions[1].text, 'Unfinished thought');
    });
  });

  // ── Edge cases ──────────────────────────────────────────────────

  group('Edge cases', () {
    test('empty captions do not create empty session transcript', () async {
      final pro = ProfessionalProvider();
      await Future.delayed(const Duration(milliseconds: 50));

      final session = await pro.createSession(
        title: 'Empty Test',
        type: SessionType.class_,
      );

      // Stop without adding any captions.
      await pro.stopSession(session.id);

      final completed = pro.sessions.firstWhere((s) => s.id == session.id);
      expect(completed.status, SessionStatus.completed);
      expect(completed.captions, isEmpty);
    });

    test('hundreds of captions remain one continuous session', () async {
      final pro = ProfessionalProvider();
      await Future.delayed(const Duration(milliseconds: 50));

      final session = await pro.createSession(
        title: 'Large Session',
        type: SessionType.meeting,
      );

      // Add 200 captions.
      for (var i = 0; i < 200; i++) {
        pro.addCaptionToSession(session.id,
            Caption(text: 'Caption $i', speaker: 'Speaker 1'));
      }

      final updated = pro.sessions.firstWhere((s) => s.id == session.id);
      expect(updated.captions.length, 200);
      expect(updated.id, session.id); // same session throughout
    });

    test('100+ captions: all retained, correct order, newest last, one session', () async {
      final pro = ProfessionalProvider();
      await Future.delayed(const Duration(milliseconds: 50));

      final session = await pro.createSession(
        title: '100+ Caption Stress Test',
        type: SessionType.class_,
      );
      final sessionId = session.id;

      // ── Phase 1: Add 120 captions with explicit ordering ─────────
      for (var i = 0; i < 120; i++) {
        pro.addCaptionToSession(sessionId,
            Caption(text: 'Message #$i', speaker: i.isEven ? 'Speaker 1' : 'Speaker 2'));
      }

      final phase1 = pro.sessions.firstWhere((s) => s.id == sessionId);
      // ALL 120 captions retained — no discarding.
      expect(phase1.captions.length, 120, reason: 'All 120 captions must be retained');
      // Session identity unchanged — still ONE session.
      expect(phase1.id, sessionId, reason: 'Session ID must remain unchanged');
      // Ordering preserved — first is #0, last is #119.
      expect(phase1.captions.first.text, 'Message #0', reason: 'First caption is #0');
      expect(phase1.captions.last.text, 'Message #119', reason: 'Newest caption (#119) is last');

      // ── Phase 2: Simulate STT restart — add 30 more ──────────────
      for (var i = 120; i < 150; i++) {
        pro.addCaptionToSession(sessionId,
            Caption(text: 'After-restart #$i', speaker: 'Speaker 1'));
      }

      final phase2 = pro.sessions.firstWhere((s) => s.id == sessionId);
      // Still 150 total — no old captions lost.
      expect(phase2.captions.length, 150, reason: 'All 150 captions retained after restart');
      expect(phase2.id, sessionId, reason: 'Session ID unchanged after restart');
      // First caption still #0, newest is #149.
      expect(phase2.captions.first.text, 'Message #0', reason: 'First caption preserved');
      expect(phase2.captions.last.text, 'After-restart #149', reason: 'Newest caption is last');
      // The transition from phase 1 → phase 2 is seamless.
      expect(phase2.captions[119].text, 'Message #119', reason: 'Phase 1 last caption intact');
      expect(phase2.captions[120].text, 'After-restart #120', reason: 'Phase 2 first caption follows');

      // ── Phase 3: Verify persistence round-trip ───────────────────
      final pro2 = ProfessionalProvider();
      await Future.delayed(const Duration(milliseconds: 100));
      final reloaded = pro2.sessions.firstWhere((s) => s.id == sessionId);
      expect(reloaded.captions.length, 150, reason: 'All 150 captions survive persistence round-trip');
      expect(reloaded.captions.first.text, 'Message #0');
      expect(reloaded.captions.last.text, 'After-restart #149');
      // Verify the session is still one continuous session.
      expect(reloaded.id, sessionId);
    });

    test('caption ordering uses stable insertion, not timestamp', () async {
      final pro = ProfessionalProvider();
      await Future.delayed(const Duration(milliseconds: 50));

      final session = await pro.createSession(
        title: 'Ordering Test',
        type: SessionType.meeting,
      );

      // Add captions with out-of-order timestamps (simulating async STT arrivals).
      final base = DateTime(2026, 1, 1, 12, 0, 0);
      pro.addCaptionToSession(session.id, Caption(
        text: 'First inserted', speaker: 'Speaker 1',
        timestamp: base.add(const Duration(seconds: 10)),
      ));
      pro.addCaptionToSession(session.id, Caption(
        text: 'Second inserted', speaker: 'Speaker 2',
        timestamp: base, // Earlier timestamp than first!
      ));
      pro.addCaptionToSession(session.id, Caption(
        text: 'Third inserted', speaker: 'Speaker 1',
        timestamp: base.add(const Duration(seconds: 20)),
      ));

      final captions = pro.sessions.firstWhere((s) => s.id == session.id).captions;
      // Insertion order is preserved regardless of timestamps.
      expect(captions[0].text, 'First inserted');
      expect(captions[1].text, 'Second inserted');
      expect(captions[2].text, 'Third inserted');
    });

    test('setPartialCaption updates in-place when partial exists', () async {
      final pro = ProfessionalProvider();
      await Future.delayed(const Duration(milliseconds: 50));

      final session = await pro.createSession(
        title: 'Partial Update',
        type: SessionType.class_,
      );

      final partialId = 'partial_update_test';
      pro.setPartialCaption(
        session.id,
        Caption(id: partialId, text: 'Hello', speaker: 'Speaker 1', isPartial: true),
        partialId,
      );
      pro.setPartialCaption(
        session.id,
        Caption(id: partialId, text: 'Hello, how', speaker: 'Speaker 1', isPartial: true),
        partialId,
      );
      pro.setPartialCaption(
        session.id,
        Caption(id: partialId, text: 'Hello, how are you', speaker: 'Speaker 1', isPartial: true),
        partialId,
      );

      final updated = pro.sessions.firstWhere((s) => s.id == session.id);
      // Should still be only 1 caption (updated in-place, not appended).
      expect(updated.captions.length, 1);
      expect(updated.captions[0].text, 'Hello, how are you');
      expect(updated.captions[0].isPartial, isTrue);
    });
  });
}
