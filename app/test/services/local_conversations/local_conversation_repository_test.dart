import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/backend/schema/structured.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/services/local_conversations/local_conversation_repository.dart';

ServerConversation _conversation(String id, {List<TranscriptSegment> segments = const []}) => ServerConversation(
      id: id,
      createdAt: DateTime.utc(2026, 1, 1),
      startedAt: DateTime.utc(2026, 1, 1),
      finishedAt: DateTime.utc(2026, 1, 1, 0, 5),
      structured: Structured('', ''),
      transcriptSegments: segments,
      status: ConversationStatus.completed,
    );

TranscriptSegment _segment(String id, String text) => TranscriptSegment(
      id: id,
      text: text,
      speaker: 'SPEAKER_00',
      isUser: false,
      personId: null,
      start: 0.0,
      end: 1.0,
      translations: [],
    );

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('local_conversation_repository_test_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  group('LocalConversationRepository restart survival (T8)', () {
    test('a fresh repository instance over the same directory returns the record with segments intact', () async {
      final writer = LocalConversationRepository(directoryProvider: () async => tempDir);
      final conversation = _conversation(
        '${ServerConversation.localOnlyIdPrefix}abc',
        segments: [_segment('s1', 'hello'), _segment('s2', 'world')],
      );

      await writer.save(conversation);

      // This is the "app restart" proof: a brand new repository instance,
      // constructed independently, pointed at the same on-disk directory —
      // not the same object, no shared in-memory state.
      final afterRestart = LocalConversationRepository(directoryProvider: () async => tempDir);
      final all = await afterRestart.listAll();

      expect(all, hasLength(1));
      expect(all.single.id, conversation.id);
      expect(all.single.transcriptSegments.map((s) => s.text), ['hello', 'world']);
      expect(all.single.isLocalOnly, isTrue);

      final byId = await afterRestart.getById(conversation.id);
      expect(byId, isNotNull);
      expect(byId!.transcriptSegments.map((s) => s.id), ['s1', 's2']);
    });

    test('listAll orders newest first and survives multiple restarts', () async {
      final writer = LocalConversationRepository(directoryProvider: () async => tempDir);
      final older = ServerConversation(
        id: '${ServerConversation.localOnlyIdPrefix}older',
        createdAt: DateTime.utc(2026, 1, 1),
        structured: Structured('', ''),
        status: ConversationStatus.completed,
      );
      final newer = ServerConversation(
        id: '${ServerConversation.localOnlyIdPrefix}newer',
        createdAt: DateTime.utc(2026, 1, 2),
        structured: Structured('', ''),
        status: ConversationStatus.completed,
      );
      await writer.save(older);
      await writer.save(newer);

      final reload1 = LocalConversationRepository(directoryProvider: () async => tempDir);
      expect((await reload1.listAll()).map((c) => c.id), [newer.id, older.id]);

      // A second independent instance changes nothing about the first reload's
      // persisted state.
      final reload2 = LocalConversationRepository(directoryProvider: () async => tempDir);
      expect((await reload2.listAll()).map((c) => c.id), [newer.id, older.id]);
    });

    test('save overwrites an existing record in place (no duplicate index entries)', () async {
      final repo = LocalConversationRepository(directoryProvider: () async => tempDir);
      const id = '${ServerConversation.localOnlyIdPrefix}dup';
      await repo.save(_conversation(id, segments: [_segment('s1', 'first save')]));
      await repo.save(_conversation(id, segments: [_segment('s1', 'second save')]));

      final reload = LocalConversationRepository(directoryProvider: () async => tempDir);
      final all = await reload.listAll();

      expect(all, hasLength(1));
      expect(all.single.transcriptSegments.single.text, 'second save');
    });
  });

  group('LocalConversationRepository delete (T9, repository layer)', () {
    test('delete removes the record; a fresh instance no longer sees it', () async {
      final repo = LocalConversationRepository(directoryProvider: () async => tempDir);
      const id = '${ServerConversation.localOnlyIdPrefix}to-delete';
      await repo.save(_conversation(id));

      final existed = await repo.delete(id);
      expect(existed, isTrue);

      final reload = LocalConversationRepository(directoryProvider: () async => tempDir);
      expect(await reload.listAll(), isEmpty);
      expect(await reload.getById(id), isNull);
    });

    test('deleting a record that does not exist returns false and does not throw', () async {
      final repo = LocalConversationRepository(directoryProvider: () async => tempDir);

      final existed = await repo.delete('${ServerConversation.localOnlyIdPrefix}never-saved');

      expect(existed, isFalse);
    });
  });
}
