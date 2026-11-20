import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:esptool/esptool.dart';

import 'flash/differential.dart';
import 'fs/fs.dart';
import 'int_literal.dart';
import 'nvs/nvs.dart';
import 'otadata.dart';
import 'partition_slice.dart';
import 'partition_table.dart';
import 'table_offset.dart';

/// An error in what was asked of the device (bad input, missing partition),
/// as opposed to a protocol failure from the loader.
class IdfToolException implements Exception {
  IdfToolException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Byte progress of a running device operation.
typedef ProgressCallback = void Function(String label, int done, int total);

/// A connected ESP-IDF device: python idftool's `State`/`Loaded` and the
/// device-facing command bodies, on top of a connected [EspLoader]
/// (preferably with the stub running — reads need it on everything but the
/// original ESP32).
///
/// The partition table is where the device's bootloader records it (see
/// `table_offset.dart`), else at [PartitionTable.defaultOffset], unless an
/// explicit offset is given; [readPartitionTableOffset] finds it, and the
/// first read of the table does so if nothing has yet. The table is read
/// from flash on first use and cached; supply one with [usePartitionTable]
/// to work against a table that isn't on the device yet (a CSV about to be
/// flashed, or a bundle's).
class IdfDevice {
  /// [partitionTableOffset] overrides where the bootloader records the
  /// table (python idftool's `--partition-table-offset`). [warn] hears about
  /// a table read away from where the bootloader records it, or written
  /// there by force.
  IdfDevice(
    this.loader, {
    int? partitionTableOffset,
    this.partitionTableSize = PartitionTable.size,
    int? primaryBootloaderOffset,
    this.flashSize,
    this.warn,
  })  : explicitPartitionTableOffset = partitionTableOffset,
        _partitionTableOffset = partitionTableOffset ?? PartitionTable.defaultOffset,
        primaryBootloaderOffset = primaryBootloaderOffset ?? loader.chip?.bootloaderFlashOffset;

  /// Make an [IdfDevice] and find where its partition table is
  /// ([readPartitionTableOffset]).
  static Future<IdfDevice> open(
    EspLoader loader, {
    int? partitionTableOffset,
    int partitionTableSize = PartitionTable.size,
    int? primaryBootloaderOffset,
    int? flashSize,
    void Function(String message)? warn,
  }) async {
    final device = IdfDevice(loader,
        partitionTableOffset: partitionTableOffset,
        partitionTableSize: partitionTableSize,
        primaryBootloaderOffset: primaryBootloaderOffset,
        flashSize: flashSize,
        warn: warn);
    await device.readPartitionTableOffset();
    return device;
  }

  final EspLoader loader;
  final int partitionTableSize;

  /// The offset the table was asked to be at, overriding the bootloader's
  /// record; `null` to go by the record.
  final int? explicitPartitionTableOffset;

  /// The flash size, which bounds the partition table offset a bootloader may
  /// record; `null` if unknown.
  final int? flashSize;

  /// Told about a table away from where the bootloader records it.
  final void Function(String message)? warn;

  /// Where the chip's ROM expects the second-stage bootloader; `null` if the
  /// chip is unknown, in which case the virtual `bootloader` entry is absent.
  final int? primaryBootloaderOffset;

  int _partitionTableOffset;
  int? _recordedPartitionTableOffset;
  bool _partitionTableOffsetRead = false;

  /// Where the partition table is: [explicitPartitionTableOffset], else where
  /// the bootloader records it, else ESP-IDF's default. Known once
  /// [readPartitionTableOffset] has run (the first table read runs it).
  int get partitionTableOffset => _partitionTableOffset;

  /// Where the device's bootloader records the partition table, as last read;
  /// `null` if it records none, or it has not been read.
  int? get recordedPartitionTableOffset => _recordedPartitionTableOffset;

  PartitionTable? _table;
  PartitionResolver? _resolver;

  EspChip get chip => loader.chip ?? (throw IdfToolException('Loader is not connected to a chip'));

  /// Read where the device's bootloader records the partition table, and so
  /// [partitionTableOffset]. A bootloader that can't be read (the ROM loader
  /// reads flash only on the ESP32) or isn't there records nothing. Throws
  /// [IdfToolException] if it records an offset that can't be a table's.
  // TODO: experimental while espressif/esp-idf#19102 is unmerged (see table_offset.dart).
  Future<int?> readPartitionTableOffset() async {
    final bootloaderOffset = primaryBootloaderOffset;
    int? recorded;
    if (bootloaderOffset != null) {
      try {
        recorded = await readRecordedPartitionTableOffset(loader, bootloaderOffset, flashSize: flashSize);
      } on EspUnsupportedCommandException {
        recorded = null;
      }
    }
    _partitionTableOffsetRead = true;
    _recordedPartitionTableOffset = recorded;
    final offset = resolvePartitionTableOffset(recorded);
    if (offset != _partitionTableOffset) {
      _partitionTableOffset = offset;
      _table = null;
      _resolver = null;
    }
    return recorded;
  }

  /// Where a table the bootloader records at [recorded] goes:
  /// [explicitPartitionTableOffset], else [recorded], else ESP-IDF's default.
  /// An explicit offset elsewhere is checked by [checkTableOffset]: with
  /// [writing], refused unless [force].
  int resolvePartitionTableOffset(int? recorded, {bool writing = false, bool force = false}) {
    final explicit = explicitPartitionTableOffset;
    if (explicit == null) return recorded ?? PartitionTable.defaultOffset;
    checkTableOffset(explicit, recorded, 'The partition table offset given', writing: writing, force: force, warn: warn);
    return explicit;
  }

  /// The partition table in use, read from flash if not yet loaded.
  Future<PartitionTable> partitionTable({bool refresh = false}) async {
    if (_table == null || refresh) {
      if (!_partitionTableOffsetRead) await readPartitionTableOffset();
      final offset = partitionTableOffset;
      final binary = await loader.readFlash(offset, partitionTableSize);
      if (isErased(binary)) {
        throw IdfToolException('No partition table on the device at ${hex(offset)}: the flash there is erased');
      }
      final PartitionTable table;
      try {
        table = PartitionTable.fromBinary(binary);
      } on PartitionTableException catch (e) {
        throw IdfToolException('Partition table could not be loaded from flash at ${hex(offset)}: $e');
      }
      checkTableRow(table, _recordedPartitionTableOffset, writing: false, warn: warn);
      usePartitionTable(table.requireNotEmpty('the device'));
    }
    return _table!;
  }

  /// Use [table] instead of the one on the device.
  void usePartitionTable(PartitionTable table) {
    _table = table;
    _resolver = PartitionResolver.forTable(
      table,
      partitionTableOffset: partitionTableOffset,
      partitionTableSize: partitionTableSize,
      primaryBootloaderOffset: primaryBootloaderOffset,
    );
  }

  /// Resolves partition labels and `name[start:stop]` slices against the
  /// loaded table.
  Future<PartitionResolver> resolver() async {
    await partitionTable();
    return _resolver!;
  }

  // --------------------------------------------------------------------------
  // Raw partition I/O
  // --------------------------------------------------------------------------

  /// Read a partition or slice (`nvs`, `nvs[0x100:0x200]`, `0x9000`).
  Future<Uint8List> readPartition(String spec, {ProgressCallback? onProgress}) async {
    final slice = (await resolver()).slice(spec);
    return loader.readFlash(slice.address, slice.length,
        onProgress: (done, total) => onProgress?.call('Reading ${slice.partition.name}', done, total));
  }

  /// Write [data] into a partition (or at an offset within it, `name[+off]`).
  Future<WriteOutcome> writePartition(
    String spec,
    Uint8List data, {
    WriteStrategy strategy = WriteStrategy.differential,
    ProgressCallback? onProgress,
  }) async {
    final target = (await resolver()).address(spec);
    final room = target.partition.end - target.address;
    if (data.length > room) {
      throw IdfToolException('Data size ${hex(data.length)} exceeds the ${hex(room)} bytes available in '
          "partition '${target.partition.name}' at ${hex(target.address)}");
    }
    return _write(target.address, data, strategy, onProgress, target.partition.name);
  }

  /// Erase a partition or slice.
  Future<void> erasePartition(String spec) async {
    final slice = (await resolver()).slice(spec);
    await loader.eraseRegion(slice.address, slice.length);
  }

  Future<WriteOutcome> _write(
      int address, Uint8List data, WriteStrategy strategy, ProgressCallback? onProgress, String label) async {
    final outcome = await writeFlashRegion(loader, address, data,
        strategy: strategy,
        onProgress: ({required scanned, required written, required total}) =>
            onProgress?.call('Writing $label', written, total));
    if (address < bootloaderDescriptionsEnd) await _bootloaderWritten();
    return outcome;
  }

  /// A write may have replaced the bootloader, and with it where the table
  /// is. A bootloader that records nothing leaves the offset as it was: it
  /// doesn't say where its table is, and the table a bundle just wrote for
  /// it is where it was written.
  Future<void> _bootloaderWritten() async {
    final bootloaderOffset = primaryBootloaderOffset;
    if (bootloaderOffset == null) return;
    int? recorded;
    try {
      recorded = await readRecordedPartitionTableOffset(loader, bootloaderOffset, flashSize: flashSize);
    } on EspUnsupportedCommandException {
      return;
    } on IdfToolException catch (e) {
      warn?.call('$e');
      return;
    }
    _recordedPartitionTableOffset = recorded;
    if (recorded == null || explicitPartitionTableOffset != null || recorded == _partitionTableOffset) return;
    _partitionTableOffset = recorded;
    _table = null;
    _resolver = null;
  }

  // --------------------------------------------------------------------------
  // NVS
  // --------------------------------------------------------------------------

  /// The NVS partition named [name], or if [name] is `null` the first
  /// `data/nvs` partition.
  Future<PartitionDefinition> nvsPartition([String? name]) async {
    final table = await partitionTable();
    if (name != null) {
      final p = table.findByName(name) ?? (throw IdfToolException("No partition named '$name'"));
      if (!(p.isData && p.subtype == DataSubtype.nvs.value)) {
        throw IdfToolException("Partition '$name' is not an NVS partition");
      }
      return p;
    }
    return table.findByType(PartitionType.data, DataSubtype.nvs).firstOrNull ??
        (throw IdfToolException('No NVS partition found'));
  }

  /// Read and parse the NVS partition.
  ///
  /// With [keys] the partition is decrypted first (throwing [NvsError] if
  /// they don't decrypt it), so the image — [NvsImage.data] included — is
  /// plaintext.
  Future<({PartitionDefinition partition, NvsImage image})> readNvs(
      {String? name, NvsKeys? keys, ProgressCallback? onProgress}) async {
    final partition = await nvsPartition(name);
    final data = await loader.readFlash(partition.offset, partition.size,
        onProgress: (done, total) => onProgress?.call('Reading ${partition.name}', done, total));
    return (partition: partition, image: parseNvs(keys == null ? data : decryptNvs(data, keys)));
  }

  /// Apply [edits] to the NVS partition and write back only the pages that
  /// changed (a page is one flash sector, so partial writes are safe).
  /// Returns the edit result and the number of bytes written.
  ///
  /// With [keys] the partition is encrypted: it is decrypted, edited, and
  /// encrypted again, and [NvsEditResult.image] is what went to flash. The
  /// dirty pages are the same either way, since a page's ciphertext depends
  /// only on its plaintext and position.
  Future<({NvsEditResult result, int written})> editNvs(List<NvsEdit> edits,
      {String? partitionName, NvsKeys? keys, bool forceRewrite = false, ProgressCallback? onProgress}) async {
    final (partition: partition, image: image) = await readNvs(name: partitionName, keys: keys, onProgress: onProgress);
    final resolved = resolveUntypedNvsEdits(image, edits);
    var result = applyNvsEdits(image.data, resolved, forceRewrite: forceRewrite);
    if (keys != null) {
      result = NvsEditResult(
          image: encryptNvs(result.image, keys), changes: result.changes, dirtyPages: result.dirtyPages, compacted: result.compacted);
    }
    var written = 0;
    for (final (address, data) in contiguousNvsWrites(partition.offset, result.image, result.dirtyPages)) {
      await loader.writeFlash(address, data,
          onProgress: (done, total) => onProgress?.call('Writing ${partition.name}', written + done, total));
      written += data.length;
    }
    return (result: result, written: written);
  }

  /// Replace the NVS partition with [image] (e.g. from [generateNvsImage]),
  /// padded to the partition size.
  Future<WriteOutcome> writeNvs(Uint8List image,
      {String? partitionName, WriteStrategy strategy = WriteStrategy.differential, ProgressCallback? onProgress}) async {
    final partition = await nvsPartition(partitionName);
    return _write(partition.offset, fitNvsBinary(image, partition.size), strategy, onProgress, partition.name);
  }

  // --------------------------------------------------------------------------
  // Filesystems
  // --------------------------------------------------------------------------

  /// The partition named [name] if it holds a filesystem (by subtype), or
  /// with [name] `null` the first filesystem partition.
  Future<PartitionDefinition> fsPartition([String? name]) async {
    final table = await partitionTable();
    if (name != null) {
      final p = table.findByName(name) ?? (throw IdfToolException("No partition named '$name'"));
      return p;
    }
    return table.where((p) => FsType.forPartition(p) != null).firstOrNull ??
        (throw IdfToolException('No filesystem partition found'));
  }

  /// Read and mount a filesystem partition.
  Future<({PartitionDefinition partition, FsVolume volume})> readFs({String? name, FsType? type, ProgressCallback? onProgress}) async {
    final partition = await fsPartition(name);
    final image = await loader.readFlash(partition.offset, partition.size,
        onProgress: (done, total) => onProgress?.call('Reading ${partition.name}', done, total));
    return (partition: partition, volume: FsVolume.mount(image, type: type, partition: partition));
  }

  /// Flash a filesystem [image] into its partition. Not padded: a
  /// wear-levelled FAT image keeps its state in its last sectors and records
  /// its own size, so padding would corrupt it.
  Future<WriteOutcome> writeFs(Uint8List image,
      {String? partitionName, WriteStrategy strategy = WriteStrategy.differential, ProgressCallback? onProgress}) async {
    final partition = await fsPartition(partitionName);
    if (image.length > partition.size) {
      throw IdfToolException("Image size ${hex(image.length)} exceeds partition '${partition.name}' size ${hex(partition.size)}");
    }
    return _write(partition.offset, image, strategy, onProgress, partition.name);
  }

  /// Put and delete files in a filesystem partition: read it, rebuild the
  /// image with the changes (see [editFsImage]) and write it back. An
  /// erased partition starts as an empty filesystem of the partition's type.
  Future<({WriteOutcome outcome, int put, int deleted, List<String> missing})> editFs({
    String? partitionName,
    FsType? type,
    Map<String, Uint8List> put = const {},
    List<String> delete = const [],
    WriteStrategy strategy = WriteStrategy.differential,
    ProgressCallback? onProgress,
  }) async {
    final partition = await fsPartition(partitionName);
    final image = await loader.readFlash(partition.offset, partition.size,
        onProgress: (done, total) => onProgress?.call('Reading ${partition.name}', done, total));
    final t = FsType.resolve(explicit: type, partition: partition, image: image);
    final edited = editFsImage(image, type: t, size: partition.size, put: put, delete: delete);
    final outcome = await _write(partition.offset, edited.image, strategy, onProgress, partition.name);
    return (outcome: outcome, put: edited.put, deleted: edited.deleted, missing: edited.missing);
  }

  // --------------------------------------------------------------------------
  // Apps and OTA
  // --------------------------------------------------------------------------

  /// Parse [app] as an ESP image with an app descriptor and check it targets
  /// this chip and fits [partition].
  ImageMetadata validateApp(Uint8List app, PartitionDefinition partition) {
    if (app.isEmpty) throw IdfToolException('Application binary is empty');
    if (app.length > partition.size) {
      throw IdfToolException(
          "Application binary size ${hex(app.length)} exceeds partition '${partition.name}' size ${hex(partition.size)}");
    }
    return validateImageChip(app, appRequired: true);
  }

  /// Parse [bootloader] as an ESP image and check it targets this chip: a
  /// bootloader for another chip leaves the board unable to boot.
  ImageMetadata validateBootloader(Uint8List bootloader) {
    if (bootloader.isEmpty) throw IdfToolException('Bootloader binary is empty');
    return validateImageChip(bootloader, appRequired: false);
  }

  /// Parse [data] as an ESP image (with an app descriptor when [appRequired])
  /// and check it was built for this chip.
  ImageMetadata validateImageChip(Uint8List data, {required bool appRequired}) {
    final what = appRequired ? 'application' : 'bootloader';
    final ImageMetadata image;
    try {
      image = ImageMetadata.fromBytes(data, appRequired: appRequired);
    } catch (e) {
      throw IdfToolException('Invalid $what binary: $e');
    }
    final imageChip = image.header.chipId;
    if (imageChip?.value != chip.imageChipId) {
      throw IdfToolException('Chip ID mismatch: attempting to flash ${imageChip?.name ?? 'unknown-chip'} $what image '
          'to ${chip.name} device');
    }
    return image;
  }

  /// The otadata partition and its currently selected entry.
  Future<({PartitionDefinition partition, OtaDataParameters otadata})> readOtadata() async {
    final table = await partitionTable();
    final appCount = table.otaAppCount;
    if (appCount == 0) throw IdfToolException('No OTA partitions found');
    final partition = table.otadataPartition ?? (throw IdfToolException('No otadata partition found'));
    final a = OtaDataSelectEntry.fromBytes(await loader.readFlash(partition.offset, OtaDataSelectEntry.size));
    final b = OtaDataSelectEntry.fromBytes(
        await loader.readFlash(partition.offset + OtaDataCopy.b.offset, OtaDataSelectEntry.size));
    return (partition: partition, otadata: OtaDataParameters.select(a, b, appCount: appCount));
  }

  /// Write the selected otadata entry into its copy of the partition. Only
  /// the 32-byte entry is written; the ROM/stub erases that sector first.
  Future<void> writeOtadata(PartitionDefinition partition, OtaDataParameters otadata) async {
    final entry = otadata.entry ?? (throw IdfToolException('No otadata entry to write'));
    final copy = otadata.copy ?? OtaDataCopy.a;
    await loader.writeFlash(partition.offset + copy.offset, entry.toBytes(), compress: false);
  }

  /// Flash [app] to the `factory` partition (or `ota_0` if there is none)
  /// and erase otadata so the bootloader falls back to it.
  Future<WriteOutcome> factory(Uint8List app, {WriteStrategy strategy = WriteStrategy.differential, ProgressCallback? onProgress}) async {
    final table = await partitionTable();
    final partition = table.findByType(PartitionType.app, AppSubtype.factory).firstOrNull ??
        table.findByType(PartitionType.app, AppSubtype.ota0).firstOrNull ??
        (throw IdfToolException('No factory or OTA partition found'));
    validateApp(app, partition);
    final outcome = await _write(partition.offset, app, strategy, onProgress, partition.name);
    final otadata = table.otadataPartition;
    if (otadata != null) await loader.eraseRegion(otadata.offset, otadata.size);
    return outcome;
  }

  /// Write [app] to the next OTA slot and switch the bootloader to it.
  /// Returns the slot's partition and the write outcome.
  Future<({PartitionDefinition partition, WriteOutcome outcome})> ota(Uint8List app,
      {WriteStrategy strategy = WriteStrategy.differential, ProgressCallback? onProgress}) async {
    final table = await partitionTable();
    final (partition: otadataPartition, otadata: otadata) = await readOtadata();
    final slot = otadata.nextSlot;
    final partition = table.findByType(PartitionType.app, AppSubtype.otaMin + slot).firstOrNull ??
        (throw IdfToolException('Partition ota_$slot not found'));
    validateApp(app, partition);
    final outcome = await _write(partition.offset, app, strategy, onProgress, partition.name);
    await writeOtadata(otadataPartition, otadata.incrementedAndSwapped(slot));
    return (partition: partition, outcome: outcome);
  }

  /// Force the next boot to the OTA partition named [label].
  Future<void> setBoot(String label) async {
    final table = await partitionTable();
    final partition = table.findByName(label) ?? (throw IdfToolException("No partition named '$label'"));
    if (!partition.isApp) throw IdfToolException('Partition $label is not an app partition');
    if (!partition.isOtaApp) throw IdfToolException('Partition $label is not an OTA partition');
    final (partition: otadataPartition, otadata: otadata) = await readOtadata();
    final next = otadata.incrementedAndSwapped(partition.subtype & 0x0F);
    await writeOtadata(otadataPartition,
        OtaDataParameters(entry: OtaDataSelectEntry(next.entry!.seq, OtaImageState.valid), copy: next.copy, appCount: next.appCount));
  }

  /// Erase otadata so the bootloader falls back to the factory app.
  Future<void> clearBoot() async {
    final table = await partitionTable();
    final partition = table.otadataPartition ?? (throw IdfToolException('No otadata partition found'));
    await loader.eraseRegion(partition.offset, partition.size);
  }

  // --------------------------------------------------------------------------
  // Partition table, whole-flash images, bundles
  // --------------------------------------------------------------------------

  /// Where a table goes for [bootloader], the bootloader that will read it:
  /// where that records it, else where the device's own records it (see
  /// [resolvePartitionTableOffset]). [bootloader] is the device's own when
  /// `null`.
  ({int offset, int? recorded}) partitionTableOffsetFor({Uint8List? bootloader, bool writing = false, bool force = false}) {
    final recorded = (bootloader == null ? null : partitionTableOffsetOfBootloader(bootloader)) ?? _recordedPartitionTableOffset;
    return (offset: resolvePartitionTableOffset(recorded, writing: writing, force: force), recorded: recorded);
  }

  /// Flash [table] where [bootloader] (the device's own by default; see
  /// [partitionTableOffsetFor]) will read it, and work against it from then
  /// on. Fails verification, or a table placed away from where the
  /// bootloader records it, unless [force]; either way this replaces only
  /// the map — existing partition data is not moved, resized or erased.
  Future<void> writePartitionTable(PartitionTable table, {bool force = false, int? flashSize, Uint8List? bootloader}) async {
    if (!_partitionTableOffsetRead) await readPartitionTableOffset();
    final (:offset, :recorded) = partitionTableOffsetFor(bootloader: bootloader, writing: true, force: force);
    checkTableRow(table, recorded, writing: true, force: force, warn: warn);
    try {
      table.verify(partitionTableOffset: offset);
    } on PartitionTableException catch (e) {
      if (!force) throw IdfToolException('Partition table failed verification: $e. Pass force to flash it anyway.');
    }
    flashSize ??= this.flashSize;
    if (flashSize != null) table.verifySizeFits(flashSize);
    await loader.writeFlash(offset, table.toBinary());
    _partitionTableOffset = offset;
    usePartitionTable(table);
  }

  /// Read the first [size] bytes of flash (all of it by default).
  Future<Uint8List> dumpImage({required int flashSize, int? size, ProgressCallback? onProgress}) {
    final length = size ?? flashSize;
    if (length > flashSize) {
      throw IdfToolException('Size ${hex(length)} is larger than the flash (${hex(flashSize)})');
    }
    return loader.readFlash(0, length, onProgress: (done, total) => onProgress?.call('Dumping flash', done, total));
  }

  /// Write a whole-flash [image] (starting at address 0), after checking its
  /// bootloader targets this chip. Its partition table is where its
  /// bootloader records it ([partitionTableOffsetOfImage]); one placed
  /// elsewhere is refused unless [force]. With [erase] the entire flash is
  /// erased first, which makes the result reproducible but forces a full
  /// write.
  Future<WriteOutcome> writeImage(Uint8List image,
      {bool erase = true, bool force = false, WriteStrategy strategy = WriteStrategy.differential, ProgressCallback? onProgress}) async {
    if (image.isEmpty) throw IdfToolException('Image is empty');
    final bootloaderOffset = primaryBootloaderOffset ?? 0;
    final recorded = partitionTableOffsetOfImage(image);
    final partitionTableOffset = resolvePartitionTableOffset(recorded, writing: true, force: force);
    if (image.length <= partitionTableOffset) {
      throw IdfToolException('Image (${hex(image.length)} bytes) is smaller than the partition table offset '
          '${hex(partitionTableOffset)}; it does not appear to contain a partition table');
    }
    final bootloader = ImageMetadata.fromBytesOrNull(Uint8List.sublistView(image, bootloaderOffset, partitionTableOffset));
    if (bootloader == null) {
      throw IdfToolException('Invalid bootloader in image, check the input file (chip type may be incorrect)');
    }
    if (bootloader.header.chipId?.value != chip.imageChipId) {
      throw IdfToolException('Chip ID mismatch: attempting to flash ${bootloader.header.chipId?.name ?? 'unknown-chip'} '
          'image to ${chip.name} device');
    }
    final tableBinary = Uint8List.sublistView(image, partitionTableOffset, (partitionTableOffset + partitionTableSize).clamp(0, image.length));
    if (isErased(tableBinary)) {
      throw IdfToolException('No partition table in the image at ${hex(partitionTableOffset)}: the flash there is erased');
    }
    final table = PartitionTable.fromBinary(tableBinary).requireNotEmpty('the image');
    checkTableRow(table, recorded, writing: true, force: force, warn: warn);
    _partitionTableOffset = partitionTableOffset;
    usePartitionTable(table);
    if (erase) {
      await loader.eraseFlash();
      strategy = WriteStrategy.always;
    }
    final data = Uint8List.sublistView(image, bootloaderOffset);
    return _write(bootloaderOffset, data, strategy, onProgress, 'image');
  }

  /// Read every partition into a ZIP (`<name>.bin` each, plus
  /// `partition_table.csv`) — python idftool's bundle format — with the
  /// bootloader as `bootloader.bin` when its offset is known, so the dump
  /// restores the whole device.
  Future<Uint8List> dumpBundle({ProgressCallback? onProgress}) async {
    final table = await partitionTable();
    final bootloader = (await resolver()).bootloaderEntry;
    final archive = Archive();
    // A table with its own `bootloader` row dumps it as a partition already.
    for (final partition in [if (bootloader != null && !table.any((p) => p.isPrimaryBootloader)) bootloader, ...table]) {
      final data = await loader.readFlash(partition.offset, partition.size,
          onProgress: (done, total) => onProgress?.call('Reading ${partition.name}', done, total));
      archive.add(ArchiveFile.bytes('${partition.name}.bin', data));
    }
    archive.add(ArchiveFile.string('partition_table.csv', table.toCsv()));
    return ZipEncoder().encodeBytes(archive);
  }

  /// Flash every `<partition>.bin` in a bundle ZIP, and its partition table
  /// if `partition_table.csv` is present (the bundle's table is then used to
  /// resolve the partitions). The table goes where the bundle's
  /// `bootloader.bin` records it, else where the device's bootloader does
  /// ([partitionTableOffsetFor]); one placed elsewhere by its own
  /// `partition_table` row is refused unless [force].
  Future<Map<String, WriteOutcome>> writeBundle(Uint8List zip,
      {bool force = false, WriteStrategy strategy = WriteStrategy.differential, ProgressCallback? onProgress}) async {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zip, verify: true);
    } catch (e) {
      throw IdfToolException('Bundle is not a valid ZIP archive: $e');
    }
    if (!_partitionTableOffsetRead) await readPartitionTableOffset();
    final csv = archive.find('partition_table.csv');
    if (csv != null) {
      final (:offset, :recorded) = partitionTableOffsetFor(bootloader: archive.find('bootloader.bin')?.readBytes(), writing: true, force: force);
      final table = PartitionTable.fromCsv(
        PartitionTable.decodeCsv(csv.readBytes()!),
        partitionTableOffset: offset,
        primaryBootloaderOffset: primaryBootloaderOffset,
      ).requireNotEmpty('the bundle');
      checkTableRow(table, recorded, writing: true, force: force, warn: warn);
      _partitionTableOffset = offset;
      usePartitionTable(table);
    }
    final r = await resolver();
    final writes = <(PartitionDefinition, int, Uint8List)>[];
    for (final file in archive.files.where((f) => f.isFile && f.name.endsWith('.bin'))) {
      final name = file.name.substring(0, file.name.length - 4);
      final partition = r.partition(name);
      final data = file.readBytes()!;
      if (data.length > partition.size) {
        throw IdfToolException('Bundle entry ${file.name} size ${hex(data.length)} exceeds partition '
            '${partition.name} size ${hex(partition.size)}');
      }
      // An erased slot (as dump-bundle saves an unused OTA partition) has no app to check.
      if (partition.isApp && data.any((b) => b != 0xFF)) validateApp(data, partition);
      if (partition.isPrimaryBootloader) validateBootloader(data);
      writes.add((partition, partition.offset, data));
    }
    if (csv != null) {
      writes.add((r.partitionTableEntry, r.partitionTableEntry.offset, (await partitionTable()).toBinary()));
    }
    final outcomes = <String, WriteOutcome>{};
    for (final (partition, address, data) in writes) {
      outcomes[partition.name] = await _write(address, data, strategy, onProgress, partition.name);
    }
    return outcomes;
  }
}
