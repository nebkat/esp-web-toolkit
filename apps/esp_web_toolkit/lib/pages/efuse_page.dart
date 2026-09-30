import 'dart:convert';

import 'package:esptool/esptool.dart';
import 'package:flutter/material.dart';

import '../session/device_session.dart';
import '../util/files.dart';
import '../widgets/empty_state.dart';
import '../widgets/type_chip.dart';

/// The chip's eFuses, read-only: what matters at a glance (revision, MAC,
/// flash encryption, secure boot, JTAG, download mode), the key blocks and
/// their purposes, every field espefuse knows grouped as its summary groups
/// them, and the raw block words. Nothing here burns anything.
class EfusePage extends StatefulWidget {
  const EfusePage({super.key, required this.session});
  final DeviceSession session;

  @override
  State<EfusePage> createState() => _EfusePageState();
}

class _EfusePageState extends State<EfusePage> {
  final _search = TextEditingController();
  bool _onlySet = false;

  /// Sections the user has opened (categories, and [_rawSection]). Kept
  /// here because the list rebuilds a section from scratch once it has
  /// scrolled far enough away.
  final Set<Object> _open = {};
  static const _rawSection = 'raw';

  /// Rebuilds too, so the list re-creates a section from its current state.
  void _setOpen(Object section, bool open) => setState(() => open ? _open.add(section) : _open.remove(section));

  DeviceSession get session => widget.session;

  @override
  void initState() {
    super.initState();
    session.addListener(_onSessionChanged);
    _onSessionChanged();
  }

  @override
  void dispose() {
    session.removeListener(_onSessionChanged);
    _search.dispose();
    super.dispose();
  }

  void _onSessionChanged() {
    if (mounted) Future<void>.microtask(session.ensureEfuses);
  }

  /// The raw blocks as JSON, enough to decode them again elsewhere.
  String _json(EfuseValues v) => const JsonEncoder.withIndent('  ').convert({
        'chip': v.chip.name,
        'mac': session.macString,
        'blocks': {
          for (final b in v.table.blocks)
            if (v.blocks[b.index] case final words?) b.name: [for (final w in words) w.toRadixString(16).padLeft(8, '0')],
        },
      });

  bool _matches(EfuseField f, EfuseValues v) {
    if (_onlySet && v.isZero(f)) return false;
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return true;
    return f.name.toLowerCase().contains(q) ||
        f.altNames.any((a) => a.toLowerCase().contains(q)) ||
        f.description.toLowerCase().contains(q) ||
        v.format(f).toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    if (!session.connected) {
      return const EmptyState.noDevice(message: 'Connect a device to read its eFuses: chip revision, MAC, security settings, key blocks and calibration data.');
    }
    final v = session.efuses;
    final busy = session.busy;
    if (v == null) {
      if (busy) return const LoadingState('Reading eFuses…');
      return EmptyState(
        icon: Icons.error_outline,
        error: true,
        title: 'eFuses not read',
        message: 'See the log for the error.',
        actions: [FilledButton.tonalIcon(onPressed: session.readEfuses, icon: const Icon(Icons.refresh), label: const Text('Try again'))],
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final groups = [
      for (final c in EfuseCategory.values)
        if (v.table.fields.where((f) => f.category == c && _matches(f, v)).toList() case final fields when fields.isNotEmpty) (c, fields),
    ];
    return ListView(padding: const EdgeInsets.all(16), children: [
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        FilledButton.tonalIcon(onPressed: busy ? null : session.readEfuses, icon: const Icon(Icons.refresh), label: const Text('Re-read')),
        MenuAnchor(
          builder: (context, controller, _) => OutlinedButton.icon(
            onPressed: () => controller.isOpen ? controller.close() : controller.open(),
            icon: const Icon(Icons.download),
            label: const Text('Save'),
          ),
          menuChildren: [
            MenuItemButton(onPressed: () => saveText('${session.deviceStem}-efuse.txt', v.summary()), child: const Text('Summary (text)')),
            MenuItemButton(
                onPressed: () => saveText('${session.deviceStem}-efuse.json', _json(v), mimeType: 'application/json'), child: const Text('Raw blocks (JSON)')),
          ],
        ),
        SizedBox(
          width: 280,
          child: TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Filter fields',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () => setState(_search.clear),
                    ),
            ),
          ),
        ),
        FilterChip(label: const Text('Only non-zero'), selected: _onlySet, onSelected: (s) => setState(() => _onlySet = s)),
      ]),
      const SizedBox(height: 12),
      _Overview(values: v),
      const SizedBox(height: 12),
      if (_keyBlocks(v) case final keys when keys.isNotEmpty) ...[
        _KeyBlocks(values: v, blocks: keys),
        const SizedBox(height: 12),
      ],
      for (final (category, fields) in groups) ...[
        _FieldGroup(
            key: ValueKey(category),
            category: category,
            fields: fields,
            values: v,
            // A search opens every group that matches.
            searching: _search.text.isNotEmpty,
            expanded: _open.contains(category),
            onExpansionChanged: (open) => _setOpen(category, open)),
        const SizedBox(height: 8),
      ],
      if (groups.isEmpty)
        Padding(padding: const EdgeInsets.all(24), child: Text('No fields match.', textAlign: TextAlign.center, style: TextStyle(color: scheme.outline))),
      const SizedBox(height: 4),
      _RawBlocks(values: v, expanded: _open.contains(_rawSection), onExpansionChanged: (open) => _setOpen(_rawSection, open)),
    ]);
  }

  /// Blocks that hold keys: those with a purpose, and ESP32's BLOCK1–3.
  static List<EfuseBlock> _keyBlocks(EfuseValues v) => [
        for (final b in v.table.blocks)
          if (b.keyPurposeField != null || (v.chip == EspChip.esp32 && b.index > 0) || b.name.startsWith('BLOCK_KEY')) b
      ];
}

/// A labelled fact, tinted when a protection is on or a feature is off.
enum _Tone { plain, on, off }

class _Fact {
  const _Fact(this.label, this.value, {this.tone = _Tone.plain, this.detail});
  final String label;
  final String value;
  final _Tone tone;

  /// Which fields it was worked out from.
  final String? detail;
}

class _Overview extends StatelessWidget {
  const _Overview({required this.values});
  final EfuseValues values;

  EfuseField? _f(String name) => values.table.field(name);
  int? _u(String name) => values.uintNamed(name);
  bool _oddBits(int v) => v.toRadixString(2).replaceAll('0', '').length.isOdd;

  List<_Fact> _facts() {
    final v = values;
    final facts = <_Fact>[
      _Fact('Chip', [v.chip.name, if (v.revisionString case final r?) r].join(' '), detail: 'WAFER_VERSION_*'),
      if (_f('MAC') case final mac?) _Fact('MAC', v.format(mac), detail: 'MAC'),
      if (_f('CUSTOM_MAC') case final mac? when !v.isZero(mac)) _Fact('Custom MAC', v.format(mac), detail: 'CUSTOM_MAC'),
      if (_u('PKG_VERSION') case final pkg?) _Fact('Package', '$pkg', detail: 'PKG_VERSION'),
      if ((_u('BLK_VERSION_MAJOR'), _u('BLK_VERSION_MINOR')) case (final major?, final minor?))
        _Fact('eFuse block version', 'v$major.$minor', detail: 'BLK_VERSION_MAJOR, BLK_VERSION_MINOR'),
    ];
    for (final name in ['FLASH_CAP', 'FLASH_VENDOR', 'PSRAM_CAP', 'PSRAM_VENDOR']) {
      final f = _f(name);
      // ESP32-S3 keeps a third PSRAM_CAP bit apart; the table's meanings only cover two.
      if (f == null || (name == 'PSRAM_CAP' && (_u('PSRAM_CAP_3') ?? 0) != 0)) continue;
      final label = switch (name) { 'FLASH_CAP' => 'Flash', 'FLASH_VENDOR' => 'Flash vendor', 'PSRAM_CAP' => 'PSRAM', _ => 'PSRAM vendor' };
      facts.add(_Fact(label, f.values[v.uint(f)] ?? '${v.uint(f)}', detail: name));
    }

    // Flash encryption: an odd number of bits in the crypt counter.
    final crypt = _f('SPI_BOOT_CRYPT_CNT') ?? _f('FLASH_CRYPT_CNT');
    if (crypt != null) {
      final on = _oddBits(v.uint(crypt));
      facts.add(_Fact('Flash encryption', on ? 'Enabled' : 'Disabled', tone: on ? _Tone.on : _Tone.plain, detail: crypt.name));
    }
    // Secure boot: SECURE_BOOT_EN, or ABS_DONE_1 / ABS_DONE_0 on ESP32 (v2 / v1).
    if (_u('SECURE_BOOT_EN') case final sb?) {
      facts.add(_Fact('Secure boot', sb != 0 ? 'Enabled' : 'Disabled', tone: sb != 0 ? _Tone.on : _Tone.plain, detail: 'SECURE_BOOT_EN'));
    } else if ((_u('ABS_DONE_0'), _u('ABS_DONE_1')) case (final v1?, final v2?)) {
      final text = v2 != 0
          ? 'V2 enabled'
          : v1 != 0
              ? 'V1 enabled'
              : 'Disabled';
      facts.add(_Fact('Secure boot', text, tone: v1 != 0 || v2 != 0 ? _Tone.on : _Tone.plain, detail: 'ABS_DONE_0, ABS_DONE_1'));
    }
    // JTAG: off for good (pad), off until HMAC re-enables it (soft), or open.
    final hard = _u('DIS_PAD_JTAG') ?? _u('JTAG_DISABLE');
    final soft = _u('SOFT_DIS_JTAG');
    if (hard != null) {
      final text = hard != 0
          ? 'Disabled'
          : soft != null && _oddBits(soft)
              ? 'Soft-disabled'
              : 'Enabled';
      facts.add(_Fact('Pad JTAG', text, tone: text == 'Enabled' ? _Tone.plain : _Tone.off, detail: 'DIS_PAD_JTAG, SOFT_DIS_JTAG'));
    }
    if (_u('DIS_USB_JTAG') case final usb?) {
      facts.add(_Fact('USB JTAG', usb != 0 ? 'Disabled' : 'Enabled', tone: usb != 0 ? _Tone.off : _Tone.plain, detail: 'DIS_USB_JTAG'));
    }
    if (_u('DIS_USB_SERIAL_JTAG') case final usb?) {
      facts.add(_Fact('USB Serial/JTAG', usb != 0 ? 'Disabled' : 'Enabled', tone: usb != 0 ? _Tone.off : _Tone.plain, detail: 'DIS_USB_SERIAL_JTAG'));
    }
    // Download mode: off, restricted to the secure subset, or full.
    final dl = _u('DIS_DOWNLOAD_MODE') ?? _u('UART_DOWNLOAD_DIS');
    if (dl != null) {
      final secure = (_u('ENABLE_SECURITY_DOWNLOAD') ?? 0) != 0;
      final text = dl != 0
          ? 'Disabled'
          : secure
              ? 'Secure only'
              : 'Enabled';
      facts.add(_Fact('Download mode', text, tone: text == 'Enabled' ? _Tone.plain : _Tone.off, detail: 'DIS_DOWNLOAD_MODE, ENABLE_SECURITY_DOWNLOAD'));
    }
    final used = v.table.blocks.where((b) => b.keyPurposeField != null && v.keyPurpose(b) != 'USER').length;
    final keyBlocks = v.table.blocks.where((b) => b.keyPurposeField != null).length;
    if (keyBlocks > 0) facts.add(_Fact('Key blocks assigned', '$used of $keyBlocks', tone: used > 0 ? _Tone.on : _Tone.plain, detail: 'KEY_PURPOSE_*'));
    return facts;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(spacing: 12, runSpacing: 12, children: [
          for (final f in _facts())
            Tooltip(
              message: f.detail ?? '',
              child: Container(
                width: 220,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: switch (f.tone) {
                    _Tone.on => scheme.tertiaryContainer,
                    _Tone.off => scheme.secondaryContainer,
                    _Tone.plain => scheme.surfaceContainerHighest
                  },
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(f.label, style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 2),
                  SelectableText(f.value, style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 14, fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
        ]),
      ),
    );
  }
}

/// Key blocks: purpose, whether they hold anything, and their protection.
class _KeyBlocks extends StatelessWidget {
  const _KeyBlocks({required this.values, required this.blocks});
  final EfuseValues values;
  final List<EfuseBlock> blocks;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Key blocks', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final b in blocks)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                SizedBox(width: 220, child: Text(b.label, style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 13))),
                SizedBox(
                  width: 280,
                  child: switch (values.keyPurpose(b)) {
                    final p? => Align(alignment: Alignment.centerLeft, child: TypeChip(p, p == 'USER' ? Colors.grey : colorForName(p))),
                    null => const SizedBox.shrink(),
                  },
                ),
                Expanded(child: Text(_contents(b), style: TextStyle(color: scheme.outline))),
                _ProtectionIcons(read: values.blockReadProtected(b), write: values.blockWriteProtected(b)),
              ]),
            ),
        ]),
      ),
    );
  }

  String _contents(EfuseBlock b) {
    if (values.blockReadProtected(b)) return 'Read-protected — contents hidden';
    final words = values.blocks[b.index];
    return words == null || words.every((w) => w == 0) ? 'Empty' : 'Holds data';
  }
}

class _ProtectionIcons extends StatelessWidget {
  const _ProtectionIcons({required this.read, required this.write});
  final bool read;
  final bool write;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.outline;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      if (read) Tooltip(message: 'Read-protected: software reads zeros', child: Icon(Icons.visibility_off_outlined, size: 18, color: color)),
      if (read && write) const SizedBox(width: 4),
      if (write) Tooltip(message: 'Write-protected: can no longer be burnt', child: Icon(Icons.lock_outline, size: 18, color: color)),
    ]);
  }
}

/// One of espefuse's categories as a collapsible list of fields.
class _FieldGroup extends StatelessWidget {
  const _FieldGroup(
      {super.key,
      required this.category,
      required this.fields,
      required this.values,
      required this.searching,
      required this.expanded,
      required this.onExpansionChanged});
  final EfuseCategory category;
  final List<EfuseField> fields;
  final EfuseValues values;
  final bool searching;
  final bool expanded;
  final ValueChanged<bool> onExpansionChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final set = fields.where((f) => !values.isZero(f)).length;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        // Starting or clearing a search rebuilds the tile, opening it or
        // putting it back as the user left it.
        key: ValueKey((category, searching)),
        initiallyExpanded: searching || expanded,
        onExpansionChanged: onExpansionChanged,
        shape: const Border(),
        title: Text(category.label, style: theme.textTheme.titleMedium),
        subtitle: Text('${fields.length} field${fields.length == 1 ? '' : 's'}, $set non-zero', style: TextStyle(color: scheme.outline)),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          for (final (i, f) in fields.indexed) ...[
            if (i > 0) const Divider(height: 1),
            _FieldRow(field: f, values: values),
          ],
        ],
      ),
    );
  }
}

class _FieldRow extends StatelessWidget {
  const _FieldRow({required this.field, required this.values});
  final EfuseField field;
  final EfuseValues values;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final zero = values.isZero(field);
    final wide = field.type == EfuseType.bytes && field.kind != EfuseKind.mac;
    final name = Tooltip(
      message: [field.location, if (field.altNames.isNotEmpty) 'Also: ${field.altNames.join(', ')}'].join('\n'),
      child: Text(field.name, style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 13, fontWeight: FontWeight.w600)),
    );
    final value = SelectableText(
      values.format(field),
      style: TextStyle(fontFamily: 'RobotoMono', fontSize: 13, color: zero ? scheme.outline : scheme.primary, fontWeight: zero ? null : FontWeight.w600),
    );
    final protection = _ProtectionIcons(read: values.readProtected(field), write: values.writeProtected(field));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: LayoutBuilder(builder: (context, constraints) {
        final description = Text(field.description, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant));
        // Long byte values and narrow screens put the value under the name.
        if (wide || constraints.maxWidth < 720) {
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Expanded(child: name), protection]),
            const SizedBox(height: 2),
            description,
            const SizedBox(height: 4),
            value,
          ]);
        }
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 5, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [name, const SizedBox(height: 2), description])),
          const SizedBox(width: 16),
          Expanded(flex: 4, child: value),
          SizedBox(width: 44, child: Align(alignment: Alignment.topRight, child: protection)),
        ]);
      }),
    );
  }
}

/// Every block's words in hex, as `espefuse dump` prints them.
class _RawBlocks extends StatelessWidget {
  const _RawBlocks({required this.values, required this.expanded, required this.onExpansionChanged});
  final EfuseValues values;
  final bool expanded;
  final ValueChanged<bool> onExpansionChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: expanded,
        onExpansionChanged: onExpansionChanged,
        shape: const Border(),
        title: Text('Raw blocks', style: theme.textTheme.titleMedium),
        subtitle: Text('Block words as read, word 0 first', style: TextStyle(color: scheme.outline)),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SelectableText.rich(
              TextSpan(children: [
                for (final b in values.table.blocks) ...[
                  TextSpan(text: b.label.padRight(28), style: TextStyle(color: scheme.onSurfaceVariant)),
                  for (final w in values.blocks[b.index] ?? const <int>[])
                    TextSpan(text: ' ${w.toRadixString(16).padLeft(8, '0')}', style: TextStyle(color: w == 0 ? scheme.outline : scheme.onSurface)),
                  const TextSpan(text: '\n'),
                ],
              ]),
              style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 12, height: 1.6),
            ),
          ),
        ],
      ),
    );
  }
}
