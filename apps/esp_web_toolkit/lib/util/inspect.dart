import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:esptool/esptool.dart';
import 'package:idftool/idftool.dart';

import 'files.dart';
import 'format.dart';

/// What a file turned out to be.
enum FileKind {
  partitionTable('Partition table'),
  flashImage('Flash image'),
  appImage('App image'),
  bootloaderImage('Bootloader image'),
  bundle('Bundle'),
  nvsImage('NVS image'),
  nvsCsv('NVS CSV'),
  fsImage('Filesystem image'),
  fileZip('ZIP of files'),
  unknown('Unknown');

  const FileKind(this.label);
  final String label;
}

/// A file opened offline: its kind, a one-line summary, the CLI-style
/// report, and whichever parsed form the actions need.
class Inspected {
  const Inspected({
    required this.kind,
    required this.file,
    required this.summary,
    required this.report,
    this.table,
    this.bootloader,
    this.nvs,
    this.volume,
    this.archive,
    this.problem,
  });

  final FileKind kind;
  final PickedFile file;
  final String summary;
  final String report;
  final PartitionTable? table;

  /// For a flash image: the chip its bootloader targets, which fixes where
  /// the bootloader sits.
  final EspChip? bootloader;
  final NvsImage? nvs;
  final FsVolume? volume;
  final Archive? archive;

  /// A table's verification failure, if any.
  final String? problem;

  String get stem => file.name.contains('.') ? file.name.substring(0, file.name.lastIndexOf('.')) : file.name;
}

/// Work out what [file] is and describe it. Nothing here needs a device;
/// the partition table is where the file's bootloader records it, else at
/// its default offset.
Future<Inspected> inspectFile(PickedFile file) async {
  final bytes = file.bytes;
  const tableSize = PartitionTable.size;

  if (bytes.length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4B && bytes[2] == 0x03 && bytes[3] == 0x04) {
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    final csv = archive.find('partition_table.csv');
    if (csv != null) {
      final bootloader = archive.find('bootloader.bin')?.readBytes();
      final recorded = bootloader == null ? null : partitionTableOffsetOfBootloader(bootloader);
      final tableOffset = recorded ?? PartitionTable.defaultOffset;
      final table = parsePartitionTableCsv(PartitionTable.decodeCsv(csv.readBytes()!), source: '${file.name}/partition_table.csv', partitionTableOffset: tableOffset);
      Future<Uint8List> read(int offset, int length) async {
        final p = table.where((p) => p.offset == offset).firstOrNull;
        final entry = p == null ? null : archive.find('${p.name}.bin');
        final out = Uint8List(length)..fillRange(0, length, 0xFF);
        if (entry != null) {
          final data = entry.readBytes()!;
          out.setRange(0, data.length.clamp(0, length), data);
        }
        return out;
      }

      final bins = archive.files.where((f) => f.isFile && f.name.endsWith('.bin')).map((f) => f.name).toList()..sort();
      return Inspected(
        kind: FileKind.bundle,
        file: file,
        summary: '${bins.length} partition image${bins.length == 1 ? '' : 's'}: ${bins.join(', ')}'
            '${recorded == null ? '' : '; its bootloader reads the partition table at ${recorded.hex} ($recordedTableOffsetNote)'}',
        report: await formatTableWithApps(table, read),
        table: table,
        archive: archive,
        problem: _verify(table, tableOffset),
      );
    }
    final files = archive.files.where((f) => f.isFile).toList();
    final total = files.fold(0, (n, f) => n + f.size);
    return Inspected(
      kind: FileKind.fileZip,
      file: file,
      summary: '${files.length} file${files.length == 1 ? '' : 's'}, ${total.bytesString} — can be built into a filesystem image',
      report: [for (final f in files) '${f.size.toString().padLeft(10)}  ${f.name}'].join('\n'),
      archive: archive,
    );
  }

  final text = _asText(bytes);
  if (text != null) {
    final first = LineSplitter.split(text).map((l) => l.trim()).where((l) => l.isNotEmpty && !l.startsWith('#')).firstOrNull ?? '';
    if (first.toLowerCase().startsWith('key,type,encoding')) {
      final lines = LineSplitter.split(text).toList();
      final rows = lines.where((l) => l.trim().isNotEmpty && !l.trim().startsWith('#')).length - 1;
      return Inspected(
        kind: FileKind.nvsCsv,
        file: file,
        summary: '$rows row${rows == 1 ? '' : 's'} — can be built into an NVS image',
        report: lines.take(200).join('\n') + (lines.length > 200 ? '\n… ${lines.length - 200} more lines' : ''),
      );
    }
    final table = parsePartitionTableCsv(text, source: file.name);
    return _tableResult(file, table, FileKind.partitionTable);
  }

  if (PartitionTable.isBinary(bytes)) {
    return _tableResult(file, PartitionTable.fromBinary(bytes), FileKind.partitionTable);
  }

  if (looksLikeNvsBinary(bytes)) {
    final nvs = parseNvs(bytes);
    final used = nvs.pages.where((p) => !p.isUninit).length;
    if (nvs.looksEncrypted) {
      return Inspected(
        kind: FileKind.nvsImage,
        file: file,
        summary: 'Encrypted NVS, $used/${nvs.pages.length} pages used — open it in Data and enter its HMAC key to read it',
        report: formatNvsPages(nvs),
        nvs: nvs,
      );
    }
    return Inspected(
      kind: FileKind.nvsImage,
      file: file,
      summary: '${nvs.entries.length} entries in ${nvs.namespaces.length} namespace${nvs.namespaces.length == 1 ? '' : 's'}, '
          'NVS v${nvs.version == NvsVersion.v1 ? 1 : 2}, $used/${nvs.pages.length} pages used'
          '${nvs.errors.isEmpty ? '' : ', ${nvs.errors.length} problem${nvs.errors.length == 1 ? '' : 's'}'}',
      report: [
        if (nvs.errors.isNotEmpty) ...[for (final e in nvs.errors) 'Warning: $e', ''],
        formatNvsPages(nvs),
        '',
        formatNvsEntries(nvs.entries),
      ].join('\n'),
      nvs: nvs,
    );
  }

  // A flash image: its table is where its bootloader records it, else at 0x8000.
  final chip = _bootloaderChip(bytes);
  int? recorded;
  String? recordProblem;
  try {
    recorded = partitionTableOffsetOfImage(bytes);
  } on IdfToolException catch (e) {
    recordProblem = e.message;
  }
  final tableOffset = recorded ?? PartitionTable.defaultOffset;
  if (bytes.length > tableOffset + tableSize) {
    PartitionTable? table;
    try {
      table = PartitionTable.fromBinary(Uint8List.sublistView(bytes, tableOffset, tableOffset + tableSize)).requireNotEmpty('image');
    } catch (_) {
      // not a flash image
    }
    if (table != null) {
      Future<Uint8List> read(int offset, int length) async {
        final out = Uint8List(length)..fillRange(0, length, 0xFF);
        if (offset < bytes.length) out.setRange(0, length.clamp(0, bytes.length - offset), bytes, offset);
        return out;
      }

      final report = StringBuffer();
      if (chip != null) {
        final blBytes = Uint8List.sublistView(bytes, chip.bootloaderFlashOffset, tableOffset);
        final bl = ImageMetadata.fromBytes(blBytes);
        report
          ..writeln('Bootloader at ${chip.bootloaderFlashOffset.hex}:')
          ..writeln(formatImageInfo(bl, bytes: blBytes).split('\n').map((l) => '  $l').join('\n'))
          ..writeln();
      } else {
        report.writeln('No bootloader recognised at ${bootloaderOffsets.map((o) => o.hex).join(' or ')}.\n');
      }
      if (recordProblem != null) report.writeln('Warning: $recordProblem; reading the partition table at ${tableOffset.hex}\n');
      report.writeln('Partition table at ${tableOffset.hex}${recorded == null ? '' : ', where the bootloader records it ($recordedTableOffsetNote)'}:\n');
      report.write(await formatTableWithApps(table, read));
      return Inspected(
        kind: FileKind.flashImage,
        file: file,
        summary: '${bytes.length.bytesString}, ${table.length} partitions${chip == null ? '' : ', ${chip.name} bootloader'}'
            '${recorded == null ? '' : ', partition table at ${recorded.hex} ($recordedTableOffsetNote)'}',
        report: report.toString(),
        table: table,
        bootloader: chip,
        problem: _verify(table, tableOffset),
      );
    }
  }

  if (bytes.isNotEmpty && bytes[0] == ImageHeader.magic) {
    final image = ImageMetadata.fromBytes(bytes);
    final app = image.appDescription;
    final description = app == null ? BootloaderDescription.fromImageOrNull(bytes) : null;
    final reads = (description?.partitionTableOffset ?? 0) == 0 ? '' : ', reads the partition table at ${description!.partitionTableOffset.hex} ($recordedTableOffsetNote)';
    return Inspected(
      kind: app == null ? FileKind.bootloaderImage : FileKind.appImage,
      file: file,
      summary: app == null
          ? '${image.header.chipId?.name ?? 'unknown chip'}, ${image.segments.length} segments, ${bytes.length.bytesString}$reads'
          : '${app.projectName} ${app.version} for ${image.header.chipId?.name ?? 'unknown chip'}, IDF ${app.idfVersion}, ${bytes.length.bytesString}',
      report: formatImageInfo(image, bytes: bytes),
    );
  }

  final fsType = FsType.detect(bytes);
  if (fsType != null) {
    final volume = FsVolume.mount(bytes, type: fsType);
    final files = volume.entries.where((e) => !e.isDir).length;
    return Inspected(
      kind: FileKind.fsImage,
      file: file,
      summary: '${fsType.label}, ${volume.describe()}, $files file${files == 1 ? '' : 's'}'
          '${volume.errors.isEmpty ? '' : ', ${volume.errors.length} problem${volume.errors.length == 1 ? '' : 's'}'}',
      report: [
        if (volume.errors.isNotEmpty) ...[for (final e in volume.errors) 'Warning: $e', ''],
        formatFsListing(volume.entries),
      ].join('\n'),
      volume: volume,
    );
  }

  return Inspected(
    kind: FileKind.unknown,
    file: file,
    summary: '${bytes.length.bytesString} — not a partition table, image, bundle, NVS or filesystem image',
    report: _hexDump(bytes, 256),
  );
}

Inspected _tableResult(PickedFile file, PartitionTable table, FileKind kind) => Inspected(
      kind: kind,
      file: file,
      summary: '${table.length} partitions, ${table.last.end.bytesString} of flash used',
      report: table.format(),
      table: table,
      problem: _verify(table),
    );

String? _verify(PartitionTable table, [int tableOffset = PartitionTable.defaultOffset]) {
  try {
    table.verify(partitionTableOffset: tableOffset);
    return null;
  } catch (e) {
    return '$e';
  }
}

/// The chip whose bootloader sits at the start of [image], if the bytes at
/// that chip's bootloader offset parse as an image built for it.
EspChip? _bootloaderChip(Uint8List image) {
  for (final offset in bootloaderOffsets) {
    if (offset >= image.length) continue;
    final meta = ImageMetadata.fromBytesOrNull(Uint8List.sublistView(image, offset));
    final chipId = meta?.header.chipId?.value;
    if (chipId == null) continue;
    final chip = EspChip.values.where((c) => c.imageChipId == chipId && c.bootloaderFlashOffset == offset).firstOrNull;
    if (chip != null) return chip;
  }
  return null;
}

/// [bytes] as text if it decodes as UTF-8 and looks printable.
String? _asText(Uint8List bytes) {
  if (bytes.isEmpty) return null;
  final String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    return null;
  }
  final sample = text.length > 512 ? text.substring(0, 512) : text;
  final printable = sample.runes.every((r) => r == 0x09 || r == 0x0A || r == 0x0D || (r >= 0x20 && r != 0x7F));
  return printable ? text : null;
}

String _hexDump(Uint8List bytes, int max) {
  final out = StringBuffer();
  for (var i = 0; i < bytes.length && i < max; i += 16) {
    final row = bytes.sublist(i, (i + 16).clamp(0, bytes.length));
    out.writeln('${i.toRadixString(16).padLeft(8, '0')}  ${row.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ').padRight(47)}  '
        '${String.fromCharCodes(row.map((b) => b >= 0x20 && b < 0x7F ? b : 0x2E))}');
  }
  if (bytes.length > max) out.writeln('… ${bytes.length - max} more bytes');
  return out.toString().trimRight();
}
