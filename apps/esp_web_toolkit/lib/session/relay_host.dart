import 'dart:async';
import 'dart:js_interop';

import 'package:esptool/esptool.dart';
import 'package:esptool/web.dart';
import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import 'device_session.dart';
import 'relay_socket.dart';

enum RelayState { idle, starting, sharing }

/// Shares the port selected in [session] through a relay server: the port
/// is served over RFC 2217 ([Rfc2217Server]) to whoever opens the link.
/// Knowing the link's random id is all it takes to connect.
///
/// [session] only supplies the ports, the reset choice and the log; it
/// never opens the port itself.
class RelayHost extends ChangeNotifier {
  RelayHost(this.session, {Uri? relayUrl}) : relayUrl = relayUrl ?? Uri.parse('ws://localhost:8787');

  final DeviceSession session;

  /// The relay server, `ws(s)://host[:port][/prefix]`.
  Uri relayUrl;

  RelayState state = RelayState.idle;

  /// The relay's id for this share, once it has sent it.
  String? sessionId;

  /// The connected client's address, while one is connected.
  String? peer;

  /// The port went away (a native-USB chip re-enumerating) and the share
  /// is waiting for it to come back.
  bool waitingForPort = false;

  SerialPort? _port;
  WebSerialTransport? _transport;
  RelaySocket? _socket;
  Rfc2217Server? server;
  StreamSubscription<List<int>>? _deviceWatch;
  Timer? _notifyTimer;

  void setRelayUrl(Uri url) {
    relayUrl = url;
    notifyListeners();
  }

  Uri _endpoint(String tail) => relayUrl.replace(path: '${relayUrl.path.replaceAll(RegExp(r'/+$'), '')}/$tail');

  /// Where a client connects, once the relay has assigned an id.
  Uri? get clientUrl => sessionId == null ? null : _endpoint('c/$sessionId');

  /// The link to hand out: the full tool, with this device as its port.
  Uri? get shareLink {
    final client = clientUrl;
    if (client == null) return null;
    final route = Uri(path: '/flash', queryParameters: {'remote': '$client'});
    return Uri.parse(web.document.baseURI).replace(fragment: '$route');
  }

  Future<void> start() async {
    final port = session.selectedPort;
    if (port == null || state != RelayState.idle) return;
    state = RelayState.starting;
    notifyListeners();
    try {
      final socket = await RelaySocket.connect(_endpoint('host'));
      _socket = socket;
      final server = Rfc2217Server(
        send: socket.send,
        bootloaderReset: session.resetStrategies(port).first.$1,
        trace: (message) => session.addLog('Relay: $message'),
        onChange: _changedSoon,
      );
      this.server = server;
      await _attach(port, 115200);
      socket.control.listen(_onControl);
      socket.data.listen(server.receive);
      unawaited(socket.closed.then((_) {
        if (identical(_socket, socket)) unawaited(_end('Relay connection closed: ${socket.closeReason}', error: true));
      }));
      state = RelayState.sharing;
      session.addLog('Sharing ${DeviceSession.describePort(port)} through $relayUrl');
    } catch (e) {
      session.addLog('Share failed: $e', error: true);
      await _teardown();
      state = RelayState.idle;
    }
    notifyListeners();
  }

  Future<void> stop() => _end('Stopped sharing');

  Future<void> _end(String why, {bool error = false}) async {
    if (state == RelayState.idle) return;
    session.addLog(why, error: error);
    await _teardown();
    state = RelayState.idle;
    notifyListeners();
  }

  /// Open [port] at [baudRate] and serve it, with its lines released so
  /// the chip keeps running until a client resets it.
  Future<void> _attach(SerialPort port, int baudRate) async {
    final transport = await WebSerialTransport.open(port, baudRate: baudRate);
    try {
      await port.setSignals(SerialOutputSignals(dataTerminalReady: false, requestToSend: false)).toDart;
    } catch (_) {}
    _port = port;
    _transport = transport;
    server!.attach(transport);
    _deviceWatch = transport.input.listen(null, onError: (Object _) => _portLost());
  }

  void _onControl(Map<String, dynamic> message) {
    final server = this.server;
    if (server == null) return;
    switch (message['type']) {
      case 'session':
        sessionId = message['id'] as String?;
      case 'open':
        peer = message['addr'] as String? ?? 'unknown address';
        server.clientConnected();
        session.addLog('Client connected from $peer');
      case 'close':
        server.clientDisconnected();
        session.addLog('Client disconnected');
        peer = null;
    }
    notifyListeners();
  }

  /// The port went away — most likely a native-USB chip re-enumerating
  /// after a reset. Keep the share and wait for the same kind of device.
  void _portLost() {
    final port = _port;
    final transport = _transport;
    if (waitingForPort || port == null || transport == null) return;
    waitingForPort = true;
    _transport = null;
    unawaited(_deviceWatch?.cancel());
    _deviceWatch = null;
    unawaited(server?.detach());
    unawaited(transport.close().catchError((Object _) {}));
    session.addLog('Relay: the port went away, waiting for it to come back');
    notifyListeners();
    final info = port.getInfo();
    unawaited(_reattach(info.usbVendorId, info.usbProductId));
  }

  Future<void> _reattach(int? vendor, int? product) async {
    final s = serial;
    for (var attempt = 0; attempt < 60 && waitingForPort && state == RelayState.sharing && s != null; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final matching = [
        for (final p in (await s.getPorts().toDart).toDart)
          if (p.connected && p.getInfo().usbVendorId == vendor && p.getInfo().usbProductId == product) p,
      ];
      final port = matching.contains(_port) ? _port : (matching.length == 1 ? matching.single : null);
      if (port == null) continue;
      try {
        await _attach(port, server!.baudRate);
        waitingForPort = false;
        session.addLog('Relay: the port is back');
        notifyListeners();
        return;
      } catch (_) {
        // Not openable yet; try again shortly.
      }
    }
    if (waitingForPort) await _end('Relay: the port did not come back', error: true);
  }

  Future<void> _teardown() async {
    final socket = _socket;
    _socket = null;
    socket?.close();
    await _deviceWatch?.cancel();
    _deviceWatch = null;
    await server?.detach();
    server = null;
    final transport = _transport;
    _transport = null;
    try {
      await transport?.close().timeout(const Duration(seconds: 3));
    } catch (_) {}
    _port = null;
    sessionId = null;
    peer = null;
    waitingForPort = false;
  }

  /// Byte counters change with every chunk; repaint at most ~10 times a
  /// second.
  void _changedSoon() {
    _notifyTimer ??= Timer(const Duration(milliseconds: 100), () {
      _notifyTimer = null;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _notifyTimer?.cancel();
    unawaited(_teardown());
    super.dispose();
  }
}
