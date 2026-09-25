import 'dart:async';
import 'dart:typed_data';

import 'transport.dart';

/// Telnet bytes used by RFC 2217.
///
/// @see [https://www.rfc-editor.org/rfc/rfc854]
abstract final class Telnet {
  static const int se = 240;
  static const int sb = 250;
  static const int will = 251;
  static const int wont = 252;
  static const int do_ = 253;
  static const int dont = 254;
  static const int iac = 255;

  static const int binary = 0;
  static const int suppressGoAhead = 3;
  static const int comPortOption = 44;
}

/// RFC 2217 COM-PORT-OPTION commands and values. A server answers command
/// `n` with `n + serverOffset`.
///
/// @see [https://www.rfc-editor.org/rfc/rfc2217]
abstract final class ComPort {
  static const int setBaudRate = 1;
  static const int setDataSize = 2;
  static const int setParity = 3;
  static const int setStopSize = 4;
  static const int setControl = 5;
  static const int notifyLineState = 6;
  static const int notifyModemState = 7;
  static const int flowControlSuspend = 8;
  static const int flowControlResume = 9;
  static const int setLineStateMask = 10;
  static const int setModemStateMask = 11;
  static const int purgeData = 12;

  static const int serverOffset = 100;

  // SET_CONTROL values.
  static const int flowControlRequest = 0;
  static const int flowControlNone = 1;
  static const int dtrRequest = 7;
  static const int dtrOn = 8;
  static const int dtrOff = 9;
  static const int rtsRequest = 10;
  static const int rtsOn = 11;
  static const int rtsOff = 12;

  // PURGE_DATA values.
  static const int purgeReceive = 1;
  static const int purgeTransmit = 2;
  static const int purgeBoth = 3;

  static const int dataSize8 = 8;
  static const int parityNone = 1;
  static const int stopSize1 = 1;
}

/// Double every `IAC` in [data], as Telnet requires of data bytes.
Uint8List telnetEscape(List<int> data) {
  var count = 0;
  for (final b in data) {
    if (b == Telnet.iac) count++;
  }
  if (count == 0) return data is Uint8List ? data : Uint8List.fromList(data);
  final out = Uint8List(data.length + count);
  var i = 0;
  for (final b in data) {
    out[i++] = b;
    if (b == Telnet.iac) out[i++] = Telnet.iac;
  }
  return out;
}

/// A COM-PORT-OPTION subnegotiation: `IAC SB 44 <command> <payload> IAC SE`.
Uint8List comPortCommand(int command, List<int> payload) =>
    Uint8List.fromList([Telnet.iac, Telnet.sb, Telnet.comPortOption, ...telnetEscape([command, ...payload]), Telnet.iac, Telnet.se]);

Uint8List _u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v);

/// Splits a Telnet byte stream into data, option negotiation and
/// subnegotiations. Feed it chunks with [add]; it keeps state across them.
class TelnetDecoder {
  TelnetDecoder({required this.onData, required this.onNegotiation, required this.onSubnegotiation});

  final void Function(Uint8List data) onData;
  final void Function(int verb, int option) onNegotiation;

  /// The bytes between `IAC SB` and `IAC SE`, unescaped.
  final void Function(Uint8List payload) onSubnegotiation;

  _State _state = _State.data;
  int _verb = 0;
  final _sub = BytesBuilder(copy: false);

  void reset() {
    _state = _State.data;
    _sub.clear();
  }

  void add(List<int> chunk) {
    final data = BytesBuilder(copy: false);
    void flushData() {
      if (data.isNotEmpty) onData(data.takeBytes());
    }

    for (final b in chunk) {
      switch (_state) {
        case _State.data:
          if (b == Telnet.iac) {
            _state = _State.iac;
          } else {
            data.addByte(b);
          }
        case _State.iac:
          switch (b) {
            case Telnet.iac:
              data.addByte(b);
              _state = _State.data;
            case Telnet.will || Telnet.wont || Telnet.do_ || Telnet.dont:
              _verb = b;
              _state = _State.option;
            case Telnet.sb:
              flushData();
              _sub.clear();
              _state = _State.sub;
            default:
              _state = _State.data; // NOP, GA and friends carry nothing for us
          }
        case _State.option:
          flushData();
          onNegotiation(_verb, b);
          _state = _State.data;
        case _State.sub:
          if (b == Telnet.iac) {
            _state = _State.subIac;
          } else {
            _sub.addByte(b);
          }
        case _State.subIac:
          if (b == Telnet.se) {
            onSubnegotiation(_sub.takeBytes());
            _state = _State.data;
          } else {
            _sub.addByte(b); // IAC IAC inside a subnegotiation
            _state = _State.sub;
          }
      }
    }
    flushData();
  }
}

enum _State { data, iac, option, sub, subIac }

/// Option negotiation for one end of the connection: agrees to BINARY,
/// SUPPRESS-GO-AHEAD and COM-PORT-OPTION in both directions, refuses
/// anything else, and never acknowledges a state it is already in (so two
/// of these can't loop).
class _TelnetOptions {
  _TelnetOptions(this._send);
  final void Function(Uint8List bytes) _send;

  static const _supported = {Telnet.binary, Telnet.suppressGoAhead, Telnet.comPortOption};

  /// Options we perform (WILL) and ones the peer performs (DO); absent is off.
  final Map<int, _Option> _local = {};
  final Map<int, _Option> _remote = {};

  void reset() {
    _local.clear();
    _remote.clear();
  }

  /// Offer and ask for every supported option.
  void start() {
    for (final option in _supported) {
      _local[option] = _Option.asked;
      _remote[option] = _Option.asked;
      _send(Uint8List.fromList([Telnet.iac, Telnet.will, option, Telnet.iac, Telnet.do_, option]));
    }
  }

  void handle(int verb, int option) {
    final ok = _supported.contains(option);
    switch (verb) {
      case Telnet.do_:
        _agree(_local, option, ok, Telnet.will, Telnet.wont);
      case Telnet.will:
        _agree(_remote, option, ok, Telnet.do_, Telnet.dont);
      case Telnet.dont:
        _refuse(_local, option, Telnet.wont);
      case Telnet.wont:
        _refuse(_remote, option, Telnet.dont);
    }
  }

  void _agree(Map<int, _Option> state, int option, bool ok, int yes, int no) {
    if (!ok) {
      state.remove(option);
      _reply(no, option);
      return;
    }
    final was = state[option];
    state[option] = _Option.on;
    if (was == null) _reply(yes, option);
  }

  void _refuse(Map<int, _Option> state, int option, int no) {
    final was = state.remove(option);
    if (was == _Option.on) _reply(no, option);
  }

  void _reply(int verb, int option) => _send(Uint8List.fromList([Telnet.iac, verb, option]));
}

enum _Option { asked, on }

/// An [EspTransport] to a serial port shared over RFC 2217 — typically a
/// [Rfc2217Server] on the far side of a relay.
///
/// Byte-stream agnostic: hand it the incoming bytes and a function that sends
/// bytes (a TCP socket, a WebSocket, an in-memory pipe). Call [start] once
/// the connection is up.
///
/// Control-line changes are sent as they happen, without waiting for the
/// server; a [Rfc2217Server] recognises esptool's reset sequences and runs
/// them locally, so network delay doesn't distort their timing.
class Rfc2217Transport extends EspTransport {
  Rfc2217Transport(Stream<List<int>> incoming, this._send, {int baudRate = 115200}) : _baudRate = baudRate {
    _options = _TelnetOptions(_send);
    _decoder = TelnetDecoder(
      onData: _input.add,
      onNegotiation: _options.handle,
      onSubnegotiation: (_) {}, // server acks; nothing waits on them
    );
    _subscription = incoming.listen(
      _decoder.add,
      onError: _input.addError,
      onDone: () {
        closed = true;
        _input.close();
      },
    );
  }

  final void Function(Uint8List bytes) _send;
  late final _TelnetOptions _options;
  late final TelnetDecoder _decoder;
  late final StreamSubscription<List<int>> _subscription;
  final _input = StreamController<List<int>>.broadcast();
  int _baudRate;

  /// Whether the connection has ended (the incoming stream closed).
  bool closed = false;

  /// Negotiate options and set the port to the constructor's baud rate, 8N1.
  void start() {
    _options.start();
    _send(comPortCommand(ComPort.setBaudRate, _u32(_baudRate)));
    _send(comPortCommand(ComPort.setDataSize, [ComPort.dataSize8]));
    _send(comPortCommand(ComPort.setParity, [ComPort.parityNone]));
    _send(comPortCommand(ComPort.setStopSize, [ComPort.stopSize1]));
  }

  @override
  Stream<List<int>> get input => _input.stream;

  @override
  Future<void> write(Uint8List data) async {
    if (closed) throw StateError('RFC 2217 connection closed');
    _send(telnetEscape(data));
  }

  @override
  Future<void> setDtr(bool value) async => _control(value ? ComPort.dtrOn : ComPort.dtrOff);

  @override
  Future<void> setRts(bool value) async => _control(value ? ComPort.rtsOn : ComPort.rtsOff);

  @override
  Future<void> setBaudRate(int baudRate) async {
    _baudRate = baudRate;
    _send(comPortCommand(ComPort.setBaudRate, _u32(baudRate)));
  }

  @override
  Future<void> flushInput() async => _send(comPortCommand(ComPort.purgeData, [ComPort.purgeReceive]));

  void _control(int value) {
    if (closed) throw StateError('RFC 2217 connection closed');
    _send(comPortCommand(ComPort.setControl, [value]));
  }

  Future<void> close() async {
    closed = true;
    await _subscription.cancel();
    await _input.close();
  }
}

/// Serves a local [EspTransport] over RFC 2217 to one client at a time.
///
/// Feed the client's bytes to [receive] and send what [send] is given back to
/// it. Commands and data are applied to the device strictly in order, each
/// finishing before the next starts.
///
/// Like esptool's `esp_rfc2217_server.py`, the DTR/RTS changes of esptool's
/// reset sequences are not passed through one by one — over a network their
/// timing is lost — but recognised and replayed locally:
///
/// - DTR asserted outside download mode runs [bootloaderReset] and enters
///   download mode; DTR released leaves it.
/// - RTS released outside download mode runs [hardReset] (reboot into the
///   app).
///
/// Everything else is applied as asked.
class Rfc2217Server {
  Rfc2217Server({
    required this.send,
    required this.bootloaderReset,
    EspReset? hardReset,
    this.trace,
    this.onChange,
  }) : hardReset = hardReset ?? EspResets.hard() {
    _options = _TelnetOptions(send);
    _decoder = TelnetDecoder(onData: _onData, onNegotiation: _options.handle, onSubnegotiation: _onSubnegotiation);
  }

  final void Function(Uint8List bytes) send;
  final EspReset bootloaderReset;
  final EspReset hardReset;
  final void Function(String message)? trace;

  /// Called when [baudRate], the line states or the byte counters change.
  final void Function()? onChange;

  late final _TelnetOptions _options;
  late final TelnetDecoder _decoder;

  EspTransport? _device;
  StreamSubscription<List<int>>? _deviceSubscription;
  bool _clientConnected = false;
  bool _downloadMode = false;
  Future<void> _queue = Future.value();

  /// The baud rate the client asked for; applied to each attached device.
  int baudRate = 115200;
  bool dtr = false;
  bool rts = false;
  int bytesToDevice = 0;
  int bytesFromDevice = 0;

  /// The device the client is talking to, or `null` while there is none
  /// (the port is re-enumerating, say): client data is then dropped.
  EspTransport? get device => _device;

  /// Use [device] from now on. Its output goes to the client, if one is
  /// connected.
  void attach(EspTransport device) {
    _deviceSubscription?.cancel();
    _device = device;
    _deviceSubscription = device.input.listen((chunk) {
      bytesFromDevice += chunk.length;
      if (_clientConnected) send(telnetEscape(chunk));
      onChange?.call();
    }, onError: (Object e) => trace?.call('device read error: $e'));
  }

  /// Stop using the device (it went away). Does not close it.
  Future<void> detach() async {
    final subscription = _deviceSubscription;
    _deviceSubscription = null;
    _device = null;
    await subscription?.cancel();
  }

  /// A client connected: start a fresh Telnet session with it.
  void clientConnected() {
    _clientConnected = true;
    _decoder.reset();
    _options.reset();
    _options.start();
    _downloadMode = false;
  }

  void clientDisconnected() {
    _clientConnected = false;
  }

  /// Bytes from the client.
  void receive(List<int> bytes) => _decoder.add(bytes);

  /// Wait for everything received so far to be applied.
  Future<void> get idle => _queue;

  void _enqueue(String what, Future<void> Function(EspTransport device) op) {
    _queue = _queue.then((_) async {
      final device = _device;
      if (device == null) return;
      try {
        await op(device);
      } catch (e) {
        trace?.call('$what failed: $e');
      }
    });
  }

  void _onData(Uint8List data) {
    _enqueue('write', (device) async {
      await device.write(data);
      bytesToDevice += data.length;
      onChange?.call();
    });
  }

  void _reply(int command, List<int> payload) => send(comPortCommand(command + ComPort.serverOffset, payload));

  void _onSubnegotiation(Uint8List payload) {
    if (payload.length < 2 || payload[0] != Telnet.comPortOption) return;
    final command = payload[1];
    final args = Uint8List.sublistView(payload, 2);
    switch (command) {
      case ComPort.setBaudRate when args.length >= 4:
        final requested = args.buffer.asByteData(args.offsetInBytes, 4).getUint32(0);
        if (requested == 0) {
          _reply(command, _u32(baudRate));
          return;
        }
        _enqueue('set baud rate', (device) async {
          trace?.call('baud rate $requested');
          await device.setBaudRate(requested);
        });
        baudRate = requested;
        _reply(command, _u32(requested));
        onChange?.call();
      case ComPort.setDataSize:
        _reply(command, [ComPort.dataSize8]);
      case ComPort.setParity:
        _reply(command, [ComPort.parityNone]);
      case ComPort.setStopSize:
        _reply(command, [ComPort.stopSize1]);
      case ComPort.setControl when args.isNotEmpty:
        _reply(command, [_control(args[0])]);
      case ComPort.setLineStateMask || ComPort.setModemStateMask when args.isNotEmpty:
        _reply(command, [args[0]]);
      case ComPort.purgeData when args.isNotEmpty:
        if (args[0] == ComPort.purgeReceive || args[0] == ComPort.purgeBoth) {
          _enqueue('purge', (device) => device.flushInput());
        }
        _reply(command, [args[0]]);
    }
  }

  /// Apply a SET_CONTROL value; returns the value to acknowledge with.
  int _control(int value) {
    switch (value) {
      case ComPort.dtrOff:
        _downloadMode = false;
        _setLine(dtr: false);
      case ComPort.dtrOn when !_downloadMode:
        _downloadMode = true;
        _enqueue('bootloader reset', (device) async {
          trace?.call('bootloader reset');
          await bootloaderReset(device);
        });
      case ComPort.dtrOn:
        _setLine(dtr: true);
      case ComPort.rtsOff when !_downloadMode:
        _enqueue('hard reset', (device) async {
          trace?.call('hard reset');
          await hardReset(device);
        });
        rts = false;
      case ComPort.rtsOff:
        _setLine(rts: false);
      case ComPort.rtsOn:
        _setLine(rts: true);
      case ComPort.dtrRequest:
        return dtr ? ComPort.dtrOn : ComPort.dtrOff;
      case ComPort.rtsRequest:
        return rts ? ComPort.rtsOn : ComPort.rtsOff;
      case ComPort.flowControlRequest || ComPort.flowControlNone:
        return ComPort.flowControlNone;
    }
    onChange?.call();
    return value;
  }

  void _setLine({bool? dtr, bool? rts}) {
    if (dtr != null) {
      this.dtr = dtr;
      _enqueue('DTR', (device) => device.setDtr(dtr));
    }
    if (rts != null) {
      this.rts = rts;
      _enqueue('RTS', (device) => device.setRts(rts));
    }
  }
}
