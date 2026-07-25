import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:omi/backend/http/api/conversations.dart';

/// T13 (acceptance-matrix.md): a `local_`-prefixed conversation id must be
/// rejected at the Omi conversation HTTP boundary, not just at whichever
/// call site remembered to check the active privacy policy.
///
/// These tests call the real, unmodified production functions in
/// conversations.dart (not a mirror of their logic) — this is safe and
/// hermetic *specifically* for the rejection case: `rejectLocalOnlyConversationId`
/// is the first statement in every one of these functions, so a `local_` id
/// makes the (async) function complete with
/// LocalOnlyConversationIdRejectedException before it ever reaches
/// `Env.apiBaseUrl`, `makeApiCall`, or any other network/singleton
/// dependency. No Env/network setup is required for that reason.
void main() {
  group('isLocalOnlyConversationId / rejectLocalOnlyConversationId', () {
    test('null id is not local-only', () {
      expect(isLocalOnlyConversationId(null), isFalse);
    });

    test('empty id is not local-only', () {
      expect(isLocalOnlyConversationId(''), isFalse);
    });

    test('a normal server id is not local-only', () {
      expect(isLocalOnlyConversationId('a1b2c3'), isFalse);
    });

    test('a local_-prefixed id is local-only', () {
      expect(isLocalOnlyConversationId('local_abc123'), isTrue);
    });

    test('rejectLocalOnlyConversationId throws only for a local_-prefixed id', () {
      expect(() => rejectLocalOnlyConversationId('local_x'), throwsA(isA<LocalOnlyConversationIdRejectedException>()));
      expect(() => rejectLocalOnlyConversationId('normal-id'), returnsNormally);
    });

    test('the exception message names the offending id', () {
      const id = 'local_abc123';
      expect(const LocalOnlyConversationIdRejectedException(id).toString(), contains(id));
    });
  });

  group('conversation HTTP boundary rejects a local_ id before any network call (T13)', () {
    test('getConversationById', () async {
      await expectLater(
        getConversationById('local_x'),
        throwsA(isA<LocalOnlyConversationIdRejectedException>()),
      );
    });

    test('deleteConversationServer', () async {
      await expectLater(
        deleteConversationServer('local_x'),
        throwsA(isA<LocalOnlyConversationIdRejectedException>()),
      );
    });

    test('reProcessConversationServer', () async {
      await expectLater(
        reProcessConversationServer('local_x'),
        throwsA(isA<LocalOnlyConversationIdRejectedException>()),
      );
    });

    test('updateConversationTitle', () async {
      await expectLater(
        updateConversationTitle('local_x', 'New title'),
        throwsA(isA<LocalOnlyConversationIdRejectedException>()),
      );
    });

    test('setConversationStarred', () async {
      await expectLater(
        setConversationStarred('local_x', true),
        throwsA(isA<LocalOnlyConversationIdRejectedException>()),
      );
    });

    test('setConversationVisibility (share)', () async {
      await expectLater(
        setConversationVisibility('local_x'),
        throwsA(isA<LocalOnlyConversationIdRejectedException>()),
      );
    });

    test('assignBulkConversationTranscriptSegments (speaker assignment)', () async {
      await expectLater(
        assignBulkConversationTranscriptSegments('local_x', ['seg1'], isUser: true),
        throwsA(isA<LocalOnlyConversationIdRejectedException>()),
      );
    });

    test('mergeConversations rejects if any id in the list is local_-prefixed', () async {
      await expectLater(
        mergeConversations(['normal-id', 'local_x']),
        throwsA(isA<LocalOnlyConversationIdRejectedException>()),
      );
    });

    // Re-check of the seam this slice's own diff opened (brief item 6):
    // uploadLocalFilesV2's conversationId is nullable, and the guard is
    // `if (conversationId != null) rejectLocalOnlyConversationId(conversationId)`.
    // Confirm the guard still rejects when a local_ id *is* passed —
    // the null case is covered separately by the predicate tests above
    // (isLocalOnlyConversationId(null) is false, so the guard is skipped,
    // preserving the existing "create a new conversation via upload"
    // behavior for a real null conversationId; exercising that path to
    // completion would require mocking the multipart network call, which is
    // out of scope here — see PR report).
    test('uploadLocalFilesV2 rejects a local_ conversationId', () async {
      await expectLater(
        uploadLocalFilesV2(<File>[], conversationId: 'local_x'),
        throwsA(isA<LocalOnlyConversationIdRejectedException>()),
      );
    });
  });
}
