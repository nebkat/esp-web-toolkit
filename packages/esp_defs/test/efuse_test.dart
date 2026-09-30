import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:esp_defs/esp_defs.dart';
import 'package:test/test.dart';

/// `espefuse dump` output → block index → words.
Map<int, Uint32List> _parseDump(String text) => {
      for (final line in LineSplitter.split(text))
        if (RegExp(r'\[(\d+)\s*\] dump: (.*)').firstMatch(line) case final m?)
          int.parse(m.group(1)!): Uint32List.fromList([for (final w in m.group(2)!.trim().split(' ')) int.parse(w, radix: 16)]),
    };

void main() {
  // An ESP32-S3 v0.2 read with espefuse 5.3.1 (`dump`, `summary --format json`).
  final blocks = _parseDump(File('test/fixtures/esp32s3_efuse_dump.txt').readAsStringSync());
  final summary = jsonDecode(File('test/fixtures/esp32s3_efuse_summary.json').readAsStringSync()) as Map<String, dynamic>;
  final values = EfuseValues.decode(EspChip.esp32s3, blocks);

  test('every chip with a table has its blocks and fields', () {
    for (final chip in EspChip.values) {
      final table = efuseTableFor(chip);
      expect(table, isNotNull, reason: chip.name);
      expect(table!.blocks.first.index, 0);
      expect(table.field('WR_DIS'), isNotNull, reason: chip.name);
      for (final f in table.fields) {
        expect(table.block(f.block), isNotNull, reason: '${chip.name} ${f.name}');
      }
    }
  });

  test('raw values match espefuse', () {
    var compared = 0;
    for (final MapEntry(key: name, value: e as Map<String, dynamic>) in summary.entries) {
      final field = values.table.fields.where((f) => f.name == name).firstOrNull;
      if (field == null) continue; // espefuse's calculated fields
      if (field.kind == EfuseKind.mac) continue; // espefuse's raw MAC is neither order
      final raw = (e['raw_value'] as String).substring(2);
      if (field.type == EfuseType.bytes) {
        // Bytes in block order.
        expect(values.bytes(field).map((b) => b.toRadixString(16).padLeft(2, '0')).join(), raw, reason: name);
      } else {
        expect(values.uint(field), int.parse(raw, radix: 16), reason: name);
      }
      expect(values.readProtected(field), !(e['readable'] as bool), reason: name);
      expect(values.writeProtected(field), !(e['writeable'] as bool), reason: name);
      compared++;
    }
    expect(compared, greaterThan(100));
  });

  test('formats values the way espefuse shows them', () {
    String show(String name) => values.format(values.table.field(name)!);
    expect(show('MAC'), '90:e5:b1:cd:47:bc');
    expect(show('KEY_PURPOSE_0'), 'USER');
    expect(show('SPI_BOOT_CRYPT_CNT'), startsWith('Disable'));
    expect(show('DIS_USB_OTG'), 'false');
    expect(show('OPTIONAL_UNIQUE_ID'), summary['OPTIONAL_UNIQUE_ID']['value']);
    expect(show('TEMP_CALIB'), '-16.8 °C');
    expect(values.revision, 2);
    expect(values.keyPurpose(values.table.block(4)!), 'USER');
  });

  test('ESP32 MAC CRC is checked', () {
    final table = efuseTableFor(EspChip.esp32)!;
    // MAC 24:0a:c4:00:01:02; MAC_CRC is BLOCK0 word 2 [23:16], esp_crc8 = 0x98.
    String show(int crc) => EfuseValues(EspChip.esp32, table, {
          0: Uint32List.fromList([0, 0xc4000102, 0x240a | crc << 16, 0, 0, 0, 0])
        }).format(table.field('MAC')!);
    expect(show(0x98), '24:0a:c4:00:01:02 (CRC OK)');
    expect(show(0x99), '24:0a:c4:00:01:02 (CRC 0x99 does not match)');
  });
}
