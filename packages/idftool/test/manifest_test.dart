import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:esptool/esptool.dart';
import 'package:idftool/idftool.dart';
import 'package:test/test.dart';

Uint8List zipWith(Map<String, Object> files) {
  final archive = Archive();
  files.forEach((name, content) {
    archive.add(content is String ? ArchiveFile.string(name, content) : ArchiveFile.bytes(name, content as Uint8List));
  });
  return ZipEncoder().encodeBytes(archive);
}

String manifest(List<Map<String, Object>> ops, {String? chip = 'esp32s3'}) =>
    jsonEncode({'name': 'Test', 'description': 'd', if (chip != null) 'chip': chip, 'ops': ops});

void main() {
  test('parses every op and describes it', () {
    final m = FlashManifest.fromJson(jsonDecode(manifest([
      {'op': 'write', 'partition': 'storage', 'file': 'fs.bin'},
      {'op': 'erase', 'partition': 'nvs'},
      {'op': 'write-fs', 'partition': 'storage', 'file': 'fs.bin'},
      {'op': 'edit-fs', 'partition': 'storage', 'put': {'config.json': 'files/storage/config.json'}, 'delete': ['old.txt']},
      {'op': 'set-boot', 'partition': 'ota_1'},
      {'op': 'clear-boot'},
      {'op': 'set-nvs', 'partition': 'nvs', 'set': {'cfg:channel': 'string:stable'}, 'delete': ['cfg:old']},
    ])) as Map<String, dynamic>);
    expect(m.chip, EspChip.esp32s3);
    expect(m.ops.map((s) => s.op), ['write', 'erase', 'write-fs', 'edit-fs', 'set-boot', 'clear-boot', 'set-nvs']);
    expect(m.ops.map((s) => s.describe()).join('\n'), contains('cfg:channel = string:stable, delete cfg:old'));
    expect((m.ops.last as SetNvsStep).edits.map((e) => e.qualified), ['cfg:channel', 'cfg:old']);
    expect(m.ops.expand((s) => s.files).toSet(), {'fs.bin', 'files/storage/config.json'});
    // Round-trips through JSON.
    expect(FlashManifest.fromJson(m.toJson()).toJson(), m.toJson());
  });

  test('set-nvs takes the type from the value, the key, or the image', () {
    SetNvsStep step(Map<String, String> set) => FlashManifest.fromJson({
          'name': 'x',
          'ops': [{'op': 'set-nvs', 'partition': 'nvs', 'set': set}],
        }).ops.single as SetNvsStep;

    // `ns:key` -> `type:value` is the form the flasher writes into a bundle.
    final typedValue = step({'oem:logo': 'u32:1'}).edits.single;
    expect((typedValue.namespace, typedValue.key, typedValue.type, typedValue.value), ('oem', 'logo', NvsType.u32, 1));
    // The CLI's `ns:key:type` = value works too.
    final typedKey = step({'oem:logo:u32': '1'}).edits.single;
    expect((typedKey.namespace, typedKey.key, typedKey.type, typedKey.value), ('oem', 'logo', NvsType.u32, 1));
    // No type anywhere: left to resolve against the entry being replaced.
    final untyped = step({'oem:logo': '1'}).edits.single;
    expect((untyped.type, untyped.value), (null, '1'));
    // A value that merely contains a colon is not a type.
    final url = step({'cfg:url': 'https://x.example/a'}).edits.single;
    expect((url.type, url.value), (null, 'https://x.example/a'));
    expect(step({'cfg:channel': 'string:stable'}).edits.single.value, 'stable');
    // Two types is a mistake worth reporting, not one to guess at.
    expect(() => step({'oem:logo:u32': 'u32:1'}).edits, throwsA(isA<NvsError>()));
  });

  test('rejects bad manifests with the step number', () {
    expect(() => FlashManifest.fromJson({'name': 'x', 'ops': []}), throwsA(isA<IdfToolException>()));
    expect(() => FlashManifest.fromJson({'name': 'x', 'chip': 'esp99', 'ops': [{'op': 'clear-boot'}]}),
        throwsA(predicate((e) => '$e'.contains("unknown chip 'esp99'"))));
    expect(() => FlashManifest.fromJson({'name': 'x', 'ops': [{'op': 'clear-boot'}, {'op': 'write', 'partition': 'storage'}]}),
        throwsA(predicate((e) => '$e'.contains('op 2') && '$e'.contains('"file" is required'))));
    expect(() => FlashManifest.fromJson({'name': 'x', 'ops': [{'op': 'set-nvs'}]}),
        throwsA(predicate((e) => '$e'.contains('needs "set" and/or "delete"'))));
    expect(() => FlashManifest.fromJson({'name': 'x', 'ops': [{'op': 'edit-fs', 'partition': 'storage'}]}),
        throwsA(predicate((e) => '$e'.contains('needs "put" and/or "delete"'))));
    expect(() => FlashManifest.fromJson({'name': 'x', 'ops': [{'op': 'frobnicate'}]}),
        throwsA(predicate((e) => '$e'.contains("unknown op 'frobnicate'"))));
    // The table, bootloader and app are files, not ops.
    for (final op in ['write-bundle', 'factory', 'ota', 'write-table', 'write-bootloader']) {
      expect(() => FlashManifest.fromJson({'ops': [{'op': op, 'file': 'x.bin'}]}), throwsA(predicate((e) => '$e'.contains("unknown op '$op'"))), reason: op);
    }
    expect(() => FlashManifest.fromJson({'name': ''}), throwsA(isA<IdfToolException>()));
  });

  test('a manifest needs neither name nor ops', () {
    final m = FlashManifest.fromJson({'ops': [{'op': 'clear-boot'}]});
    expect(m.name, isNull);
    expect(m.ops.single, isA<ClearBootStep>());
    expect(FlashManifest.fromJson(m.toJson()).toJson(), m.toJson());
    expect(FlashManifest.fromJson({'name': 'n'}).toJson(), {'name': 'n'});
  });

  test('bundle checks referenced files exist', () {
    final ok = FlashBundle.fromZip(zipWith({
      'manifest.json': manifest([{'op': 'write-fs', 'partition': 'storage', 'file': 'files/storage.img'}]),
      'files/storage.img': Uint8List(16),
    }));
    expect(ok.name, 'Test');
    expect(ok.chip, EspChip.esp32s3);
    expect(ok.steps.single, isA<WriteFsStep>());
    expect(ok.file('files/storage.img').length, 16);

    expect(() => FlashBundle.fromZip(zipWith({'manifest.json': manifest([{'op': 'write', 'partition': 'storage', 'file': 'files/missing.bin'}])})),
        throwsA(predicate((e) => '$e'.contains("file 'files/missing.bin' is not in the bundle"))));
    expect(() => FlashBundle.fromZip(zipWith({'README.md': 'nothing'})),
        throwsA(predicate((e) => '$e'.contains('Nothing to flash'))));
    expect(() => FlashBundle.fromZip(Uint8List.fromList([1, 2, 3])), throwsA(isA<IdfToolException>()));
  });

  test('convention bundle resolves to steps in bundle order, then the extras', () {
    final b = FlashBundle.fromZip(
      zipWith({
        'nvs.bin': Uint8List(8),
        'manifest.json': jsonEncode({
          'description': 'd',
          'ops': [
            {'op': 'set-nvs', 'partition': 'nvs', 'set': {'cfg:channel': 'string:stable'}},
          ],
        }),
        'partition_table.csv': 'nvs, data, nvs, 0x9000, 0x6000\nfactory, app, factory, 0x20000, 0x100000\n',
        'bootloader.bin': Uint8List(4),
        '@factory.bin': Uint8List(4),
      }),
      source: 'ms5-v0.17.0.zip',
    );
    expect(b.name, 'ms5-v0.17.0');
    expect(b.description, 'd');
    expect(b.chip, isNull);
    expect(b.steps.map((s) => s.op), ['write-table', 'write-bootloader', 'factory', 'write', 'set-nvs']);
    expect((b.steps[3] as WritePartitionStep).file, 'nvs.bin');
    expect(b.contents.table, isNotNull);
  });

  test('the chip comes from the app image when the manifest is silent', () {
    final app = File('test/fixtures/app-v1.bin').readAsBytesSync();
    final b = FlashBundle.fromZip(zipWith({'@ota.bin': app}), source: 'x.zip');
    expect(b.chip, EspChip.esp32s3);
    expect(b.steps.single.describe(), contains('@ota.bin'));
  });
}
