/// Where the partition table is: where the bootloader's description records
/// it, in the `partition_table_offset` field espressif/esp-idf#19102
/// proposes for `esp_bootloader_desc_t`
/// (https://github.com/espressif/esp-idf/pull/19102). A bootloader without
/// the field leaves it 0, and the table is then at an explicit offset or
/// ESP-IDF's default, 0x8000, as before.
///
/// A table placed elsewhere than the bootloader records is one the
/// bootloader won't find: writing it is refused unless forced, reading it
/// only warned about.
library;

// TODO: espressif/esp-idf#19102 is not merged, so this is experimental: the
// field may move or change before it is, and stock bootloaders all record 0.
// https://github.com/espressif/esp-idf/pull/19102

import 'dart:typed_data';

import 'package:esptool/esptool.dart';

import 'device.dart';
import 'int_literal.dart';
import 'partition_table.dart';

/// Marks what is shown to a user about a recorded offset as experimental
/// while espressif/esp-idf#19102 is unmerged.
const recordedTableOffsetNote = 'experimental, espressif/esp-idf#19102';

/// Every flash offset a chip's ROM boots its bootloader from, lowest first.
final List<int> bootloaderOffsets = (EspChip.values.map((c) => c.bootloaderFlashOffset).toSet().toList()..sort());

/// Past this, no write can reach a bootloader's description.
final int bootloaderDescriptionsEnd = bootloaderOffsets.last + BootloaderDescription.imageEnd;

/// The flash offset the chip [bootloader] is built for boots it from, or
/// `null` if it isn't an image for a known chip.
int? bootloaderOffsetOf(Uint8List bootloader) {
  if (bootloader.length < ImageHeader.size || bootloader[0] != ImageHeader.magic) return null;
  final chipId = ByteData.sublistView(bootloader).getUint16(12, Endian.little);
  return EspChip.values.where((c) => c.imageChipId == chipId).firstOrNull?.bootloaderFlashOffset;
}

/// Where [bootloader], an image flashed at [offset], records its partition
/// table, or `null` if it records none. Throws [IdfToolException] if what it
/// records can't be a partition table's offset: one on a sector boundary,
/// past the bootloader, and with the table below [limit] (the flash's or
/// image's end) when given.
int? partitionTableOffsetRecordedBy(Uint8List bootloader, int offset, {int? limit}) {
  final recorded = BootloaderDescription.fromImageOrNull(bootloader)?.partitionTableOffset ?? 0;
  if (recorded == 0) return null;
  if (recorded % 0x1000 != 0 || recorded <= offset || (limit != null && recorded + PartitionTable.size > limit)) {
    throw IdfToolException("The bootloader at ${hex(offset)} records partition table offset ${hex(recorded)}, which can't be one");
  }
  return recorded;
}

/// Where the bootloader of [bootloader], a file to be flashed at its chip's
/// bootloader offset, records the partition table; `null` if it records
/// none or isn't an image for a known chip.
int? partitionTableOffsetOfBootloader(Uint8List bootloader) {
  final offset = bootloaderOffsetOf(bootloader);
  return offset == null ? null : partitionTableOffsetRecordedBy(bootloader, offset);
}

/// Where the bootloader in the whole-flash [image] records the partition
/// table: the first bootloader offset holding an image for a chip that boots
/// from there. `null` if none records one.
int? partitionTableOffsetOfImage(Uint8List image) {
  for (final offset in bootloaderOffsets) {
    if (offset >= image.length) break;
    final bootloader = Uint8List.sublistView(image, offset);
    if (bootloaderOffsetOf(bootloader) != offset) continue;
    return partitionTableOffsetRecordedBy(bootloader, offset, limit: image.length);
  }
  return null;
}

/// Where the bootloader at [bootloaderOffset] on the device [loader] is
/// connected to records the partition table, or `null` if it records none.
/// [flashSize] bounds what it may record.
Future<int?> readRecordedPartitionTableOffset(EspLoader loader, int bootloaderOffset, {int? flashSize}) async {
  final data = await loader.readFlash(bootloaderOffset, BootloaderDescription.imageEnd);
  if (bootloaderOffsetOf(data) != bootloaderOffset) return null;
  return partitionTableOffsetRecordedBy(data, bootloaderOffset, limit: flashSize);
}

/// Check a table [declared] at an offset by [what] against where the
/// bootloader [recorded] it (`null` if it records none, and anything goes).
/// A table written elsewhere is one the bootloader won't find: refused
/// unless [force], when [warn] is told instead. Reading one elsewhere is
/// only warned about, as a leftover table can be worth a look.
void checkTableOffset(int declared, int? recorded, String what,
    {required bool writing, bool force = false, void Function(String message)? warn}) {
  if (recorded == null || declared == recorded) return;
  final mismatch = '$what puts the partition table at ${hex(declared)}, but the bootloader records ${hex(recorded)}';
  if (!writing) {
    warn?.call('$mismatch; reading ${hex(declared)}');
  } else if (!force) {
    throw IdfToolException('$mismatch, so it would not find the table there. Force it to write it anyway.');
  } else {
    warn?.call('$mismatch (writing it anyway, forced)');
  }
}

/// [checkTableOffset] for [table]'s own primary `partition_table` row, if it
/// has one.
void checkTableRow(PartitionTable table, int? recorded,
    {required bool writing, bool force = false, void Function(String message)? warn}) {
  final row = table.where((p) => p.isPrimaryPartitionTable).firstOrNull;
  if (row != null) checkTableOffset(row.offset, recorded, "The table's ${row.name} row", writing: writing, force: force, warn: warn);
}

/// Whether [data] is all erased flash (0xFF).
bool isErased(Uint8List data) => data.every((b) => b == 0xFF);
