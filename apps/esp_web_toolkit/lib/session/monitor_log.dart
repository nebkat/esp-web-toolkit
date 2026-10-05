import 'dart:async';

import 'package:esp_monitor/esp_monitor.dart';
import 'package:flutter/foundation.dart';

/// The monitor's output as a [ChangeNotifier] of its own, so a chatty
/// console repaints the monitor view — at most ~20 times a second — rather
/// than the whole app on every chunk.
class MonitorLog extends ChangeNotifier {
  final MonitorBuffer buffer = MonitorBuffer();
  Timer? _notify;

  void add(List<int> bytes) {
    buffer.add(bytes);
    _schedule();
  }

  /// A host line in the stream ("monitor started").
  void note(String text) {
    buffer.note(text);
    _schedule();
  }

  /// Complete any pending partial line.
  void flush() {
    buffer.flush();
    _schedule();
  }

  void clear() {
    buffer.clear();
    notifyListeners();
  }

  MonitorFilter get filter => buffer.filter;

  /// Throws [FormatException] for an invalid regular expression, leaving the
  /// filter as it was.
  set filter(MonitorFilter value) {
    buffer.filter = value;
    notifyListeners();
  }

  /// How the view shows the device's timestamps (and the host's).
  TimeDisplay get timeDisplay => _timeDisplay;
  TimeDisplay _timeDisplay = TimeDisplay.readable;
  set timeDisplay(TimeDisplay value) {
    _timeDisplay = value;
    notifyListeners();
  }

  /// Whether the view shows, after each timestamp, the time since the
  /// previous line's.
  bool get showDelta => _showDelta;
  bool _showDelta = false;
  set showDelta(bool value) {
    _showDelta = value;
    notifyListeners();
  }

  /// Whether the view shows when each line arrived.
  bool get hostTime => _hostTime;
  bool _hostTime = false;
  set hostTime(bool value) {
    _hostTime = value;
    notifyListeners();
  }

  void _schedule() => _notify ??= Timer(const Duration(milliseconds: 50), () {
        _notify = null;
        notifyListeners();
      });

  @override
  void dispose() {
    _notify?.cancel();
    super.dispose();
  }
}
