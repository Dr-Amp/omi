import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/backend/schema/structured.dart';
import 'package:omi/providers/conversation_provider.dart';
import 'package:omi/services/local_conversations/local_conversation_repository.dart';

ServerConversation _serverConversation(String id, {DateTime? createdAt}) => ServerConversation(
      id: id,
      createdAt: createdAt ?? DateTime.utc(2026, 1, 1),
      structured: Structured('Title', 'Overview'),
      status: ConversationStatus.completed,
    );

ServerConversation _localConversation(String suffix, {DateTime? createdAt}) => ServerConversation(
      id: '${ServerConversation.localOnlyIdPrefix}$suffix',
      createdAt: createdAt ?? DateTime.utc(2026, 1, 1),
      structured: Structured('', ''),
      status: ConversationStatus.completed,
    );

void main() {
  late Directory tempDir;
  late LocalConversationRepository repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    tempDir = Directory.systemTemp.createTempSync('conversation_provider_local_test_');
    repo = LocalConversationRepository(directoryProvider: () async => tempDir);
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  group('surfacing local-only conversations (item 10 / T8 at the UI layer)', () {
    test('loadLocalConversations lists a persisted local-only conversation, clearly marked as local', () async {
      await repo.save(_localConversation('a'));

      final provider = ConversationProvider(isSignedIn: () => true, localConversationRepository: repo);
      addTearDown(provider.dispose);

      await provider.loadLocalConversations();

      expect(provider.conversations, hasLength(1));
      expect(provider.conversations.single.isLocalOnly, isTrue);
    });

    test('a subsequent fetchConversations() (pull-to-refresh) does not drop local-only history', () async {
      await repo.save(_localConversation('a'));

      final provider = ConversationProvider(
        conversationListFetcher: () async => (items: <ServerConversation>[_serverConversation('server-1')], ok: true),
        isSignedIn: () => true,
        localConversationRepository: repo,
      );
      addTearDown(provider.dispose);

      await provider.loadLocalConversations();
      expect(provider.conversations.map((c) => c.id), contains('${ServerConversation.localOnlyIdPrefix}a'));

      // fetchConversations() rebuilds `conversations` from `result.items`,
      // which never contains local-only records (they don't exist
      // server-side) — without re-merging, this would silently make local
      // history disappear until the next app restart.
      await provider.fetchConversations();

      expect(provider.conversations.map((c) => c.id), containsAll(['server-1', '${ServerConversation.localOnlyIdPrefix}a']));
    });

    test('a freshly finalized local-only conversation (upsertConversation) survives a later refresh', () async {
      final provider = ConversationProvider(
        conversationListFetcher: () async => (items: <ServerConversation>[], ok: true),
        isSignedIn: () => true,
        localConversationRepository: repo,
      );
      addTearDown(provider.dispose);

      // Mirrors CaptureController._finalizeLocalOnlySessionIfNeeded calling
      // externalActions.upsertConversation(...) right after capture stop —
      // no loadLocalConversations() call happens in between.
      provider.upsertConversation(_localConversation('fresh'));
      expect(provider.conversations.map((c) => c.id), contains('${ServerConversation.localOnlyIdPrefix}fresh'));
      // upsertConversation -> addConversation does unawaited first-conversation
      // app-review bookkeeping (pre-existing, not part of this slice); drain it
      // before the test ends so it can't fire notifyListeners() after dispose.
      await pumpEventQueue();

      await provider.fetchConversations();

      expect(provider.conversations.map((c) => c.id), contains('${ServerConversation.localOnlyIdPrefix}fresh'));
    });
  });

  group('deleting a local-only conversation makes no Omi HTTP call (T9)', () {
    test('deleteConversation removes it from the repository and the conversation-API spy records zero calls',
        () async {
      await repo.save(_localConversation('to-delete'));
      var deleterCallCount = 0;

      final provider = ConversationProvider(
        isSignedIn: () => true,
        localConversationRepository: repo,
        conversationDeleter: (id) async {
          deleterCallCount++;
          return true;
        },
      );
      addTearDown(provider.dispose);
      await provider.loadLocalConversations();
      final conversation = provider.conversations.single;

      provider.deleteConversation(conversation);
      // deleteConversation fires the repository delete via unawaited(...)
      // (correct for production — the caller doesn't block the UI on a local
      // file delete); drain it here before this test's tearDown removes tempDir.
      await pumpEventQueue();

      expect(provider.conversations, isEmpty);
      expect(deleterCallCount, 0, reason: 'a local-only delete must never call the Omi conversation-delete HTTP API');
      expect(await repo.listAll(), isEmpty);
    });

    test('a normal server conversation delete still goes through the conversation-API deleter', () async {
      var deleterCallCount = 0;
      final provider = ConversationProvider(
        conversationListFetcher: () async => (items: <ServerConversation>[_serverConversation('server-1')], ok: true),
        isSignedIn: () => true,
        localConversationRepository: repo,
        conversationDeleter: (id) async {
          deleterCallCount++;
          return true;
        },
      );
      addTearDown(provider.dispose);
      await provider.fetchConversations();
      final conversation = provider.conversations.single;

      provider.deleteConversation(conversation);

      expect(deleterCallCount, 1, reason: 'server-origin deletes must still reach the Omi conversation-delete API');
    });

    test(
        'committing a pending delete (deleteConversationOnServer, the swipe-to-delete-with-undo commit '
        'path) makes no Omi call for a local-only conversation', () async {
      // deleteConversationLocally's undo window fires this exact function
      // (either immediately, superseding an earlier still-pending delete, or
      // via its internal 3s Future.delayed) once the undo window lapses.
      // Exercising it directly here proves the commit behavior without a
      // real 3-second wait or fake_async's dart:io interaction.
      await repo.save(_localConversation('swiped'));
      var deleterCallCount = 0;
      final provider = ConversationProvider(
        isSignedIn: () => true,
        localConversationRepository: repo,
        conversationDeleter: (id) async {
          deleterCallCount++;
          return true;
        },
      );
      addTearDown(provider.dispose);
      await provider.loadLocalConversations();
      final conversation = provider.conversations.single;
      provider.memoriesToDelete[conversation.id] = conversation;

      provider.deleteConversationOnServer(conversation.id);

      expect(deleterCallCount, 0, reason: 'a local-only swipe-delete must never call the Omi delete HTTP API');
      expect(await repo.listAll(), isEmpty);
    });
  });
}
