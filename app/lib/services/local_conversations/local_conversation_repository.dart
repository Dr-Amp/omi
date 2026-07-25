import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/utils/logger.dart';

/// Durable local store for `localOnly` conversations: one JSON file per
/// conversation plus an index file, under
/// `path_provider.getApplicationDocumentsDirectory()/local_conversations/`.
///
/// Deliberately file-backed rather than `SharedPreferencesUtil.cachedConversations`
/// (`preferences.dart:507-523`): that list is a bounded cache wiped by
/// `clearAll` (`preferences.dart:667`), which would destroy local-only
/// history on sign-out. Uses only existing dependencies (`path_provider`,
/// already in `pubspec.yaml`) — no sqflite/drift/isar/hive added.
///
/// The directory is injected (not hardcoded to `path_provider` at
/// call sites) so tests can point it at a temp directory.
class LocalConversationRepository {
  LocalConversationRepository({required Future<Directory> Function() directoryProvider})
      : _directoryProvider = directoryProvider;

  /// Production factory: `<app documents>/local_conversations/`.
  factory LocalConversationRepository.appDocuments() {
    return LocalConversationRepository(
      directoryProvider: () async {
        final docs = await getApplicationDocumentsDirectory();
        return Directory('${docs.path}/local_conversations');
      },
    );
  }

  final Future<Directory> Function() _directoryProvider;

  static const String _indexFileName = '_index.json';

  Future<Directory> _ensureDirectory() async {
    final dir = await _directoryProvider();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  String _fileNameFor(String id) => '$id.json';

  /// Persists (creates or overwrites) a local conversation record.
  Future<void> save(ServerConversation conversation) async {
    final dir = await _ensureDirectory();
    final file = File('${dir.path}/${_fileNameFor(conversation.id)}');
    await file.writeAsString(jsonEncode(conversation.toJson()));
    await _updateIndex(dir, add: conversation.id);
  }

  /// Lists every local conversation, newest first. Survives an app restart
  /// via a fresh repository instance reloading from the same directory.
  Future<List<ServerConversation>> listAll() async {
    final dir = await _ensureDirectory();
    final ids = await _readIndex(dir);
    final results = <ServerConversation>[];
    for (final id in ids) {
      final conversation = await _readOne(dir, id);
      if (conversation != null) results.add(conversation);
    }
    results.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return results;
  }

  Future<ServerConversation?> getById(String id) async {
    final dir = await _ensureDirectory();
    return _readOne(dir, id);
  }

  /// Deletes a local conversation. Returns whether a record actually existed.
  /// Never calls an Omi endpoint — deletion is purely local file removal.
  Future<bool> delete(String id) async {
    final dir = await _ensureDirectory();
    final file = File('${dir.path}/${_fileNameFor(id)}');
    var existed = false;
    if (await file.exists()) {
      await file.delete();
      existed = true;
    }
    await _updateIndex(dir, remove: id);
    return existed;
  }

  Future<ServerConversation?> _readOne(Directory dir, String id) async {
    final file = File('${dir.path}/${_fileNameFor(id)}');
    if (!await file.exists()) return null;
    try {
      final raw = await file.readAsString();
      return ServerConversation.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      Logger.debug('LocalConversationRepository: failed to read $id: $e');
      return null;
    }
  }

  Future<List<String>> _readIndex(Directory dir) async {
    final file = File('${dir.path}/$_indexFileName');
    if (!await file.exists()) return [];
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is List) return decoded.map((e) => e.toString()).toList();
      return [];
    } catch (e) {
      Logger.debug('LocalConversationRepository: failed to read index: $e');
      return [];
    }
  }

  Future<void> _writeIndex(Directory dir, List<String> ids) async {
    final file = File('${dir.path}/$_indexFileName');
    await file.writeAsString(jsonEncode(ids));
  }

  Future<void> _updateIndex(Directory dir, {String? add, String? remove}) async {
    final ids = (await _readIndex(dir)).toSet();
    if (add != null) ids.add(add);
    if (remove != null) ids.remove(remove);
    await _writeIndex(dir, ids.toList());
  }
}
