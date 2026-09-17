import 'dart:typed_data';

import 'device.dart';
import 'int_literal.dart';
import 'manifest.dart';
import 'partition_table.dart';
import 'partition_table_files.dart';

/// What flashing a bundle does when its partition table differs from the
/// device's. A table that already matches is never written, whatever the
/// policy; what counts as a match is [TableMatch].
enum TablePolicy {
  /// Write it (the default, and what a bundle without a policy means).
  update('update'),

  /// Show the differences and let the person flashing decide: update the
  /// table, keep the device's (only where [TableMatch.used] allows it), or
  /// flash nothing.
  ask('ask'),

  /// Never write it: flash only a device whose table is compatible.
  require('require');

  const TablePolicy(this.keyword);

  /// The manifest's spelling.
  final String keyword;

  static TablePolicy parse(Object? value) {
    if (value == null) return update;
    return values.where((p) => p.keyword == value).firstOrNull ??
        (throw IdfToolException('table policy must be one of ${values.map((p) => '"${p.keyword}"').join(', ')}, not "$value"'));
  }
}

/// Which differences in the device's table the firmware cannot live with.
enum TableMatch {
  /// Any (the default): the firmware needs this exact layout.
  exact('exact'),

  /// Only in the partitions the bundle itself uses (writes, erases, edits,
  /// boots); the rest of the layout may stay as the device has it.
  used('used');

  const TableMatch(this.keyword);

  /// The manifest's spelling.
  final String keyword;

  static TableMatch parse(Object? value) {
    if (value == null) return exact;
    return values.where((m) => m.keyword == value).firstOrNull ??
        (throw IdfToolException('table match must be one of ${values.map((m) => '"${m.keyword}"').join(', ')}, not "$value"'));
  }
}

/// What the person flashing chose for a differing table ([TablePolicy.ask]).
enum TableChoice {
  /// Write the bundle's table first.
  update,

  /// Leave the device's table as it is (only when [BundleCheck.canKeepLayout]).
  keep,
}

/// One partition that differs between the table a bundle writes and the
/// device's, matched by name.
class PartitionDifference {
  const PartitionDifference(this.name, {this.expected, this.actual});
  final String name;

  /// The row in the bundle's table; `null` when only the device has it.
  final PartitionDefinition? expected;

  /// The row on the device; `null` when only the bundle's table has it.
  final PartitionDefinition? actual;

  /// What changes, device first: `resized 16K → 24K`, `new at 0x9000 (24K)`.
  String describe() {
    final e = expected, a = actual;
    String size(int s) => PartitionDefinition.formatSize(s);
    String kind(PartitionDefinition p) => '${p.typeName}/${p.subtypeName}';
    String flags(PartitionDefinition p) => p.flagNames.isEmpty ? 'no flags' : p.flagNames.join(', ');
    if (a == null) return 'new at ${hex(e!.offset)} (${size(e.size)})';
    if (e == null) return 'removed (was at ${hex(a.offset)}, ${size(a.size)})';
    return [
      if (a.offset != e.offset) 'moved ${hex(a.offset)} → ${hex(e.offset)}',
      if (a.size != e.size) 'resized ${size(a.size)} → ${size(e.size)}',
      if (a.type != e.type || a.subtype != e.subtype) '${kind(a)} → ${kind(e)}',
      if (a.encrypted != e.encrypted || a.readonly != e.readonly) '${flags(a)} → ${flags(e)}',
    ].join(', ');
  }

  @override
  String toString() => '$name: ${describe()}';
}

/// The partitions that differ between [expected] and [actual], in
/// [expected]'s order followed by the ones only [actual] has. Empty when
/// the two describe the same partitions; an [actual] of `null` (nothing
/// readable on the device) makes every partition new.
List<PartitionDifference> comparePartitionTables(PartitionTable expected, PartitionTable? actual) => [
      for (final e in expected)
        if (actual?.findByName(e.name) case final a when a != e) PartitionDifference(e.name, expected: e, actual: a),
      for (final a in actual ?? const <PartitionDefinition>[])
        if (expected.findByName(a.name) == null) PartitionDifference(a.name, actual: a),
    ];

/// What flashing a bundle will meet on a device, worked out before anything
/// is written: whether its table matches, and whether every partition it
/// names exists in the table that name will resolve against.
class BundleCheck {
  const BundleCheck({
    required this.deviceTable,
    this.table,
    this.policy = TablePolicy.update,
    this.match = TableMatch.exact,
    this.differences = const [],
    this.used = const {},
    this.missing = const {},
  });

  /// The device's table; `null` when it has none that can be read.
  final PartitionTable? deviceTable;

  /// The table the bundle writes, if it carries one.
  final PartitionTable? table;
  final TablePolicy policy;
  final TableMatch match;

  /// How [table] differs from [deviceTable]; empty when it matches or the
  /// bundle carries no table.
  final List<PartitionDifference> differences;

  /// The partitions the bundle uses, by name, in [table]'s terms.
  final Set<String> used;

  /// Problems by step index: a partition a step names that the table it
  /// resolves against does not have.
  final Map<int, String> missing;

  bool get carriesTable => table != null;
  bool get tableMatches => table != null && differences.isEmpty;

  /// The bundle carries a table and the device's differs from it.
  bool get tableChanges => table != null && differences.isNotEmpty;

  /// None of the differences touch a partition the bundle uses: flashing
  /// onto the device's own layout would land everything in the same place.
  bool get usedPartitionsMatch => deviceTable != null && !differences.any((d) => used.contains(d.name));

  /// The device's differing table may stay: the author allows it
  /// ([TableMatch.used]) and nothing the bundle uses differs.
  bool get canKeepLayout => tableChanges && match == TableMatch.used && usedPartitionsMatch;

  /// The person flashing has to choose before flashing ([TablePolicy.ask]).
  bool get needsApproval => tableChanges && policy == TablePolicy.ask;

  /// What happens to a differing table without asking: written for
  /// [TablePolicy.update], kept for [TablePolicy.require] when it may be,
  /// `null` when it is the user's choice or cannot be flashed at all.
  TableChoice? get automaticChoice => switch (policy) {
        _ when !tableChanges => TableChoice.keep,
        TablePolicy.update => TableChoice.update,
        TablePolicy.ask => null,
        TablePolicy.require => canKeepLayout ? TableChoice.keep : null,
      };

  /// Why this bundle cannot be flashed onto this device at all, if it can't.
  String? get blocker {
    if (tableChanges && policy == TablePolicy.require && !canKeepLayout) {
      return deviceTable == null
          ? 'This update needs a device that already has its partition layout, and this one has none'
          : match == TableMatch.used
              ? "This device's partition layout differs where this update writes"
              : "This device's partition layout is different from the one this update requires";
    }
    if (missing.isNotEmpty) return missing.values.join('; ');
    return null;
  }
}

/// Check [bundle] against [deviceTable] (see [BundleCheck]). A bundle that
/// carries a table writes it first, so every name resolves against that
/// table; otherwise against the device's.
BundleCheck checkBundle(FlashBundle bundle, PartitionTable? deviceTable) {
  final table = bundle.contents.table;
  final current = table ?? deviceTable;
  final missing = <int, String>{};
  final used = <String>{};
  // Partitions picked by kind rather than name are used in both tables:
  // an OTA flash may pick any slot either one has.
  void useWhere(bool Function(PartitionDefinition p) test) {
    for (final t in [table, deviceTable]) {
      used.addAll([for (final p in t ?? const <PartitionDefinition>[]) if (test(p)) p.name]);
    }
  }

  String? need(String name) {
    if (current == null) return "'$name': the device has no partition table";
    return current.findByName(name) == null ? "'$name' is not a partition on this device" : null;
  }

  String? needWhere(String what, bool Function(PartitionDefinition p) test) {
    if (current == null) return '$what: the device has no partition table';
    return current.any(test) ? null : 'no $what partition on this device';
  }

  for (var i = 0; i < bundle.steps.length; i++) {
    String? problem;
    switch (bundle.steps[i]) {
      case WriteTableStep():
      case WriteBootloaderStep():
        break;
      case FactoryStep():
        bool factory(PartitionDefinition p) => p.isApp && (p.subtype == AppSubtype.factory.value || p.subtype == AppSubtype.ota0.value);
        problem = needWhere('factory or ota_0', factory);
        useWhere((p) => factory(p) || p.isOtadata);
      case OtaStep():
        problem = needWhere('OTA app', (p) => p.isOtaApp);
        useWhere((p) => p.isOtaApp || p.isOtadata);
      case ClearBootStep():
        problem = needWhere('otadata', (p) => p.isOtadata);
        useWhere((p) => p.isOtadata);
      case SetNvsStep(:final partition):
        bool nvs(PartitionDefinition p) => p.isData && p.subtype == DataSubtype.nvs.value;
        problem = partition != null ? need(partition) : needWhere('NVS', nvs);
        if (partition != null) {
          used.add(partition);
        } else if (current?.where(nvs).firstOrNull case final p?) {
          used.add(p.name);
        }
      case SetBootStep(:final partition):
        problem = need(partition);
        used.add(partition);
        useWhere((p) => p.isOtadata);
      case WritePartitionStep(:final partition) || EraseStep(:final partition) || WriteFsStep(:final partition) || EditFsStep(:final partition):
        problem = need(partition);
        used.add(partition);
    }
    if (problem != null) missing[i] = problem;
  }
  return BundleCheck(
    deviceTable: deviceTable,
    table: table,
    policy: bundle.manifest?.tablePolicy ?? TablePolicy.update,
    match: bundle.manifest?.tableMatch ?? TableMatch.exact,
    differences: table == null ? const [] : comparePartitionTables(table, deviceTable),
    used: used,
    missing: missing,
  );
}

/// Parse a table file from a bundle, CSV or binary.
PartitionTable parsePartitionTable(Uint8List bytes, {required String source, int partitionTableOffset = PartitionTable.defaultOffset, int? primaryBootloaderOffset}) {
  return PartitionTable.isBinary(bytes)
      ? PartitionTable.fromBinary(bytes)
      : parsePartitionTableCsv(PartitionTable.decodeCsv(bytes),
          source: source, partitionTableOffset: partitionTableOffset, primaryBootloaderOffset: primaryBootloaderOffset);
}

/// The device's table, or `null` when there is none to read (blank or
/// corrupt flash). Serial errors still throw.
Future<PartitionTable?> readDeviceTable(IdfDevice device) async {
  try {
    return await device.partitionTable(refresh: true);
  } on IdfToolException {
    return null;
  } on PartitionTableException {
    return null;
  }
}
