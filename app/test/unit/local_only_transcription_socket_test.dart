import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/backend/schema/message_event.dart';
import 'package:omi/backend/schema/transcript_segment.dart';
import 'package:omi/env/env.dart';
import 'package:omi/models/custom_stt_config.dart';
import 'package:omi/models/stt_provider.dart';
import 'package:omi/services/sockets/local_only_transcription_socket.dart';
import 'package:omi/services/sockets/pure_socket.dart';
import 'package:omi/services/sockets/transcription_service.dart';

void main() {
  setUpAll(() {
    Env.init(_TestEnvFields());
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });

  group('LocalOnlyTranscriptionSocket', () {
    test('has exactly one child field and delegates connect/disconnect/stop/send/status to it', () async {
      final primary = _FakeSocket();
      final socket = LocalOnlyTranscriptionSocket(primarySocket: primary);

      // No secondary field exists to populate — this is the compiler-first
      // form of the localOnly guarantee (see class doc comment). A
      // CompositeTranscriptionSocket is the only production type with a
      // secondary; asserting this is not one is a cheap extra check, not the
      // primary proof (the primary proof is that the type has no such field).
      expect(socket, isNot(isA<CompositeTranscriptionSocket>()));

      expect(socket.status, PureSocketStatus.notConnected);
      expect(await socket.connect(), isTrue);
      expect(socket.status, PureSocketStatus.connected);

      socket.send('ping');
      expect(primary.sent, ['ping']);

      await socket.disconnect();
      expect(primary.disconnectCalls, 1);

      await socket.stop();
      expect(primary.stopCalls, 1);
    });

    test('T4: routes a primary transcript message straight to the composed listener', () async {
      final primary = _FakeSocket();
      final localOnlySocket = LocalOnlyTranscriptionSocket(primarySocket: primary);
      final service = TranscriptSegmentSocketService.withSocket(
        16000,
        BleAudioCodec.pcm16,
        'en',
        localOnlySocket,
        customSttMode: true,
      );

      final receivedSegments = <TranscriptSegment>[];
      service.subscribe('t4', _RecordingListener(onSegments: receivedSegments.addAll));

      await primary.connect();
      primary.emitMessage(jsonEncode([
        {
          'id': 's1',
          'text': 'hello from the primary',
          'speaker': 'SPEAKER_00',
          'is_user': false,
          'start': 0.0,
          'end': 1.0,
        }
      ]));

      expect(receivedSegments, hasLength(1));
      expect(receivedSegments.single.text, 'hello from the primary');
    });

    test('propagates onConnected/onClosed/onError from the primary to the composed listener', () async {
      final primary = _FakeSocket();
      final socket = LocalOnlyTranscriptionSocket(primarySocket: primary);
      final listener = _RecordingPureSocketListener();
      socket.setListener(listener);

      primary.emitConnected();
      expect(listener.connectedCount, 1);

      primary.emitClosed(1000);
      expect(listener.closedCodes, [1000]);

      final error = Exception('boom');
      primary.emitError(error);
      expect(listener.errors, [error]);
    });
  });

  group('TranscriptSocketServiceFactory localOnly branch (T3)', () {
    test('wraps the primary in LocalOnlyTranscriptionSocket instead of building an Omi composite', () {
      const config = CustomSttConfig(
        provider: SttProvider.customLive,
        url: 'wss://stt.example.test/live',
        privacyPolicy: SttPrivacyPolicy.localOnly,
      );

      final service = TranscriptSocketServiceFactory.createFromCustomConfig(
        16000,
        BleAudioCodec.pcm16,
        'en',
        config,
      );

      // The Omi secondary is never constructed: the composed socket has no
      // secondarySocket field to inspect because it isn't a
      // CompositeTranscriptionSocket at all.
      expect(service.socket, isA<LocalOnlyTranscriptionSocket>());
      expect(service.socket, isNot(isA<CompositeTranscriptionSocket>()));
    });

    test('full and transcriptOnly policies still build the Omi composite (regression guard)', () {
      const fullConfig = CustomSttConfig(
        provider: SttProvider.customLive,
        url: 'wss://stt.example.test/live',
        privacyPolicy: SttPrivacyPolicy.full,
      );
      const transcriptOnlyConfig = CustomSttConfig(
        provider: SttProvider.customLive,
        url: 'wss://stt.example.test/live',
        privacyPolicy: SttPrivacyPolicy.transcriptOnly,
      );

      final fullService =
          TranscriptSocketServiceFactory.createFromCustomConfig(16000, BleAudioCodec.pcm16, 'en', fullConfig);
      final transcriptOnlyService = TranscriptSocketServiceFactory.createFromCustomConfig(
        16000,
        BleAudioCodec.pcm16,
        'en',
        transcriptOnlyConfig,
      );

      expect(fullService.socket, isA<CompositeTranscriptionSocket>());
      expect((fullService.socket as CompositeTranscriptionSocket).forwardRawAudioToSecondary, isTrue);

      expect(transcriptOnlyService.socket, isA<CompositeTranscriptionSocket>());
      expect((transcriptOnlyService.socket as CompositeTranscriptionSocket).forwardRawAudioToSecondary, isFalse);
    });
  });
}

class _TestEnvFields implements EnvFields {
  @override
  String? get apiBaseUrl => 'https://api.example.test/';

  @override
  String? get googleClientId => null;

  @override
  String? get googleClientSecret => null;

  @override
  String? get googleMapsApiKey => null;

  @override
  String? get intercomAndroidApiKey => null;

  @override
  String? get intercomAppId => null;

  @override
  String? get intercomIOSApiKey => null;

  @override
  String? get openAIAPIKey => null;

  @override
  String? get posthogApiKey => null;

  @override
  bool? get useAuthCustomToken => false;

  @override
  bool? get useWebAuth => false;
}

class _FakeSocket implements IPureSocket {
  final List<dynamic> sent = [];
  IPureSocketListener? _listener;
  PureSocketStatus _status = PureSocketStatus.notConnected;
  int disconnectCalls = 0;
  int stopCalls = 0;

  @override
  PureSocketStatus get status => _status;

  @override
  Future<bool> connect() async {
    _status = PureSocketStatus.connected;
    _listener?.onConnected();
    return true;
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    _status = PureSocketStatus.disconnected;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    await disconnect();
  }

  @override
  void onClosed([int? closeCode]) => _listener?.onClosed(closeCode);

  @override
  void onConnected() => _listener?.onConnected();

  @override
  void onError(Object err, StackTrace trace) => _listener?.onError(err, trace);

  @override
  void onMessage(dynamic message) => _listener?.onMessage(message);

  @override
  void send(dynamic message) => sent.add(message);

  @override
  void setListener(IPureSocketListener listener) => _listener = listener;

  void emitMessage(dynamic message) => _listener?.onMessage(message);
  void emitConnected() => _listener?.onConnected();
  void emitClosed([int? closeCode]) => _listener?.onClosed(closeCode);
  void emitError(Object err) => _listener?.onError(err, StackTrace.current);
}

class _RecordingPureSocketListener implements IPureSocketListener {
  int connectedCount = 0;
  final List<int?> closedCodes = [];
  final List<Object> errors = [];

  @override
  void onConnected() => connectedCount++;

  @override
  void onMessage(dynamic message) {}

  @override
  void onClosed([int? closeCode]) => closedCodes.add(closeCode);

  @override
  void onError(Object err, StackTrace trace) => errors.add(err);
}

class _RecordingListener implements ITransctiptSegmentSocketServiceListener {
  _RecordingListener({required this.onSegments});

  final void Function(List<TranscriptSegment> segments) onSegments;
  int connectedCount = 0;
  final List<int?> closedCodes = [];
  final List<Object> errors = [];

  @override
  void onSegmentReceived(List<TranscriptSegment> segments) => onSegments(segments);

  @override
  void onMessageEventReceived(MessageEvent event) {}

  @override
  void onConnected() => connectedCount++;

  @override
  void onClosed([int? closeCode]) => closedCodes.add(closeCode);

  @override
  void onError(Object err) => errors.add(err);
}
