import 'package:omi/services/sockets/pure_socket.dart';

/// Transport for [SttPrivacyPolicy.localOnly]: wraps the Custom STT primary
/// socket with exactly one child field. There is no secondary (Omi) field to
/// populate — that absence is the compiler-first form of the `localOnly`
/// guarantee: the Omi socket object is never allocated, so it cannot connect,
/// retry, or be revived by a reconnect path (architecture.md §5.2).
///
/// `connect`/`disconnect`/`stop`/`send`/`status` delegate straight to the
/// primary. Primary messages are routed to [onMessage], which
/// `TranscriptSegmentSocketService.withSocket(...)` wires as its own listener
/// — so a primary emitting a JSON-encoded segment list (every provider does;
/// see architecture-revalidation.md refinement 1) flows straight into
/// `TranscriptSegmentSocketService.onMessage`'s existing `jsonDecode` +
/// `_dropSecretSegments` path with no translation layer and no secret-filter
/// regression.
class LocalOnlyTranscriptionSocket implements IPureSocket {
  final IPureSocket primarySocket;

  IPureSocketListener? _listener;
  late final _LocalOnlyPrimaryListener _primaryListener;

  LocalOnlyTranscriptionSocket({required this.primarySocket}) {
    _primaryListener = _LocalOnlyPrimaryListener(this);
    primarySocket.setListener(_primaryListener);
  }

  @override
  PureSocketStatus get status => primarySocket.status;

  @override
  void setListener(IPureSocketListener listener) {
    _listener = listener;
  }

  @override
  Future<bool> connect() => primarySocket.connect();

  @override
  Future disconnect() => primarySocket.disconnect();

  @override
  Future stop() => primarySocket.stop();

  @override
  void send(dynamic message) => primarySocket.send(message);

  @override
  void onConnected() => _listener?.onConnected();

  @override
  void onMessage(dynamic message) => _listener?.onMessage(message);

  @override
  void onClosed([int? closeCode]) => _listener?.onClosed(closeCode);

  @override
  void onError(Object err, StackTrace trace) => _listener?.onError(err, trace);
}

class _LocalOnlyPrimaryListener implements IPureSocketListener {
  final LocalOnlyTranscriptionSocket _owner;
  _LocalOnlyPrimaryListener(this._owner);

  @override
  void onConnected() => _owner.onConnected();

  @override
  void onMessage(dynamic message) => _owner.onMessage(message);

  @override
  void onClosed([int? closeCode]) => _owner.onClosed(closeCode);

  @override
  void onError(Object err, StackTrace trace) => _owner.onError(err, trace);
}
