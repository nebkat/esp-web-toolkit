/// ESP-IDF log timestamps, interpreted, and ways to show them.
library;

/// What a log timestamp counts.
enum TimestampKind {
  /// Milliseconds since boot (`CONFIG_LOG_TIMESTAMP_SOURCE_RTOS`, Log v2's
  /// `MILLISECONDS`, and the system-time sources before the scheduler runs).
  uptime,

  /// `HH:MM:SS.sss`, the device's wall clock without a date (the system-time
  /// source). Counts from midnight at boot until the clock is set.
  timeOfDay,

  /// A point in time: `YY-MM-DD HH:MM:SS.sss` (Log v2's `SYSTEM_FULL`), Unix
  /// milliseconds (Log v2's `UNIX`), or the host's receive time.
  dateTime,
}

/// A log line's timestamp as printed, and what it means.
class LogTimestamp {
  const LogTimestamp._(this.raw, this.kind, this.millis, this.dateTime);

  /// The host's receive time, shown like a device timestamp.
  factory LogTimestamp.host(DateTime at) => LogTimestamp._(_clock(at), TimestampKind.dateTime, at.millisecondsSinceEpoch, at);

  /// As the device printed it.
  final String raw;
  final TimestampKind kind;

  /// Milliseconds: since boot for [TimestampKind.uptime], since midnight for
  /// [TimestampKind.timeOfDay], since the epoch for [TimestampKind.dateTime].
  final int millis;

  /// For [TimestampKind.dateTime], in the host's time zone. A device's
  /// `YY-MM-DD` date carries no zone and is taken to be the host's.
  final DateTime? dateTime;

  // A Unix timestamp in milliseconds is past 2001; an uptime that long isn't
  // plausible. A Unix-source device whose clock isn't set prints a small
  // number, which is its uptime in effect.
  static const _unixFrom = 1000000000000;

  static final _timeOfDay = RegExp(r'^(\d{2}):(\d{2}):(\d{2})\.(\d{3})$');
  static final _full = RegExp(r'^(\d{2,4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})\.(\d{3})$');

  /// Interpret [raw], a timestamp as [MonitorLine.timestamp] holds it.
  /// `null` when it has none of the ESP-IDF forms.
  static LogTimestamp? tryParse(String? raw) {
    if (raw == null) return null;
    final n = int.tryParse(raw);
    if (n != null) {
      if (n < _unixFrom) return LogTimestamp._(raw, TimestampKind.uptime, n, null);
      final at = DateTime.fromMillisecondsSinceEpoch(n);
      return LogTimestamp._(raw, TimestampKind.dateTime, n, at);
    }
    final t = _timeOfDay.firstMatch(raw);
    if (t != null) {
      int g(int i) => int.parse(t[i]!);
      return LogTimestamp._(raw, TimestampKind.timeOfDay, ((g(1) * 60 + g(2)) * 60 + g(3)) * 1000 + g(4), null);
    }
    final f = _full.firstMatch(raw);
    if (f != null) {
      int g(int i) => int.parse(f[i]!);
      // Two digits are years since 2000; three are C's years since 1900.
      final year = g(1) < 100 ? 2000 + g(1) : (g(1) < 1000 ? 1900 + g(1) : g(1));
      final at = DateTime(year, g(2), g(3), g(4), g(5), g(6), g(7));
      return LogTimestamp._(raw, TimestampKind.dateTime, at.millisecondsSinceEpoch, at);
    }
    return null;
  }

  /// Time from [earlier] to this, when the two count the same thing. A
  /// time of day that went past midnight wraps.
  Duration? since(LogTimestamp earlier) {
    if (earlier.kind != kind) return null;
    var ms = millis - earlier.millis;
    if (kind == TimestampKind.timeOfDay && ms < 0) ms += Duration.millisecondsPerDay;
    return Duration(milliseconds: ms);
  }

  @override
  String toString() => raw;
}

/// When the device booted, as the host reckons it from the uptime
/// timestamps of one boot's lines: the earliest receive time less uptime.
/// A line arrives a little after it is printed, never before, so the
/// earliest is the closest.
class BootClock {
  DateTime? _at;
  int _lastUptime = -1;

  /// `null` until a line with an uptime timestamp has been seen.
  DateTime? get at => _at;

  /// The last uptime seen, -1 before any.
  int get lastUptime => _lastUptime;

  void observe(DateTime received, int uptimeMs) {
    _lastUptime = uptimeMs;
    final boot = received.subtract(Duration(milliseconds: uptimeMs));
    if (_at == null || boot.isBefore(_at!)) _at = boot;
  }

  /// The host time of [uptimeMs] in this boot, when known.
  DateTime? atUptime(int uptimeMs) => _at?.add(Duration(milliseconds: uptimeMs));
}

/// How timestamps are shown.
enum TimeDisplay {
  /// As the device printed it.
  raw('As printed'),

  /// Uptimes as `boot+1h 02m 03.456s`, points in time as a full date.
  readable('Readable'),

  /// The host's local time it happened, `HH:MM:SS.sss`; for an uptime, as
  /// estimated (`~HH:MM:SS.sss`), or as with [readable] without an estimate.
  clock('Local time');

  const TimeDisplay(this.label);
  final String label;

  /// [time] shown this way. [estimate] is the host time of a timestamp that
  /// isn't a point in time itself (see [BootClock]).
  String format(LogTimestamp time, {DateTime? estimate}) {
    final at = time.dateTime ?? estimate;
    if (this == raw) return time.raw;
    if (this == clock && at != null) return '${time.dateTime == null ? '~' : ''}${_clock(at)}';
    return switch (time.kind) {
      TimestampKind.uptime => 'boot+${formatDuration(Duration(milliseconds: time.millis))}',
      TimestampKind.timeOfDay => time.raw,
      TimestampKind.dateTime => _date(time.dateTime!),
    };
  }
}

/// Time since [previous] as `+0.012s`, or `null` when the two don't count
/// the same thing or [time] is earlier (an uptime across a reboot).
String? formatDelta(LogTimestamp time, LogTimestamp? previous) {
  final d = previous == null ? null : time.since(previous);
  return d == null || d.isNegative ? null : '+${formatDuration(d)}';
}

String _two(int n) => n.toString().padLeft(2, '0');
String _three(int n) => n.toString().padLeft(3, '0');

String _clock(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}.${_three(t.millisecond)}';

String _date(DateTime t) => '${t.year}-${_two(t.month)}-${_two(t.day)} ${_clock(t)}';

/// `3.456s`, `2m 03.456s`, `1h 02m 03.456s`, `2d 01h 02m 03.456s`.
String formatDuration(Duration d) {
  final ms = d.inMilliseconds.abs();
  final sign = d.isNegative ? '-' : '';
  final seconds = '${ms ~/ 1000 % 60}.${_three(ms % 1000)}s';
  final minutes = ms ~/ 60000 % 60, hours = ms ~/ 3600000 % 24, days = ms ~/ 86400000;
  if (days > 0) return '$sign${days}d ${_two(hours)}h ${_two(minutes)}m ${seconds.padLeft(7, '0')}';
  if (hours > 0) return '$sign${hours}h ${_two(minutes)}m ${seconds.padLeft(7, '0')}';
  if (minutes > 0) return '$sign${minutes}m ${seconds.padLeft(7, '0')}';
  return '$sign$seconds';
}

