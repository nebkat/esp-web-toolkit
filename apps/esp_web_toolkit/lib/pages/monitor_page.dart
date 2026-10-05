import 'dart:async';
import 'dart:js_interop';

import 'package:esp_monitor/esp_monitor.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:web/web.dart' as web;

import '../session/device_session.dart';
import '../util/files.dart';
import '../widgets/dropdown.dart';
import '../widgets/log_overview.dart';

/// The app's serial console: ESP-IDF log lines coloured and parsed, with
/// filtering, timestamps shown in a choice of forms, a context menu on the
/// lines, reset, and a line to send input. Monitoring is a session mode
/// of its own — the chip runs its app, so the bootloader pages are
/// unavailable until it is put back into the bootloader.
class MonitorPage extends StatefulWidget {
  const MonitorPage({super.key, required this.session});
  final DeviceSession session;

  @override
  State<MonitorPage> createState() => _MonitorPageState();
}

class _MonitorPageState extends State<MonitorPage> {
  final _scroll = ScrollController();
  late final _query = TextEditingController(text: log.filter.query);
  final _send = TextEditingController();
  bool _follow = true;
  bool _resetOnStart = true;
  String _ending = '\r\n';
  String? _queryError;

  /// The timestamp under the pointer, shown as printed: a line's sequence
  /// number, and whether it is the host's time rather than the device's.
  final _hover = ValueNotifier<(int, bool)?>(null);
  (int, bool)? _leaving;

  final _menu = MenuController();
  MonitorLine? _menuLine;
  (MonitorLine?, int)? _rightClick;
  String _selection = '';

  /// The browser's own context menu is cancelled over the output, for the
  /// lines' menu. (Turning it off with [BrowserContextMenu] instead would
  /// rebuild the [SelectionArea] under the pointer.)
  bool _overOutput = false;
  late final JSFunction _blockContextMenu = ((web.Event e) {
    if (_overOutput) e.preventDefault();
  }).toJS;

  static const _bauds = [9600, 57600, 74880, 115200, 230400, 460800, 921600, 1500000, 2000000];
  static const _mono = TextStyle(fontFamily: 'RobotoMono', fontSize: 12, height: 1.35);

  DeviceSession get session => widget.session;
  MonitorLog get log => session.monitorLog;

  @override
  void initState() {
    super.initState();
    web.document.addEventListener('contextmenu', _blockContextMenu, true.toJS);
  }

  @override
  void dispose() {
    web.document.removeEventListener('contextmenu', _blockContextMenu, true.toJS);
    _hover.dispose();
    _scroll.dispose();
    _query.dispose();
    _send.dispose();
    super.dispose();
  }

  void _setFilter(MonitorFilter filter) {
    try {
      log.filter = filter;
      if (_queryError != null) setState(() => _queryError = null);
    } on FormatException catch (e) {
      setState(() => _queryError = e.message);
    }
  }

  void _setTimeDisplay(TimeDisplay display) => log.timeDisplay = display;

  void _sendText() {
    session.monitorSend('${_send.text}$_ending');
    _send.clear();
  }

  Future<void> _save() async {
    final stem = session.chip == null ? 'monitor' : '${session.deviceStem}-monitor';
    final text = [for (final line in log.buffer.visible) '${log.hostTime ? '${LogTimestamp.host(line.received).raw}  ' : ''}${line.text}'].join('\n');
    await saveText('$stem.log', '$text\n');
  }

  /// Follow new output while the view is at the very bottom; scrolling up
  /// stops following, scrolling back to the end resumes it.
  bool _onScroll(ScrollUpdateNotification n) {
    final atEnd = n.metrics.pixels >= n.metrics.maxScrollExtent - _unstick / 2;
    if (atEnd != _follow) setState(() => _follow = atEnd);
    return false;
  }

  /// How far the view moves up from the bottom to stop following: too
  /// little to see, enough not to count as at the end.
  static const _unstick = 0.5;

  void _toggleFollow() {
    if (!_follow) return setState(() => _follow = true);
    setState(() => _follow = false);
    if (_scroll.hasClients && _scroll.position.maxScrollExtent >= _unstick) {
      _scroll.jumpTo(_scroll.position.maxScrollExtent - _unstick);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 8), child: _controls()),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: ListenableBuilder(listenable: log, builder: (context, _) => _filters(theme)),
      ),
      Expanded(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: theme.dividerColor),
          ),
          clipBehavior: Clip.antiAlias,
          child: _contextMenu(ListenableBuilder(listenable: Listenable.merge([log, _hover]), builder: (context, _) => _output(theme))),
        ),
      ),
      Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 16), child: _sendRow()),
    ]);
  }

  Widget _controls() {
    final busy = session.busy;
    final monitoring = session.monitoring;
    return Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      AppDropdown<int>(
        value: session.monitorBaud,
        label: 'Baud',
        width: 150,
        enabled: !monitoring && !busy,
        entries: [for (final b in _bauds) DropdownMenuEntry(value: b, label: '$b')],
        onSelected: (b) {
          if (b != null) session.setMonitorBaud(b);
        },
      ),
      if (!monitoring) ...[
        if (!session.connected)
          FilterChip(
            label: const Text('Reset on start'),
            tooltip: 'Reboot the chip when the monitor starts, to see it from boot',
            selected: _resetOnStart,
            onSelected: (v) => setState(() => _resetOnStart = v),
          ),
        FilledButton.icon(
          onPressed: busy || !session.hasDevice ? null : () => session.startMonitor(reset: _resetOnStart),
          icon: const Icon(Icons.play_arrow),
          label: Text(session.connected ? 'Reset into app & monitor' : 'Start monitor'),
        ),
        if (!session.hasDevice) const Text('Choose a port in the bar above first.'),
      ] else ...[
        Chip(
          avatar: session.monitorWaiting
              ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.circle, size: 12, color: Colors.green),
          label: Text(session.monitorWaiting ? 'Waiting for the port…' : 'Monitoring${session.chip == null ? '' : ' ${session.chip!.name}'}'),
        ),
        FilledButton.tonalIcon(onPressed: session.monitorWaiting ? null : session.monitorReset, icon: const Icon(Icons.restart_alt), label: const Text('Reset')),
        FilledButton.tonalIcon(
            onPressed: busy ? null : () => session.stopMonitor(enterBootloader: true), icon: const Icon(Icons.memory), label: const Text('Enter bootloader')),
        OutlinedButton.icon(onPressed: busy ? null : session.stopMonitor, icon: const Icon(Icons.stop), label: const Text('Stop')),
      ],
    ]);
  }

  Widget _filters(ThemeData theme) {
    final filter = log.filter;
    final tags = log.buffer.tags;
    final names = tags.keys.toList()..sort();
    return Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      for (final level in LogLevel.values) _levelChip(level, filter, theme),
      SizedBox(
        width: 340,
        child: TextField(
          controller: _query,
          style: _mono,
          decoration: InputDecoration(
            isDense: true,
            labelText: 'Search',
            errorText: _queryError,
            prefixIcon: const Icon(Icons.search, size: 20),
            suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                tooltip: 'Match case',
                isSelected: filter.caseSensitive,
                icon: const Text('Aa'),
                onPressed: () => _setFilter(filter.copyWith(caseSensitive: !filter.caseSensitive)),
              ),
              IconButton(
                tooltip: 'Regular expression',
                isSelected: filter.regex,
                icon: const Text('.*'),
                onPressed: () => _setFilter(filter.copyWith(regex: !filter.regex)),
              ),
            ]),
          ),
          onChanged: (text) => _setFilter(log.filter.copyWith(query: text)),
        ),
      ),
      MenuAnchor(
        menuChildren: [
          MenuItemButton(
            closeOnActivate: false,
            onPressed: filter.filtersTags ? () => _setFilter(filter.allTags()) : null,
            child: const Text('Show all'),
          ),
          const Divider(height: 1),
          for (final tag in names)
            CheckboxMenuButton(
              value: filter.showsTag(tag),
              closeOnActivate: false,
              onChanged: (v) => _setFilter(log.filter.withTag(tag, shown: v ?? true)),
              trailingIcon: IconButton(
                tooltip: 'Show only $tag',
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                icon: const Icon(Icons.filter_center_focus),
                onPressed: () => _setFilter(log.filter.onlyTag(tag)),
              ),
              child: Text('$tag (${tags[tag]})', style: _mono),
            ),
        ],
        builder: (context, controller, _) => OutlinedButton.icon(
          onPressed: names.isEmpty ? null : () => controller.isOpen ? controller.close() : controller.open(),
          icon: const Icon(Icons.label_outline),
          label: Text(!filter.filtersTags
              ? 'Tags'
              : filter.onlyTags
                  ? 'Tags (${filter.tags.length} shown)'
                  : 'Tags (${filter.tags.length} hidden)'),
        ),
      ),
      FilterChip(label: const Text('Log lines only'), selected: filter.logOnly, onSelected: (v) => _setFilter(filter.copyWith(logOnly: v))),
      AppDropdown<TimeDisplay>(
        value: log.timeDisplay,
        label: 'Timestamps',
        width: 170,
        entries: [for (final d in TimeDisplay.values) DropdownMenuEntry(value: d, label: d.label)],
        onSelected: (d) {
          if (d != null) _setTimeDisplay(d);
        },
      ),
      FilterChip(
        label: const Text('Since previous'),
        tooltip: 'After each timestamp, the time since the line before',
        selected: log.showDelta,
        onSelected: (v) => log.showDelta = v,
      ),
      FilterChip(
        label: const Text('Host time'),
        tooltip: 'When each line arrived',
        selected: log.hostTime,
        onSelected: (v) => log.hostTime = v,
      ),
      if (!filter.isEmpty)
        TextButton(
          onPressed: () {
            _query.clear();
            _setFilter(MonitorFilter.none);
          },
          child: const Text('Clear filters'),
        ),
      Text('${log.buffer.visible.length} of ${log.buffer.lines.length} lines', style: theme.textTheme.labelMedium),
      IconButton(tooltip: 'Save the lines shown', icon: const Icon(Icons.download), onPressed: log.buffer.visible.isEmpty ? null : _save),
      IconButton(tooltip: 'Clear output', icon: const Icon(Icons.clear_all), onPressed: log.clear),
    ]);
  }

  /// A level's chip: shown are the chosen level and those more severe.
  /// Choosing the least severe one shown again shows one level fewer.
  Widget _levelChip(LogLevel level, MonitorFilter filter, ThemeData theme) {
    final selected = level.index <= filter.maxLevel.index;
    return FilterChip(
      selected: selected,
      showCheckmark: false,
      label: Text(level.label.toUpperCase()),
      avatar: Icon(_levelIcon(level), size: 16),
      labelStyle: TextStyle(color: selected ? _levelColour(level, theme.brightness == Brightness.dark) : null),
      onSelected: (_) => _setFilter(filter.copyWith(
        maxLevel: filter.maxLevel == level && level.index > 0 ? LogLevel.values[level.index - 1] : level,
      )),
    );
  }

  static IconData _levelIcon(LogLevel level) => switch (level) {
        LogLevel.error => Icons.error,
        LogLevel.warning => Icons.warning,
        LogLevel.info => Icons.info,
        LogLevel.debug => Icons.bug_report,
        LogLevel.verbose => Icons.details,
      };

  Widget _output(ThemeData theme) {
    final lines = log.buffer.visible;
    final pending = log.buffer.pending;
    final count = lines.length + (pending.isEmpty ? 0 : 1);
    if (count == 0) {
      return Center(
        child: Text(
          session.monitoring ? 'Waiting for output…' : 'Start the monitor to see the device\'s console output.',
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline),
        ),
      );
    }
    if (_follow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _follow && _scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
    final dark = theme.brightness == Brightness.dark;
    final list = Stack(children: [
      NotificationListener<ScrollUpdateNotification>(
        onNotification: _onScroll,
        child: SelectionArea(
          // The lines' own menu (see [_contextMenu]) replaces the selection's.
          contextMenuBuilder: (context, _) => const SizedBox.shrink(),
          onSelectionChanged: (content) => _selection = content?.plainText ?? '',
          // The overview beside the list is its scrollbar.
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.all(8),
            itemCount: count,
            itemBuilder: (context, i) => i < lines.length
                ? Listener(
                    onPointerDown: (e) {
                      if (e.buttons & kSecondaryMouseButton != 0) _rightClick = (lines[i], e.pointer);
                    },
                    child: _row(lines, i, theme, dark),
                  )
                : Text(pending, style: _mono.copyWith(color: theme.colorScheme.outline)),
          ),
        ),
      ),
      Positioned(
        right: 16,
        bottom: 16,
        child: FloatingActionButton.small(
          tooltip: _follow ? 'Following new output: stop' : 'Follow new output',
          backgroundColor: _follow ? theme.colorScheme.primary : theme.colorScheme.surfaceContainerHighest,
          foregroundColor: _follow ? theme.colorScheme.onPrimary : theme.colorScheme.onSurfaceVariant,
          onPressed: _toggleFollow,
          child: Icon(_follow ? Icons.vertical_align_bottom : Icons.arrow_downward),
        ),
      ),
    ]);
    final scheme = theme.colorScheme;
    OverviewMark level(LogLevel l, int rank, double alpha) => (colour: _levelColour(l, dark).withValues(alpha: alpha), rank: rank);
    final marks = {
      LogLevel.error: level(LogLevel.error, 5, 1),
      LogLevel.warning: level(LogLevel.warning, 4, 1),
      LogLevel.info: level(LogLevel.info, 3, 0.4),
      LogLevel.debug: level(LogLevel.debug, 2, 0.4),
      LogLevel.verbose: level(LogLevel.verbose, 1, 0.3),
    };
    final panic = (colour: scheme.error, rank: 6);
    final reset = (colour: scheme.primary, rank: 7);
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(child: ScrollConfiguration(behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false), child: list)),
      DecoratedBox(
        decoration: BoxDecoration(border: Border(left: BorderSide(color: theme.dividerColor))),
        child: SizedBox(
          width: LogOverview.width,
          child: LogOverview(
            lines: lines,
            count: count,
            controller: _scroll,
            mark: (line) => switch (line.kind) {
              LineKind.log => marks[line.level],
              LineKind.panic => panic,
              LineKind.reset => reset,
              _ => null,
            },
          ),
        ),
      ),
    ]);
  }

  Widget _row(List<MonitorLine> lines, int i, ThemeData theme, bool dark) {
    final line = lines[i];
    final previous = i == 0 ? null : lines[i - 1];
    final scheme = theme.colorScheme;
    final display = log.timeDisplay;
    // Firmware built without log colours still gets its levels coloured.
    final levelColour = line.kind == LineKind.log && line.spans.every((s) => s.style.foreground == null) ? _levelColour(line.level!, dark) : null;
    final base = switch (line.kind) {
      LineKind.panic => _mono.copyWith(color: scheme.error, fontWeight: FontWeight.bold),
      LineKind.note => _mono.copyWith(color: scheme.primary, fontStyle: FontStyle.italic),
      _ => _mono.copyWith(color: levelColour),
    };
    final time = line.time;
    final text = Text.rich(
      TextSpan(children: [
        if (log.hostTime) ...[
          _hostTimeSpan(line, previous, display, scheme),
          const TextSpan(text: '  '),
        ],
        ..._lineSpans(
          line,
          dark,
          time == null || (display == TimeDisplay.raw && !log.showDelta)
              ? null
              : (style) {
                  final delta = log.showDelta ? formatDelta(time, _previousTime(lines, i, time.kind)) : null;
                  return TextSpan(children: [
                    display == TimeDisplay.raw
                        ? TextSpan(text: time.raw, style: style)
                        : _timeSpan(time, display.format(time, estimate: line.deviceAt), (line.seq, false), style),
                    if (delta != null) TextSpan(text: ' $delta', style: TextStyle(color: scheme.outline)),
                  ]);
                },
        ),
      ]),
      style: base,
    );
    return switch (line.kind) {
      LineKind.reset when previous?.kind != LineKind.reset => Container(
          margin: const EdgeInsets.only(top: 6),
          padding: const EdgeInsets.only(top: 4),
          decoration: BoxDecoration(border: Border(top: BorderSide(color: scheme.primary, width: 1.5))),
          child: text,
        ),
      LineKind.panic => ColoredBox(color: scheme.errorContainer.withValues(alpha: 0.35), child: text),
      _ => text,
    };
  }

  /// The line's styled spans, with its timestamp replaced by [timestamp]
  /// (given the style it was printed in) when there is one.
  List<InlineSpan> _lineSpans(MonitorLine line, bool dark, InlineSpan Function(TextStyle?)? timestamp) {
    final spans = <InlineSpan>[];
    final start = MonitorLine.timestampStart;
    final end = start + (line.timestamp?.length ?? 0);
    var at = 0;
    for (final span in line.spans) {
      final style = line.kind == LineKind.note ? null : _style(span.style, dark);
      final from = at;
      at += span.text.length;
      if (timestamp == null || at <= start || from >= end) {
        spans.add(TextSpan(text: span.text, style: style));
        continue;
      }
      if (from < start) spans.add(TextSpan(text: span.text.substring(0, start - from), style: style));
      if (from <= start) spans.add(timestamp(style));
      if (at > end) spans.add(TextSpan(text: span.text.substring(end - from), style: style));
    }
    return spans;
  }

  /// The timestamp of the nearest line before [i] that counts the same
  /// thing, for [MonitorLog.showDelta].
  LogTimestamp? _previousTime(List<MonitorLine> lines, int i, TimestampKind kind) {
    for (var j = i - 1; j >= 0 && j >= i - 200; j--) {
      final time = lines[j].time;
      if (time != null) return time.kind == kind ? time : null;
    }
    return null;
  }

  InlineSpan _hostTimeSpan(MonitorLine line, MonitorLine? previous, TimeDisplay display, ColorScheme scheme) {
    final time = LogTimestamp.host(line.received);
    final style = TextStyle(color: scheme.outline);
    // The host's own "as printed" is the time of day; under the pointer it is the full date.
    final span = _timeSpan(time, display.format(time).padRight(12), (line.seq, true), style,
        hovered: TimeDisplay.readable.format(time), underline: display != TimeDisplay.raw);
    if (!log.showDelta) return span;
    final delta = previous == null ? null : formatDelta(time, LogTimestamp.host(previous.received));
    return TextSpan(children: [span, TextSpan(text: ' ${(delta ?? '').padRight(8)}', style: style)]);
  }

  /// A timestamp shown as [shown], and as [hovered] (as printed, unless
  /// given) under the pointer.
  InlineSpan _timeSpan(LogTimestamp time, String shown, (int, bool) key, TextStyle? style, {String? hovered, bool underline = true}) {
    hovered ??= time.raw;
    // The text under the pointer mustn't shrink away from it.
    final text = _hover.value == key ? hovered.padRight(shown.length) : shown;
    return TextSpan(
      text: text,
      style: (style ?? const TextStyle()).copyWith(
        decoration: underline ? TextDecoration.underline : null,
        decorationStyle: TextDecorationStyle.dotted,
      ),
      mouseCursor: SystemMouseCursors.help,
      // A rebuilt line's span is a new one: the old one's exit comes with the new one's
      // enter, so an exit only counts once nothing has taken the hover back.
      onEnter: (_) {
        _leaving = null;
        _hover.value = key;
      },
      onExit: (_) {
        _leaving = key;
        scheduleMicrotask(() {
          if (_leaving == key && _hover.value == key) _hover.value = null;
          if (_leaving == key) _leaving = null;
        });
      },
    );
  }

  /// The right-click menu over the output: what a line's level and tag
  /// allow, copying, and how times are shown.
  Widget _contextMenu(Widget child) {
    return MouseRegion(
      onEnter: (_) => _overOutput = true,
      onExit: (_) => _overOutput = false,
      child: Listener(
        // A line's own listener sees the press first; elsewhere it opens the menu without a line.
        onPointerDown: (e) {
          if (e.buttons & kSecondaryMouseButton != 0 && _rightClick?.$2 != e.pointer) _rightClick = (null, e.pointer);
        },
        onPointerUp: (e) {
          final click = _rightClick;
          if (click == null || click.$2 != e.pointer) return;
          _rightClick = null;
          setState(() => _menuLine = click.$1);
          _menu.open(position: e.localPosition);
        },
        child: Stack(children: [
          child,
          // The anchor is a point, not the output: the menu counts a tap on its anchor as inside it.
          Positioned(
            left: 0,
            top: 0,
            child: MenuAnchor(
              controller: _menu,
              consumeOutsideTap: true,
              menuChildren: _menuItems(_menuLine),
              child: const SizedBox.shrink(),
            ),
          ),
        ]),
      ),
    );
  }

  List<Widget> _menuItems(MonitorLine? line) {
    final filter = log.filter;
    final tag = line?.tag;
    final level = line?.level;
    final selection = _selection.trim();
    final searchable = selection.isNotEmpty && !selection.contains('\n') && selection.length <= 80;
    void copy(String text) => Clipboard.setData(ClipboardData(text: text));
    String quoted(String text) => '“${text.length > 24 ? '${text.substring(0, 24)}…' : text}”';
    return [
      if (selection.isNotEmpty)
        MenuItemButton(leadingIcon: const Icon(Icons.copy, size: 18), onPressed: () => copy(_selection), child: const Text('Copy selection')),
      if (line != null) MenuItemButton(leadingIcon: const Icon(Icons.subject, size: 18), onPressed: () => copy(line.text), child: const Text('Copy line')),
      if (line?.message case final message?) MenuItemButton(onPressed: () => copy(message), child: const Text('Copy message')),
      if (line?.time case final time?)
        MenuItemButton(
          onPressed: () => copy(time.raw),
          child: Text('Copy timestamp${log.timeDisplay == TimeDisplay.raw ? '' : ' (as printed)'}'),
        ),
      if (selection.isNotEmpty || line != null) const Divider(height: 1),
      if (tag != null) ...[
        MenuItemButton(
          leadingIcon: const Icon(Icons.visibility_off_outlined, size: 18),
          onPressed: () => _setFilter(filter.withTag(tag, shown: false)),
          child: Text('Hide tag $tag'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.filter_center_focus, size: 18),
          onPressed: filter.onlyTags && filter.tags.length == 1 && filter.tags.contains(tag) ? null : () => _setFilter(filter.onlyTag(tag)),
          child: Text('Show only tag $tag'),
        ),
      ],
      if (filter.filtersTags) MenuItemButton(onPressed: () => _setFilter(filter.allTags()), child: const Text('Show all tags')),
      if (level != null && level != filter.maxLevel)
        MenuItemButton(
          leadingIcon: const Icon(Icons.filter_list, size: 18),
          onPressed: () => _setFilter(filter.copyWith(maxLevel: level)),
          child: Text(level == LogLevel.values.last ? 'Show all levels' : 'Show ${level.label} and above'),
        ),
      if (searchable)
        MenuItemButton(
          leadingIcon: const Icon(Icons.search, size: 18),
          onPressed: () {
            _query.text = selection;
            _setFilter(filter.copyWith(query: selection, regex: false));
          },
          child: Text('Search for ${quoted(selection)}'),
        ),
      CheckboxMenuButton(
        value: filter.logOnly,
        onChanged: (v) => _setFilter(filter.copyWith(logOnly: v ?? false)),
        child: const Text('Log lines only'),
      ),
      if (!filter.isEmpty)
        MenuItemButton(
          onPressed: () {
            _query.clear();
            _setFilter(MonitorFilter.none);
          },
          child: const Text('Clear filters'),
        ),
      const Divider(height: 1),
      SubmenuButton(
        leadingIcon: const Icon(Icons.schedule, size: 18),
        menuChildren: [
          for (final d in TimeDisplay.values)
            RadioMenuButton(value: d, groupValue: log.timeDisplay, onChanged: (d) => _setTimeDisplay(d!), child: Text(d.label)),
          const Divider(height: 1),
          CheckboxMenuButton(value: log.showDelta, onChanged: (v) => log.showDelta = v ?? false, child: const Text('Since previous')),
          CheckboxMenuButton(value: log.hostTime, onChanged: (v) => log.hostTime = v ?? false, child: const Text('Host time')),
        ],
        child: const Text('Timestamps'),
      ),
    ];
  }

  static TextStyle? _style(AnsiStyle style, bool dark) {
    if (style.isPlain) return null;
    var foreground = ansiColour(style.foreground, dark);
    var background = ansiColour(style.background, dark);
    if (style.reverse) {
      final swapped = background ?? (dark ? const Color(0xFF1E1E1E) : Colors.white);
      background = foreground ?? (dark ? Colors.white : Colors.black);
      foreground = swapped;
    }
    return TextStyle(
      color: foreground,
      backgroundColor: background,
      fontWeight: style.bold ? FontWeight.bold : null,
      fontStyle: style.italic ? FontStyle.italic : null,
      decoration: style.underline ? TextDecoration.underline : null,
    );
  }

  static Color _levelColour(LogLevel level, bool dark) => switch (level) {
        LogLevel.error => ansiColour(1, dark)!,
        LogLevel.warning => ansiColour(3, dark)!,
        LogLevel.info => ansiColour(2, dark)!,
        LogLevel.debug || LogLevel.verbose => dark ? const Color(0xFF9E9E9E) : const Color(0xFF616161),
      };

  Widget _sendRow() {
    final enabled = session.monitoring && !session.monitorWaiting;
    return Row(children: [
      Expanded(
        child: TextField(
          controller: _send,
          enabled: enabled,
          style: _mono,
          decoration: const InputDecoration(isDense: true, labelText: 'Send to device', prefixIcon: Icon(Icons.keyboard, size: 20)),
          onSubmitted: (_) => _sendText(),
        ),
      ),
      const SizedBox(width: 8),
      AppDropdown<String>(
        value: _ending,
        label: 'Line ending',
        width: 150,
        entries: const [
          DropdownMenuEntry(value: '', label: 'None'),
          DropdownMenuEntry(value: '\n', label: 'LF'),
          DropdownMenuEntry(value: '\r', label: 'CR'),
          DropdownMenuEntry(value: '\r\n', label: 'CR LF'),
        ],
        onSelected: (v) => setState(() => _ending = v ?? _ending),
      ),
      const SizedBox(width: 8),
      FilledButton.icon(onPressed: enabled ? _sendText : null, icon: const Icon(Icons.send), label: const Text('Send')),
    ]);
  }
}

/// A terminal palette colour for [index] (see [AnsiStyle]), readable on the
/// theme's background.
Color? ansiColour(int? index, bool dark) {
  if (index == null) return null;
  if (index & AnsiStyle.rgbFlag != 0) return Color(0xFF000000 | (index & 0xFFFFFF));
  if (index < 16) return (dark ? _darkPalette : _lightPalette)[index];
  if (index < 232) {
    final i = index - 16;
    int level(int v) => v == 0 ? 0 : 55 + v * 40;
    return Color.fromARGB(255, level(i ~/ 36), level(i ~/ 6 % 6), level(i % 6));
  }
  final grey = 8 + (index - 232) * 10;
  return Color.fromARGB(255, grey, grey, grey);
}

const _lightPalette = [
  Color(0xFF000000), Color(0xFFC62828), Color(0xFF2E7D32), Color(0xFF9A6700), //
  Color(0xFF1565C0), Color(0xFF8E24AA), Color(0xFF00838F), Color(0xFF616161),
  Color(0xFF424242), Color(0xFFE53935), Color(0xFF43A047), Color(0xFFB8860B),
  Color(0xFF1E88E5), Color(0xFFAB47BC), Color(0xFF00ACC1), Color(0xFF212121),
];

const _darkPalette = [
  Color(0xFF757575), Color(0xFFEF5350), Color(0xFF66BB6A), Color(0xFFFFCA28), //
  Color(0xFF42A5F5), Color(0xFFBA68C8), Color(0xFF26C6DA), Color(0xFFE0E0E0),
  Color(0xFF9E9E9E), Color(0xFFFF7961), Color(0xFF98EE99), Color(0xFFFFF176),
  Color(0xFF80D6FF), Color(0xFFE1BEE7), Color(0xFF84FFFF), Color(0xFFFFFFFF),
];
