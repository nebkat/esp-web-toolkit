// Reads its fixtures from disk.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:esptool/esptool.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idftool/idftool.dart';
import 'package:esp_web_toolkit/util/inspect.dart';

void main() {
  final fixtures = Directory('../../packages/idftool/test/fixtures');
  final tableCsv = File('${fixtures.path}/partitions.csv').readAsBytesSync();
  final nvsCsv = File('${fixtures.path}/nvs.csv').readAsBytesSync();

  Future<Inspected> inspect(String name, Uint8List bytes) => inspectFile((name: name, bytes: bytes));

  test('partition table CSV', () async {
    final i = await inspect('partitions.csv', tableCsv);
    expect(i.kind, FileKind.partitionTable);
    expect(i.table, isNotNull);
    expect(i.report, contains('nvs'));
  });

  test('partition table binary', () async {
    final table = parsePartitionTableCsv(String.fromCharCodes(tableCsv), source: 'x');
    final i = await inspect('partitions.bin', table.toBinary());
    expect(i.kind, FileKind.partitionTable);
    expect(i.table!.length, table.length);
  });

  test('NVS CSV and generated image', () async {
    final csv = await inspect('nvs.csv', nvsCsv);
    expect(csv.kind, FileKind.nvsCsv);
    final image = generateNvsImage(String.fromCharCodes(nvsCsv), 0x6000);
    final i = await inspect('nvs.bin', image);
    expect(i.kind, FileKind.nvsImage);
    expect(i.nvs!.entries, isNotEmpty);
  });

  test('bundle and plain zip', () async {
    final table = parsePartitionTableCsv(String.fromCharCodes(tableCsv), source: 'x');
    final bundle = Archive()
      ..add(ArchiveFile.string('partition_table.csv', table.toCsv()))
      ..add(ArchiveFile.bytes('nvs.bin', generateNvsImage(String.fromCharCodes(nvsCsv), 0x6000)));
    final b = await inspect('bundle.zip', ZipEncoder().encodeBytes(bundle));
    expect(b.kind, FileKind.bundle);
    expect(b.summary, contains('nvs.bin'));

    final files = Archive()..add(ArchiveFile.string('hello.txt', 'hi'));
    final z = await inspect('files.zip', ZipEncoder().encodeBytes(files));
    expect(z.kind, FileKind.fileZip);
  });

  test('flash image with table at 0x8000', () async {
    final table = parsePartitionTableCsv(String.fromCharCodes(tableCsv), source: 'x');
    final image = Uint8List(0x10000)..fillRange(0, 0x10000, 0xFF);
    image.setRange(0x8000, 0x8000 + table.toBinary().length, table.toBinary());
    final i = await inspect('flash.bin', image);
    expect(i.kind, FileKind.flashImage);
    expect(i.bootloader, isNull);
  });

  test('flash image whose bootloader moves the table', () async {
    // An ESP32-S3 bootloader (booted from 0x0) whose description records the table at 0x10000.
    final bootloader = Uint8List(0x130);
    final view = ByteData.sublistView(bootloader);
    bootloader[0] = ImageHeader.magic;
    bootloader[1] = 1;
    view.setUint16(12, EspChip.esp32s3.imageChipId, Endian.little);
    view.setUint32(ImageHeader.size + 4, 0x100, Endian.little);
    bootloader[BootloaderDescription.imageOffset] = BootloaderDescription.magic;
    view.setUint32(BootloaderDescription.imageOffset + 64, 0x10000, Endian.little);
    var checksum = ImageMetadata.checksumMagic;
    for (final b in Uint8List.sublistView(bootloader, ImageHeader.size + 8, ImageHeader.size + 8 + 0x100)) {
      checksum ^= b;
    }
    bootloader[bootloader.length - 1] = checksum;
    final table = PartitionTable.fromCsv('nvs, data, nvs, , 0x6000\nfactory, app, factory, , 1M\n', partitionTableOffset: 0x10000);
    final image = Uint8List(0x20000)..fillRange(0, 0x20000, 0xFF);
    image.setRange(0, bootloader.length, bootloader);
    image.setRange(0x10000, 0x10000 + table.toBinary().length, table.toBinary());

    final i = await inspect('flash.bin', image);
    expect(i.kind, FileKind.flashImage);
    expect(i.bootloader, EspChip.esp32s3);
    expect(i.table!.findByName('nvs')!.offset, 0x11000);
    expect(i.summary, contains('partition table at 0x10000'));
    expect(i.report, contains('Partition table:  0x10000'));
    expect(i.problem, isNull);

    final b = await inspect('bootloader.bin', bootloader);
    expect(b.kind, FileKind.bootloaderImage);
    expect(b.summary, contains('reads the partition table at 0x10000'));
  });

  test('unknown bytes', () async {
    final i = await inspect('junk.bin', Uint8List.fromList([1, 2, 3, 4, 5]));
    expect(i.kind, FileKind.unknown);
  });
}
