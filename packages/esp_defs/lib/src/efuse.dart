import 'dart:typed_data';

import 'chip.dart';
import 'efuse_tables.g.dart';

/// How a field's bits are read: one bit, an unsigned number (at most 32
/// bits in every table), or a run of bytes.
enum EfuseType { bool, uint, bytes }

/// espefuse's grouping of fields, in the order a summary lists them.
enum EfuseCategory {
  identity('Identity'),
  mac('MAC'),
  security('Security'),
  flash('Flash'),
  jtag('JTAG'),
  usb('USB'),
  spiPad('SPI pads'),
  vdd('VDD_SPI'),
  wdt('Watchdog'),
  config('Configuration'),
  calibration('Calibration');

  const EfuseCategory(this.label);
  final String label;
}

/// How a field's value reads beyond its [EfuseType].
enum EfuseKind {
  plain,

  /// A MAC address (`MAC`, `CUSTOM_MAC`, `MAC_EXT`).
  mac,

  /// A key block's purpose, named by [EfuseTable.keyPurposes].
  keyPurpose,

  /// A counter burnt one bit at a time (`SPI_BOOT_CRYPT_CNT`,
  /// `SECURE_VERSION`): what counts is how many bits are set.
  bitCount,

  /// A key or other opaque block of bytes.
  keyBlock,

  /// The temperature sensor's offset: sign and magnitude, in 0.1 °C.
  tSensor,
}

/// An eFuse block: a run of [words] 32-bit words read at
/// [EfuseTable.baseAddress] + [readOffset].
class EfuseBlock {
  const EfuseBlock({
    required this.name,
    this.aliases = const [],
    required this.index,
    required this.readOffset,
    required this.words,
    this.writeDisableBit,
    this.readDisableBits = const [],
    this.keyPurposeField,
  });

  final String name;

  /// Other names espefuse accepts (`BLOCK4` for `BLOCK_KEY0`).
  final List<String> aliases;
  final int index;
  final int readOffset;
  final int words;

  /// The `WR_DIS` bit that locks the whole block against burning.
  final int? writeDisableBit;

  /// The `RD_DIS` bits that hide it from software (key blocks).
  final List<int> readDisableBits;

  /// The field holding this key block's purpose.
  final String? keyPurposeField;

  /// `BLOCK_KEY0 (BLOCK4)`, or just the name when it has no numbered alias.
  String get label => aliases.isEmpty || aliases.first == name ? name : '$name (${aliases.first})';
}

/// One named eFuse field, as espefuse defines it: [bitLength] bits from bit
/// [pos] of [word] in [block].
class EfuseField {
  const EfuseField({
    required this.name,
    required this.block,
    required this.word,
    required this.pos,
    required this.bitLength,
    required this.type,
    required this.category,
    this.kind = EfuseKind.plain,
    required this.description,
    this.altNames = const [],
    this.writeDisableBit,
    this.readDisableBits = const [],
    this.values = const {},
  });

  final String name;
  final int block;
  final int word;
  final int pos;
  final int bitLength;
  final EfuseType type;
  final EfuseCategory category;
  final EfuseKind kind;
  final String description;

  /// Older or alternative names for the field.
  final List<String> altNames;

  /// The `WR_DIS` bit that locks this field.
  final int? writeDisableBit;

  /// The `RD_DIS` bits that hide this field's block.
  final List<int> readDisableBits;

  /// Meanings of particular values, where espefuse gives them.
  final Map<int, String> values;

  /// First bit within the block.
  int get startBit => word * 32 + pos;

  /// `BLOCK0 word 1 [18:16]`.
  String get location {
    final end = pos + bitLength - 1;
    return 'BLOCK$block word $word ${bitLength == 1 ? '[$pos]' : '[$end:$pos]'}';
  }
}

/// A chip's eFuse layout: where its blocks are read and what fields they
/// hold. Some chips have more than one, by revision (see [efuseTableFor]).
class EfuseTable {
  const EfuseTable({
    required this.baseAddress,
    this.minRevision = 0,
    required this.blocks,
    required this.fields,
    this.keyPurposes = const {},
  });

  /// `DR_REG_EFUSE_BASE`.
  final int baseAddress;

  /// The lowest chip revision (major * 100 + minor) this layout covers.
  final int minRevision;
  final List<EfuseBlock> blocks;
  final List<EfuseField> fields;

  /// Key purpose values and their names (`KEY_PURPOSE_n`).
  final Map<int, String> keyPurposes;

  /// The field called [name], or with [name] among its [EfuseField.altNames].
  EfuseField? field(String name) => fields.where((f) => f.name == name || f.altNames.contains(name)).firstOrNull;

  /// The block with [index].
  EfuseBlock? block(int index) => blocks.where((b) => b.index == index).firstOrNull;

  /// Absolute address of [block]'s word [word].
  int wordAddress(EfuseBlock block, int word) => baseAddress + block.readOffset + word * 4;
}

/// The eFuse tables for [chip], newest revision first; empty if there are
/// none.
List<EfuseTable> efuseTablesFor(EspChip chip) => [...?efuseTables[chip]]..sort((a, b) => b.minRevision.compareTo(a.minRevision));

/// The table for [chip] at [revision] (major * 100 + minor), or the base
/// table if the revision is unknown.
EfuseTable? efuseTableFor(EspChip chip, {int? revision}) {
  final tables = efuseTablesFor(chip);
  if (tables.isEmpty) return null;
  if (revision == null) return tables.last;
  return tables.firstWhere((t) => revision >= t.minRevision, orElse: () => tables.last);
}

/// Raw eFuse block contents read from a chip, decoded against [table].
class EfuseValues {
  EfuseValues(this.chip, this.table, this.blocks);

  /// Decode [blocks] (block index → words) with the right table for the
  /// revision they record.
  factory EfuseValues.decode(EspChip chip, Map<int, Uint32List> blocks) {
    final base = efuseTableFor(chip)!;
    final revision = EfuseValues(chip, base, blocks).revision;
    return EfuseValues(chip, efuseTableFor(chip, revision: revision)!, blocks);
  }

  final EspChip chip;
  final EfuseTable table;

  /// Block index → its words, as read.
  final Map<int, Uint32List> blocks;

  bool _bit(int block, int bit) {
    final words = blocks[block];
    final w = bit ~/ 32;
    if (words == null || w >= words.length) return false;
    return (words[w] >> (bit % 32)) & 1 == 1;
  }

  /// [field]'s bits packed into bytes, least significant first — the order
  /// they sit in the block.
  Uint8List bytes(EfuseField field) {
    final out = Uint8List((field.bitLength + 7) ~/ 8);
    for (var i = 0; i < field.bitLength; i++) {
      if (_bit(field.block, field.startBit + i)) out[i ~/ 8] |= 1 << (i % 8);
    }
    return out;
  }

  /// [field] as an unsigned number (bool fields read 0 or 1). Built by
  /// multiplication so it holds on the web, where bitwise ops are 32-bit.
  int uint(EfuseField field) {
    final b = bytes(field);
    var v = 0;
    for (var i = b.length - 1; i >= 0; i--) {
      v = v * 256 + b[i];
    }
    return v;
  }

  /// The field called [name] as a number, or `null` if the table has none.
  int? uintNamed(String name) => switch (table.field(name)) { final f? => uint(f), null => null };

  bool isZero(EfuseField field) => bytes(field).every((b) => b == 0);

  /// Whether [field] is locked against further burning.
  bool writeProtected(EfuseField field) {
    final bit = field.writeDisableBit;
    return bit != null && _bit(0, bit);
  }

  /// Whether [field]'s block is hidden from reads (it reads as zeros).
  bool readProtected(EfuseField field) => field.readDisableBits.any(_readDisabled);

  bool blockWriteProtected(EfuseBlock block) => block.writeDisableBit != null && _bit(0, block.writeDisableBit!);
  bool blockReadProtected(EfuseBlock block) => block.readDisableBits.any(_readDisabled);

  bool _readDisabled(int bit) {
    final rd = table.field('RD_DIS');
    return rd != null && _bit(rd.block, rd.startBit + bit);
  }

  /// The purpose of key [block], by name, if it has one.
  String? keyPurpose(EfuseBlock block) {
    final f = switch (block.keyPurposeField) { final n? => table.field(n), null => null };
    return f == null ? null : purposeName(uint(f));
  }

  String purposeName(int v) => table.keyPurposes[v] ?? 'UNKNOWN ($v)';

  /// Chip revision as major * 100 + minor, where the eFuses record it.
  int? get revision {
    int? v(String n) => uintNamed(n);
    final minorRaw =
        v('WAFER_VERSION_MINOR') ?? switch ((v('WAFER_VERSION_MINOR_HI'), v('WAFER_VERSION_MINOR_LO'))) { (final hi?, final lo?) => hi * 8 + lo, _ => null };
    final major =
        v('WAFER_VERSION_MAJOR') ?? switch ((v('WAFER_VERSION_MAJOR_HI'), v('WAFER_VERSION_MAJOR_LO'))) { (final hi?, final lo?) => hi * 4 + lo, _ => null };
    if (minorRaw == null || major == null) return null;
    // ESP32-S3 v0.0 left these unburnt; esptool recognises it by BLK_VERSION 1.1.
    if (chip == EspChip.esp32s3 && minorRaw % 8 == 0 && v('BLK_VERSION_MAJOR') == 1 && v('BLK_VERSION_MINOR') == 1) return 0;
    return major * 100 + minorRaw;
  }

  /// `v0.2`, or `null`.
  String? get revisionString => switch (revision) { final r? => 'v${r ~/ 100}.${r % 100}', null => null };

  /// [field]'s value as espefuse would show it: `true`, `5`, a value's
  /// meaning, a MAC, a key purpose, or bytes in hex.
  String format(EfuseField field) {
    final b = bytes(field);
    switch (field.kind) {
      case EfuseKind.mac:
        final mac = field.name == 'CUSTOM_MAC' ? b : Uint8List.fromList(b.reversed.toList());
        final text = mac.map((x) => x.toRadixString(16).padLeft(2, '0')).join(':');
        final crc = table.field('${field.name}_CRC');
        if (crc == null) return text;
        final stored = uint(crc);
        return stored == _crc8(mac) ? '$text (CRC OK)' : '$text (CRC 0x${stored.toRadixString(16)} does not match)';
      case EfuseKind.keyPurpose:
        return purposeName(uint(field));
      case EfuseKind.tSensor:
        final v = uint(field);
        final sign = 1 << (field.bitLength - 1);
        final tenths = v & (sign - 1);
        return '${v & sign != 0 && tenths != 0 ? '-' : ''}${tenths ~/ 10}.${tenths % 10} °C';
      case EfuseKind.plain || EfuseKind.bitCount || EfuseKind.keyBlock:
    }
    switch (field.type) {
      case EfuseType.bool:
        final v = b[0] & 1;
        return field.values[v] ?? (v == 1 ? 'true' : 'false');
      case EfuseType.bytes:
        return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ');
      case EfuseType.uint:
        final v = uint(field);
        final meaning = field.values[v];
        if (field.kind == EfuseKind.bitCount) {
          final bits = v.toRadixString(2).replaceAll('0', '').length;
          return '${meaning ?? '$bits bit${bits == 1 ? '' : 's'} set'} (0b${v.toRadixString(2).padLeft(field.bitLength, '0')})';
        }
        final number = field.bitLength > 8 ? '$v (0x${v.toRadixString(16)})' : '$v';
        return meaning == null ? number : '$meaning ($v)';
    }
  }

  /// esp_crc8: CRC-8, reflected polynomial 0x8C, initial 0 (ESP32 MAC CRC).
  static int _crc8(List<int> data) {
    var crc = 0;
    for (final b in data) {
      crc ^= b;
      for (var i = 0; i < 8; i++) {
        crc = crc & 1 == 1 ? (crc >> 1) ^ 0x8C : crc >> 1;
      }
    }
    return crc;
  }

  /// A plain-text listing like `espefuse summary`, for saving.
  String summary() {
    final out = StringBuffer('${chip.name}${revisionString == null ? '' : ' $revisionString'} eFuses\n');
    for (final c in EfuseCategory.values) {
      final fields = table.fields.where((f) => f.category == c).toList();
      if (fields.isEmpty) continue;
      out.writeln('\n${c.label}');
      for (final f in fields) {
        final flags = '${readProtected(f) ? '-' : 'R'}/${writeProtected(f) ? '-' : 'W'}';
        out.writeln('${f.name.padRight(32)} ${f.description}');
        out.writeln('${''.padRight(32)} = ${format(f)} $flags');
      }
    }
    out.writeln('\nBlocks');
    for (final block in table.blocks) {
      final words = blocks[block.index];
      out.writeln('${block.label.padRight(32)} ${words == null ? '(not read)' : words.map((w) => w.toRadixString(16).padLeft(8, '0')).join(' ')}');
    }
    return out.toString();
  }
}
