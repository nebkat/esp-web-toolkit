import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:idftool/idftool.dart';
import 'package:test/test.dart';

const layout = '''
nvs,      data, nvs,     0x9000,  0x6000
otadata,  data, ota,     0xf000,  0x2000
ota_0,    app,  ota_0,   0x20000, 0x100000
ota_1,    app,  ota_1,   0x120000, 0x100000
storage,  data, spiffs,  0x220000, 0x10000
''';

PartitionTable table(String csv) => PartitionTable.fromCsv(csv);

FlashBundle bundle(Map<String, Object> files) {
  final archive = Archive();
  files.forEach((name, content) {
    archive.add(content is String ? ArchiveFile.string(name, content) : ArchiveFile.bytes(name, content as Uint8List));
  });
  return FlashBundle.fromZip(ZipEncoder().encodeBytes(archive));
}

void main() {
  test('compares tables by name, device first', () {
    expect(comparePartitionTables(table(layout), table(layout)), isEmpty);

    final changed = table('''
nvs,      data, nvs,     0x9000,  0x4000
otadata,  data, ota,     0xf000,  0x2000
ota_0,    app,  ota_0,   0x30000, 0x100000
ota_1,    app,  ota_1,   0x130000, 0x100000
fctry,    data, nvs,     0x230000, 0x6000
''');
    final diff = comparePartitionTables(changed, table(layout));
    expect(diff.map((d) => d.toString()), [
      'nvs: resized 24K → 16K',
      'ota_0: moved 0x20000 → 0x30000',
      'ota_1: moved 0x120000 → 0x130000',
      'fctry: new at 0x230000 (24K)',
      'storage: removed (was at 0x220000, 64K)',
    ]);
    // A blank device has nothing: every partition is new.
    expect(comparePartitionTables(table(layout), null).every((d) => d.actual == null), isTrue);
  });

  test('table policy parses, round-trips and reaches the table step', () {
    expect(() => FlashManifest.fromJson({'table': 'sometimes'}), throwsA(predicate((e) => '$e'.contains('"table"'))));
    expect(() => FlashManifest.fromJson({'tableMatch': 'mostly'}), throwsA(predicate((e) => '$e'.contains('"tableMatch"'))));
    final m = FlashManifest.fromJson({'table': 'ask', 'tableMatch': 'used'});
    expect((m.tablePolicy, m.tableMatch), (TablePolicy.ask, TableMatch.used));
    expect(m.toJson(), {'table': 'ask', 'tableMatch': 'used'});

    final b = bundle({'partition_table.csv': layout, 'storage.bin': Uint8List(4), 'manifest.json': jsonEncode({'table': 'require'})});
    expect((b.steps.first as WriteTableStep).policy, TablePolicy.require);
    expect(bundle({'partition_table.csv': layout, 'storage.bin': Uint8List(4)}).steps.first, isA<WriteTableStep>().having((s) => s.policy, 'policy', TablePolicy.update));
  });

  test('a matching table needs nothing; a differing one follows the policy', () {
    final device = table(layout);
    final grown = layout.replaceFirst('0x9000,  0x6000', '0x9000,  0x5000');
    BundleCheck check(String csv, String? policy) =>
        checkBundle(bundle({'partition_table.csv': csv, 'storage.bin': Uint8List(4), if (policy != null) 'manifest.json': jsonEncode({'table': policy})}), device);

    for (final policy in [null, 'ask', 'require']) {
      final same = check(layout, policy);
      expect((same.tableMatches, same.needsApproval, same.blocker), (true, false, null), reason: '$policy');
    }
    expect((check(grown, null).tableChanges, check(grown, null).needsApproval, check(grown, null).blocker), (true, false, null));
    expect((check(grown, 'ask').needsApproval, check(grown, 'ask').blocker), (true, null));
    expect(check(grown, 'require').blocker, contains('different'));
    expect(check(grown, 'ask').differences.single.describe(), 'resized 24K → 20K');
  });

  test('with tableMatch "used", only differences in used partitions matter', () {
    final device = table(layout);
    // nvs shrinks; storage, which the bundle writes, is unchanged.
    final smallerNvs = layout.replaceFirst('0x9000,  0x6000', '0x9000,  0x5000');
    BundleCheck check(Map<String, Object> files, Map<String, String> manifest) =>
        checkBundle(bundle({'partition_table.csv': smallerNvs, ...files, 'manifest.json': jsonEncode(manifest)}), device);
    final writesStorage = {'storage.bin': Uint8List(4)};

    final exact = check(writesStorage, {'table': 'ask'});
    expect((exact.needsApproval, exact.canKeepLayout), (true, false));

    final ask = check(writesStorage, {'table': 'ask', 'tableMatch': 'used'});
    expect((ask.needsApproval, ask.canKeepLayout, ask.automaticChoice, ask.blocker), (true, true, null, null));

    // require: exact refuses; used keeps the device's layout without asking.
    expect(check(writesStorage, {'table': 'require'}).blocker, isNotNull);
    final require = check(writesStorage, {'table': 'require', 'tableMatch': 'used'});
    expect((require.blocker, require.automaticChoice), (null, TableChoice.keep));

    // update still writes it.
    expect(check(writesStorage, {'table': 'update', 'tableMatch': 'used'}).automaticChoice, TableChoice.update);

    // Using the partition that differs takes keeping off the table.
    final writesNvs = check({'nvs.bin': Uint8List(4)}, {'table': 'require', 'tableMatch': 'used'});
    expect(writesNvs.canKeepLayout, isFalse);
    expect(writesNvs.blocker, contains('where this update writes'));

    // Setting the boot slot uses that slot and otadata; a shrunk ota_1 doesn't matter.
    final smallerSlot = layout.replaceFirst('0x120000, 0x100000', '0x120000, 0x80000');
    final boots = checkBundle(
        bundle({'partition_table.csv': smallerSlot, 'manifest.json': jsonEncode({'table': 'ask', 'tableMatch': 'used', 'ops': [{'op': 'set-boot', 'partition': 'ota_0'}]})}), device);
    expect(boots.used, {'ota_0', 'otadata'});
    expect(boots.canKeepLayout, isTrue);
  });

  test("names resolve against the bundle's table, else the device's", () {
    final device = table(layout);
    // No table in the bundle: the device's names.
    final byName = checkBundle(bundle({'storage.bin': Uint8List(4), 'missing.bin': Uint8List(4)}), device);
    expect(byName.carriesTable, isFalse);
    expect(byName.missing.values.single, "'missing' is not a partition on this device");
    expect(byName.blocker, isNotNull);

    // A table that adds the partition makes the name good, before anything is written.
    final adds = checkBundle(bundle({'partition_table.csv': '$layout\nextra, data, spiffs, 0x230000, 0x10000\n', 'extra.bin': Uint8List(4)}), device);
    expect(adds.missing, isEmpty);
    expect(adds.differences.single.name, 'extra');

    // Manifest ops are checked too, as is a blank device.
    final ops = bundle({
      'storage.bin': Uint8List(4),
      'manifest.json': jsonEncode({
        'ops': [
          {'op': 'erase', 'partition': 'coredump'},
          {'op': 'clear-boot'},
        ],
      }),
    });
    expect(checkBundle(ops, device).missing.values, ["'coredump' is not a partition on this device"]);
    expect(checkBundle(ops, null).missing.length, 3);
  });
}
