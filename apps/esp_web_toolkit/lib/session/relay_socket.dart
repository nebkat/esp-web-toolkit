import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:esptool/esptool.dart';
import 'package:web/web.dart' as web;

/// A relay server address as typed, forgiving what pasting tends to
/// produce: an `https://` address (the one a tunnel prints), a bare host,
/// or a scheme typed in front of a pasted one. `null` if it isn't one.
Uri? parseRelayUrl(String text) {
  var t = text.trim();
  final doubled = RegExp(r'^(wss?|https?)://(?=(wss?|https?)://)');
  while (doubled.hasMatch(t)) {
    t = t.replaceFirst(doubled, '');
  }
  if (!t.contains('://')) t = 'wss://$t';
  final url = Uri.tryParse(t);
  if (url == null || url.host.isEmpty) return null;
  return switch (url.scheme) {
    'ws' || 'wss' => url,
    'https' => url.replace(scheme: 'wss'),
    'http' => url.replace(scheme: 'ws'),
    _ => null,
  };
}

/// A shared device's address from what the user pasted: the link a relay
/// page hands out (`…/#/flash?remote=<address>`, or `…/flash?remote=…`
/// from before routes moved into the fragment) or the address itself
/// (`wss://<relay>/c/<id>`). `null` if it is neither.
Uri? parseRemoteAddress(String text) {
  String? fromLink;
  try {
    final link = Uri.tryParse(text.trim());
    fromLink = link?.queryParameters['remote'] ??
        (link == null || link.fragment.isEmpty ? null : Uri.tryParse(link.fragment)?.queryParameters['remote']);
  } on FormatException {
    // Not a link with a query; try it as the address itself.
  }
  final url = parseRelayUrl(fromLink ?? text);
  if (url == null || !RegExp(r'/c/[A-Za-z0-9_-]{16,}$').hasMatch(url.path)) return null;
  return url;
}

/// A WebSocket to the relay server (`apps/relay`): binary frames are the
/// RFC 2217 byte stream, text frames JSON control messages. The relay
/// sends control messages to the host only, and answers the
/// `{"type":"ping"}` both ends send every [keepalive] to keep an idle
/// connection from being dropped.
class RelaySocket {
  RelaySocket._(this._socket) {
    _socket.binaryType = 'arraybuffer';
    _ping = Timer.periodic(keepalive, (_) => _socket.send(_pingMessage.toJS));
    _socket.onmessage = ((web.MessageEvent event) {
      final data = event.data;
      if (data.typeofEquals('string')) {
        final message = jsonDecode((data as JSString).toDart);
        if (message is Map<String, dynamic> && message['type'] != 'pong') _control.add(message);
      } else {
        _data.add((data as JSArrayBuffer).toDart.asUint8List());
      }
    }).toJS;
    _socket.onclose = ((web.CloseEvent event) {
      _ping.cancel();
      closeReason = event.reason.isEmpty ? 'closed (${event.code})' : event.reason;
      _data.close();
      _control.close();
      _closed.complete();
    }).toJS;
  }

  static const keepalive = Duration(seconds: 30);
  static final _pingMessage = jsonEncode({'type': 'ping'});

  final web.WebSocket _socket;
  late final Timer _ping;
  final _data = StreamController<List<int>>();
  final _control = StreamController<Map<String, dynamic>>();
  final _closed = Completer<void>();

  /// Why the socket closed, once it has.
  String? closeReason;

  /// Open a socket to [url], failing if it doesn't open.
  static Future<RelaySocket> connect(Uri url) async {
    final socket = web.WebSocket(url.toString());
    final opened = Completer<void>();
    socket.onopen = ((web.Event _) => opened.complete()).toJS;
    socket.onerror = ((web.Event _) {
      if (!opened.isCompleted) opened.completeError(StateError('Could not reach the relay at $url'));
    }).toJS;
    await opened.future;
    socket.onerror = null;
    return RelaySocket._(socket);
  }

  /// Bytes from the other end. Closes when the socket does.
  Stream<List<int>> get data => _data.stream;

  /// Control messages from the relay.
  Stream<Map<String, dynamic>> get control => _control.stream;

  /// Completes when the socket has closed, from either end.
  Future<void> get closed => _closed.future;

  bool get isOpen => !_closed.isCompleted;

  void send(Uint8List bytes) {
    if (isOpen) _socket.send(bytes.toJS);
  }

  void close() => _socket.close();
}

/// The client end: an RFC 2217 [EspTransport] to a device another browser
/// shares from its relay page, at `wss://<relay>/c/<id>`.
class RemoteTransport extends Rfc2217Transport {
  RemoteTransport._(this.socket, int baudRate) : super(socket.data, socket.send, baudRate: baudRate);

  final RelaySocket socket;

  static Future<RemoteTransport> open(Uri url, {int baudRate = 115200}) async {
    final transport = RemoteTransport._(await RelaySocket.connect(url), baudRate);
    transport.start();
    return transport;
  }

  /// Fail with the relay's reason (no such session, host left) once closed.
  void _check() {
    if (!socket.isOpen) throw StateError('Remote device: ${socket.closeReason}');
  }

  @override
  Future<void> write(Uint8List data) {
    _check();
    return super.write(data);
  }

  @override
  Future<void> setDtr(bool value) {
    _check();
    return super.setDtr(value);
  }

  @override
  Future<void> setRts(bool value) {
    _check();
    return super.setRts(value);
  }

  @override
  Future<void> close() async {
    socket.close();
    await super.close();
  }
}
