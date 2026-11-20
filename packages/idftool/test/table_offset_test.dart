import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:esptool/esptool.dart';
import 'package:idftool/idftool.dart';
import 'package:test/test.dart';

/// A bootloader image for [chip] whose description records [tableOffset]
/// (0: records none), or with no description at all. A valid ESP image:
/// one segment, its checksum, no hash.
Uint8List bootloaderImage(EspChip chip, {int tableOffset = 0, bool description = true, int segmentLength = 0x100}) {
  final length = ((ImageHeader.size + 8 + segmentLength + 1 + 15) & ~15);
  final image = Uint8List(length);
  final view = ByteData.sublistView(image);
  image[0] = ImageHeader.magic;
  image[1] = 1; // segments
  image[8] = ImageHeader.wpPinDisabled;
  view.setUint16(12, chip.imageChipId, Endian.little);
  view.setUint32(ImageHeader.size, 0x403c8000, Endian.little); // load address
  view.setUint32(ImageHeader.size + 4, segmentLength, Endian.little);
  if (description) {
    const d = BootloaderDescription.imageOffset;
    image[d] = BootloaderDescription.magic;
    image[d + 3] = 2; // secure version
    view.setUint32(d + 4, 7, Endian.little);
    image.setRange(d + 8, d + 8 + 6, 'v5.5.1'.codeUnits);
    image.setRange(d + 40, d + 40 + 20, 'Nov 20 2026 10:00:00'.codeUnits);
    view.setUint32(d + 64, tableOffset, Endian.little);
  }
  var checksum = ImageMetadata.checksumMagic;
  for (final b in Uint8List.sublistView(image, ImageHeader.size + 8, ImageHeader.size + 8 + segmentLength)) {
    checksum ^= b;
  }
  image[length - 1] = checksum;
  return image;
}

const layout = 'nvs, data, nvs, , 0x6000\nfactory, app, factory, , 1M\n';

PartitionTable csvTable(int tableOffset) => PartitionTable.fromCsv(layout, partitionTableOffset: tableOffset);

/// An [EspLoader] over an in-memory flash, as the stub sees it.
class FakeLoader extends EspLoader {
  FakeLoader(this.flash, {this.fakeChip = EspChip.esp32s3}) : super(_NoTransport());

  final Uint8List flash;
  final EspChip fakeChip;
  final writes = <int>[];

  @override
  EspChip? get chip => fakeChip;

  @override
  Future<Uint8List> readFlash(int offset, int length, {void Function(int read, int total)? onProgress}) async =>
      Uint8List.fromList(Uint8List.sublistView(flash, offset, offset + length));

  @override
  Future<void> writeFlash(int offset, Uint8List data,
      {void Function(int written, int total)? onProgress, bool? compress, bool finish = true, bool reboot = false}) async {
    writes.add(offset);
    flash.setRange(offset, offset + data.length, data);
  }

  @override
  Future<String> flashMd5(int addr, int size) async => md5.convert(Uint8List.sublistView(flash, addr, addr + size)).toString();

  @override
  Future<void> eraseRegion(int offset, int size) async => flash.fillRange(offset, offset + size, 0xFF);
}

class _NoTransport extends EspTransport {
  @override
  Stream<List<int>> get input => const Stream.empty();
  @override
  Future<void> write(Uint8List data) async {}
}

/// 4 MB of erased flash with [bootloader] at the S3's offset (0) and
/// [table] at [tableOffset].
Uint8List flashWith({Uint8List? bootloader, PartitionTable? table, int tableOffset = 0x8000}) {
  final flash = Uint8List(0x400000)..fillRange(0, 0x400000, 0xFF);
  if (bootloader != null) flash.setRange(0, bootloader.length, bootloader);
  if (table != null) {
    final binary = table.toBinary();
    flash.setRange(tableOffset, tableOffset + binary.length, binary);
  }
  return flash;
}

void main() {
  group('BootloaderDescription', () {
    test('reads the description and the partition table offset it records', () {
      final d = BootloaderDescription.fromImageOrNull(bootloaderImage(EspChip.esp32s3, tableOffset: 0x10000))!;
      expect(d.version, 7);
      expect(d.secureVersion, 2);
      expect(d.idfVersion, 'v5.5.1');
      expect(d.dateTime, 'Nov 20 2026 10:00:00');
      expect(d.partitionTableOffset, 0x10000);
    });

    test('is absent from an image without one', () {
      expect(BootloaderDescription.fromImageOrNull(bootloaderImage(EspChip.esp32s3, description: false)), isNull);
      expect(BootloaderDescription.fromImageOrNull(Uint8List(16)), isNull);
    });
  });

  group('recorded offset', () {
    test('of a bootloader file, at its chip\'s offset', () {
      expect(partitionTableOffsetOfBootloader(bootloaderImage(EspChip.esp32s3, tableOffset: 0x10000)), 0x10000);
      expect(partitionTableOffsetOfBootloader(bootloaderImage(EspChip.esp32, tableOffset: 0x9000)), 0x9000);
      expect(partitionTableOffsetOfBootloader(bootloaderImage(EspChip.esp32s3)), isNull, reason: 'records none');
      expect(partitionTableOffsetOfBootloader(bootloaderImage(EspChip.esp32s3, description: false)), isNull);
      expect(partitionTableOffsetOfBootloader(Uint8List.fromList([1, 2, 3])), isNull);
    });

    test("that can't be a table's is refused", () {
      expect(() => partitionTableOffsetOfBootloader(bootloaderImage(EspChip.esp32s3, tableOffset: 0x10800)), throwsA(isA<IdfToolException>()));
      // At or below the bootloader itself.
      expect(() => partitionTableOffsetOfBootloader(bootloaderImage(EspChip.esp32, tableOffset: 0x1000)), throwsA(isA<IdfToolException>()));
      expect(() => partitionTableOffsetRecordedBy(bootloaderImage(EspChip.esp32s3, tableOffset: 0x400000), 0, limit: 0x400000),
          throwsA(isA<IdfToolException>()));
    });

    test('of a whole-flash image, by the bootloader at the offset its chip boots from', () {
      final s3 = flashWith(bootloader: bootloaderImage(EspChip.esp32s3, tableOffset: 0x10000));
      expect(partitionTableOffsetOfImage(s3), 0x10000);
      final esp32 = Uint8List(0x20000)..fillRange(0, 0x20000, 0xFF);
      final bl = bootloaderImage(EspChip.esp32, tableOffset: 0xa000);
      esp32.setRange(0x1000, 0x1000 + bl.length, bl);
      expect(partitionTableOffsetOfImage(esp32), 0xa000);
      expect(partitionTableOffsetOfImage(flashWith(bootloader: bootloaderImage(EspChip.esp32s3))), isNull);
      expect(partitionTableOffsetOfImage(Uint8List(0x10)), isNull);
    });
  });

  group('checkTableOffset', () {
    test('passes where the bootloader records nothing, or the same', () {
      checkTableOffset(0x8000, null, 'x', writing: true);
      checkTableOffset(0x10000, 0x10000, 'x', writing: true);
    });

    test('warns on a read elsewhere, refuses a write unless forced', () {
      final warnings = <String>[];
      checkTableOffset(0x8000, 0x10000, '--partition-table-offset', writing: false, warn: warnings.add);
      expect(warnings.single, contains('reading 0x8000'));
      expect(() => checkTableOffset(0x8000, 0x10000, 'x', writing: true), throwsA(isA<IdfToolException>()));
      checkTableOffset(0x8000, 0x10000, 'x', writing: true, force: true, warn: warnings.add);
      expect(warnings.last, contains('forced'));
    });

    test("checks a table's own partition_table row", () {
      final table = PartitionTable.fromCsv('pt, partition_table, primary, 0x8000, 4K\n$layout');
      expect(() => checkTableRow(table, 0x10000, writing: true), throwsA(isA<IdfToolException>()));
      checkTableRow(table, 0x8000, writing: true);
      checkTableRow(csvTable(0x8000), 0x10000, writing: true); // no row of its own
    });
  });

  group('bundles', () {
    test("lay a CSV out for where the bundle's bootloader records the table", () {
      // A layout with blank offsets shows where it was laid out.
      final withCsv = readBundle(
          _zip({'partition_table.csv': layout.codeUnits, 'bootloader.bin': bootloaderImage(EspChip.esp32s3, tableOffset: 0x10000)}));
      expect(withCsv.recordedPartitionTableOffset, 0x10000);
      expect(withCsv.partitionTableOffset, 0x10000);
      expect(withCsv.table!.findByName('nvs')!.offset, 0x11000);
      final noBootloader = readBundle(_zip({'partition_table.csv': layout.codeUnits}), partitionTableOffset: 0x9000);
      expect(noBootloader.table!.findByName('nvs')!.offset, 0xa000);
      expect(noBootloader.recordedPartitionTableOffset, isNull);
    });

    test('whose bootloader moves the table must write one there', () {
      final device = csvTable(0x8000);
      final moved = FlashBundle.fromZip(_zip({
        'partition_table.csv': layout.codeUnits,
        'bootloader.bin': bootloaderImage(EspChip.esp32s3, tableOffset: 0x10000),
      }));
      final check = checkBundle(moved, device, deviceTableOffset: 0x8000, tableOffset: 0x10000);
      expect(check.tableMoves, isTrue);
      expect(check.tableMatches, isFalse);
      expect(check.tableChanges, isTrue);
      expect(check.differences.first.describe(), 'moved 0x8000 → 0x10000');
      expect(check.canKeepLayout, isFalse);
      expect(check.automaticChoice, TableChoice.update);

      final noTable = FlashBundle.fromZip(_zip({'bootloader.bin': bootloaderImage(EspChip.esp32s3, tableOffset: 0x10000)}));
      expect(checkBundle(noTable, device, deviceTableOffset: 0x8000, tableOffset: 0x10000).blocker, contains('carries no table'));
      expect(checkBundle(noTable, device, deviceTableOffset: 0x10000, tableOffset: 0x10000).blocker, isNull);
    });
  });

  group('IdfDevice', () {
    test('reads the table where its bootloader records it', () async {
      final loader = FakeLoader(flashWith(
          bootloader: bootloaderImage(EspChip.esp32s3, tableOffset: 0x10000), table: csvTable(0x10000), tableOffset: 0x10000));
      final device = await IdfDevice.open(loader);
      expect(device.recordedPartitionTableOffset, 0x10000);
      expect(device.partitionTableOffset, 0x10000);
      expect((await device.partitionTable()).findByName('nvs')!.offset, 0x11000);
      expect((await device.resolver()).bootloaderEntry!.size, 0x10000);
    });

    test('falls back to 0x8000 when the bootloader records nothing', () async {
      final device = await IdfDevice.open(FakeLoader(flashWith(bootloader: bootloaderImage(EspChip.esp32s3), table: csvTable(0x8000))));
      expect(device.recordedPartitionTableOffset, isNull);
      expect(device.partitionTableOffset, 0x8000);
      expect(await device.partitionTable(), hasLength(2));
    });

    test('finds the offset on its first table read', () async {
      final loader = FakeLoader(flashWith(
          bootloader: bootloaderImage(EspChip.esp32s3, tableOffset: 0x10000), table: csvTable(0x10000), tableOffset: 0x10000));
      final device = IdfDevice(loader);
      expect(await device.partitionTable(), hasLength(2));
      expect(device.partitionTableOffset, 0x10000);
    });

    test('says erased flash is erased, not an empty table', () async {
      final device = await IdfDevice.open(FakeLoader(flashWith(bootloader: bootloaderImage(EspChip.esp32s3, tableOffset: 0x10000))));
      expect(device.partitionTable(),
          throwsA(isA<IdfToolException>().having((e) => e.message, 'message', contains('the flash there is erased'))));
    });

    test('an explicit offset elsewhere is read with a warning, written only by force', () async {
      final warnings = <String>[];
      final loader = FakeLoader(flashWith(
          bootloader: bootloaderImage(EspChip.esp32s3, tableOffset: 0x10000), table: csvTable(0x8000), tableOffset: 0x8000));
      final device = await IdfDevice.open(loader, partitionTableOffset: 0x8000, warn: warnings.add);
      expect(device.partitionTableOffset, 0x8000);
      expect(warnings.single, contains('records 0x10000'));
      expect(await device.partitionTable(), hasLength(2));
      expect(() => device.writePartitionTable(csvTable(0x8000)), throwsA(isA<IdfToolException>()));
      await device.writePartitionTable(csvTable(0x8000), force: true);
      expect(loader.writes, [0x8000]);
    });

    test('writes a table where a new bootloader will read it, and follows the bootloader once written', () async {
      final loader = FakeLoader(flashWith(bootloader: bootloaderImage(EspChip.esp32s3), table: csvTable(0x8000)));
      final device = await IdfDevice.open(loader);
      final bootloader = bootloaderImage(EspChip.esp32s3, tableOffset: 0x10000, segmentLength: 0x8000);
      await device.writePartitionTable(csvTable(0x10000), bootloader: bootloader);
      expect(loader.writes, [0x10000]);
      expect(device.partitionTableOffset, 0x10000);
      // The bootloader region now runs up to the moved table, so the bigger bootloader fits.
      await device.writePartition('bootloader', bootloader);
      expect(device.recordedPartitionTableOffset, 0x10000);
      expect(device.partitionTableOffset, 0x10000);
    });

    test('writeImage takes the table where the image\'s bootloader records it', () async {
      final image = flashWith(
          bootloader: bootloaderImage(EspChip.esp32s3, tableOffset: 0x10000), table: csvTable(0x10000), tableOffset: 0x10000);
      final loader = FakeLoader(flashWith(bootloader: bootloaderImage(EspChip.esp32s3), table: csvTable(0x8000)));
      final device = await IdfDevice.open(loader);
      await device.writeImage(Uint8List.sublistView(image, 0, 0x20000), erase: false);
      expect(device.partitionTableOffset, 0x10000);
      expect(device.recordedPartitionTableOffset, 0x10000);
      expect((await device.partitionTable(refresh: true)).findByName('nvs')!.offset, 0x11000);
    });
  });

  group('runFlashBundle', () {
    test("writes the table where the bundle's bootloader moves it, even when the layout matches", () async {
      final loader = FakeLoader(flashWith(bootloader: bootloaderImage(EspChip.esp32s3), table: csvTable(0x8000)));
      final device = await IdfDevice.open(loader);
      // The same layout, but explicit offsets so it matches the device's wherever the table goes.
      final table = csvTable(0x10000);
      final moved = FlashBundle.fromZip(_zip({
        'partition_table.csv': table.toCsv().codeUnits,
        'bootloader.bin': bootloaderImage(EspChip.esp32s3, tableOffset: 0x10000),
      }));
      final check = await checkBundleOnDevice(device, moved);
      expect(check.tableMoves, isTrue);
      final log = <String>[];
      await runFlashBundle(device, moved, log: log.add);
      expect(log.first, 'partition table written at 0x10000');
      expect(loader.writes.first, 0x10000);
      expect(PartitionTable.fromBinary(Uint8List.sublistView(loader.flash, 0x10000, 0x11000)), hasLength(2));
      expect(device.partitionTableOffset, 0x10000);
    });

    test('lays a bundle CSV out for where the device reads its table', () async {
      final loader = FakeLoader(flashWith(
          bootloader: bootloaderImage(EspChip.esp32s3, tableOffset: 0x10000), table: csvTable(0x10000), tableOffset: 0x10000));
      final device = await IdfDevice.open(loader);
      final bundle = FlashBundle.fromZip(_zip({'partition_table.csv': layout.codeUnits}));
      expect(bundle.contents.table!.findByName('nvs')!.offset, 0x9000, reason: 'laid out offline for 0x8000');
      final check = await checkBundleOnDevice(device, bundle);
      expect(check.tableMatches, isTrue);
      final log = <String>[];
      await runFlashBundle(device, bundle, log: log.add);
      expect(log.single, 'partition table already matches; not written');
      expect(loader.writes, isEmpty);
    });
  });
}

/// A ZIP of [files] as given.
Uint8List _zip(Map<String, List<int>> files) => encodeBundle(files: {for (final e in files.entries) e.key: Uint8List.fromList(e.value)});
