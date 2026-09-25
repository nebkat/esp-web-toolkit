import 'dart:async';
import 'dart:typed_data';

import 'package:esptool/esptool.dart';
import 'package:test/test.dart';

/// The device end: records what the server does to it.
class RecordingTransport extends EspTransport {
  final output = StreamController<List<int>>.broadcast();
  final events = <String>[];
  final written = <int>[];

  @override
  Stream<List<int>> get input => output.stream;

  @override
  Future<void> write(Uint8List data) async => written.addAll(data);

  @override
  Future<void> setDtr(bool value) async => events.add('DTR=$value');

  @override
  Future<void> setRts(bool value) async => events.add('RTS=$value');

  @override
  Future<void> setBaudRate(int baudRate) async => events.add('baud=$baudRate');

  @override
  Future<void> flushInput() async => events.add('flush');
}

void main() {
  late RecordingTransport device;
  late Rfc2217Server server;
  late Rfc2217Transport client;
  late int wireBytes;

  setUp(() {
    device = RecordingTransport();
    wireBytes = 0;
    final toClient = StreamController<List<int>>();
    server = Rfc2217Server(
      send: (bytes) {
        wireBytes += bytes.length;
        toClient.add(bytes);
      },
      bootloaderReset: (t) async => device.events.add('bootloader reset'),
      hardReset: (t) async => device.events.add('hard reset'),
    );
    server.attach(device);
    server.clientConnected();
    client = Rfc2217Transport(toClient.stream, (bytes) {
      wireBytes += bytes.length;
      server.receive(bytes);
    });
    client.start();
  });

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
      await server.idle;
    }
  }

  test('negotiation settles and sets 8N1 at the requested baud', () async {
    await settle();
    final before = wireBytes;
    await settle();
    expect(wireBytes, before, reason: 'no negotiation ping-pong');
    expect(device.events, ['baud=115200']);
  });

  test('data passes both ways with IAC escaped', () async {
    final received = <int>[];
    client.input.listen(received.addAll);
    await client.write(Uint8List.fromList([1, 0xFF, 2, 0xFF, 0xFF]));
    device.output.add([0xC0, 0xFF, 0x00]);
    await settle();
    expect(device.written, [1, 0xFF, 2, 0xFF, 0xFF]);
    expect(received, [0xC0, 0xFF, 0x00]);
  });

  test("esptool's classic reset becomes one local bootloader reset", () async {
    await settle();
    device.events.clear();
    await EspResets.classic(enterBootDelay: Duration.zero, resetDelay: Duration.zero)(client);
    await client.flushInput();
    await client.write(Uint8List.fromList([0xC0]));
    await settle();
    expect(device.events, ['DTR=false', 'RTS=true', 'bootloader reset', 'RTS=false', 'DTR=false', 'flush']);
    expect(device.written, [0xC0]);
  });

  test('releasing RTS outside download mode is a hard reset', () async {
    await settle();
    device.events.clear();
    await EspResets.hard(holdDelay: Duration.zero)(client);
    await settle();
    expect(device.events, ['RTS=true', 'hard reset']);
  });

  test('baud changes reach the device in order with data', () async {
    await settle();
    device.events.clear();
    await client.write(Uint8List.fromList([1]));
    await client.setBaudRate(921600);
    await settle();
    expect(device.events, ['baud=921600']);
    expect(server.baudRate, 921600);
  });
}
