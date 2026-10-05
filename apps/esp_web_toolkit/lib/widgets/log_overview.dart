import 'dart:math' as math;

import 'package:esp_monitor/esp_monitor.dart';
import 'package:flutter/material.dart';

/// How a line shows on a [LogOverview]: its colour, and how much it
/// matters when lines share a pixel — the higher rank wins.
typedef OverviewMark = ({Color colour, int rank});

/// A scrollbar for the monitor's output that shows where the errors,
/// warnings and other marked lines are along its length.
///
/// Lines are placed by their index, not their pixel offset — the list
/// doesn't know the latter for lines it hasn't laid out — so a run of
/// wrapped lines shifts the marks a little from the scroll position.
class LogOverview extends StatefulWidget {
  const LogOverview({super.key, required this.lines, required this.count, required this.controller, required this.mark});

  final List<MonitorLine> lines;

  /// Rows in the list: [lines] and, possibly, the pending line after them.
  final int count;
  final ScrollController controller;

  /// The mark for a line, or `null` for none.
  final OverviewMark? Function(MonitorLine line) mark;

  static const width = 14.0;

  @override
  State<LogOverview> createState() => _LogOverviewState();
}

class _LogOverviewState extends State<LogOverview> {
  /// Where in the thumb the pointer took hold of it, while dragging.
  double? _grab;

  /// The thumb's top and height, in the strip's pixels; `null` before the
  /// list is laid out.
  (double, double)? _thumb(double height) {
    final c = widget.controller;
    if (!c.hasClients || !c.position.hasContentDimensions || !c.position.hasViewportDimension) return null;
    final p = c.position;
    final total = p.maxScrollExtent + p.viewportDimension;
    if (total <= 0) return null;
    final size = (p.viewportDimension / total * height).clamp(16.0, height);
    final top = p.maxScrollExtent <= 0 ? 0.0 : p.pixels / p.maxScrollExtent * (height - size);
    return (top, size);
  }

  void _start(double y, double height) {
    final thumb = _thumb(height);
    if (thumb == null) return;
    final (top, size) = thumb;
    // Holding the thumb drags it from where it was taken; elsewhere it centres on the pointer.
    _grab = y >= top && y <= top + size ? y - top : size / 2;
    _drag(y, height);
  }

  void _drag(double y, double height) {
    final thumb = _thumb(height);
    final grab = _grab;
    if (thumb == null || grab == null) return;
    final p = widget.controller.position;
    final free = height - thumb.$2;
    final fraction = free <= 0 ? 0.0 : ((y - grab) / free).clamp(0.0, 1.0);
    widget.controller.jumpTo(fraction * p.maxScrollExtent);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, constraints) {
      final height = constraints.maxHeight;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) {
          _start(d.localPosition.dy, height);
          _grab = null;
        },
        onVerticalDragStart: (d) => _start(d.localPosition.dy, height),
        onVerticalDragUpdate: (d) => _drag(d.localPosition.dy, height),
        onVerticalDragEnd: (_) => _grab = null,
        child: CustomPaint(
          size: Size(LogOverview.width, height),
          painter: _MarksPainter(widget.lines, widget.count, widget.mark),
          foregroundPainter: _ThumbPainter(this, scheme.onSurface),
        ),
      );
    });
  }
}

class _MarksPainter extends CustomPainter {
  _MarksPainter(this.lines, this.count, this.mark);

  final List<MonitorLine> lines;
  final int count;
  final OverviewMark? Function(MonitorLine) mark;

  @override
  void paint(Canvas canvas, Size size) {
    final rows = size.height.floor();
    if (rows <= 0 || count == 0) return;
    // The winning mark for each pixel row. A line taller than a pixel (few lines) fills its rows;
    // a mark is at least two pixels, so a lone error among thousands of lines still shows.
    final marks = List<OverviewMark?>.filled(rows, null);
    final perLine = size.height / count;
    for (var i = 0; i < lines.length; i++) {
      final m = mark(lines[i]);
      if (m == null) continue;
      final from = (i * perLine).floor().clamp(0, rows - 1);
      final to = math.min(math.max(((i + 1) * perLine).ceil(), from + 2), rows);
      for (var y = from; y < to; y++) {
        final current = marks[y];
        if (current == null || m.rank > current.rank) marks[y] = m;
      }
    }
    final paint = Paint();
    var y = 0;
    while (y < rows) {
      final m = marks[y];
      var end = y + 1;
      while (end < rows && marks[end] == m) {
        end++;
      }
      if (m != null) {
        paint.color = m.colour;
        canvas.drawRect(Rect.fromLTWH(3, y.toDouble(), size.width - 6, (end - y).toDouble()), paint);
      }
      y = end;
    }
  }

  @override
  bool shouldRepaint(_MarksPainter old) => true;
}

class _ThumbPainter extends CustomPainter {
  _ThumbPainter(this.state, this.colour) : super(repaint: state.widget.controller);

  final _LogOverviewState state;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final thumb = state._thumb(size.height);
    if (thumb == null) return;
    final rect = RRect.fromRectAndRadius(Rect.fromLTWH(0.5, thumb.$1 + 0.5, size.width - 1, thumb.$2 - 1), const Radius.circular(3));
    canvas.drawRRect(rect, Paint()..color = colour.withValues(alpha: 0.22));
    canvas.drawRRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = colour.withValues(alpha: 0.6),
    );
  }

  // The list's extent changes as lines arrive, without a scroll.
  @override
  bool shouldRepaint(_ThumbPainter old) => true;
}
