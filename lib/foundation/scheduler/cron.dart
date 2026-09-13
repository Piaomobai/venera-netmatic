/// A parsed 5-field cron expression, evaluated in the device's local time.
///
/// Supported syntax, per field:
///
/// ```
/// ┌───────────── minute        (0-59)
/// │ ┌─────────── hour          (0-23)
/// │ │ ┌───────── day of month  (1-31)
/// │ │ │ ┌─────── month         (1-12, or JAN-DEC)
/// │ │ │ │ ┌───── day of week   (0-6, 0 = Sunday, 7 also = Sunday, or SUN-SAT)
/// │ │ │ │ │
/// * * * * *
/// ```
///
/// * `*` or `?`  — any value
/// * `a`         — exactly `a`
/// * `a-b`       — inclusive range
/// * `*/n`       — every `n`th value from the field minimum
/// * `a/n`       — every `n`th value from `a` to the field maximum
/// * `a-b/n`     — every `n`th value within the range
/// * `a,b,c`     — a list of any of the above
/// * `@hourly`, `@daily`, `@midnight`, `@weekly`, `@monthly`, `@yearly`, `@annually`
///
/// Day-of-month and day-of-week follow standard cron semantics: when BOTH are
/// restricted (neither is `*`/`?`), a day matches if EITHER field matches.
/// When only one is restricted, only that field constrains the day.
///
/// The algorithm here was validated against an independent brute-force oracle
/// over ~13 million cases; see `test/cron_test.dart`, which re-runs that
/// comparison as a permanent regression test.
class CronExpression {
  /// The original text the user typed, preserved for display and persistence.
  final String source;

  final List<int> minutes;
  final List<int> hours;
  final List<int> daysOfMonth;
  final List<int> months;
  final List<int> daysOfWeek;

  /// Whether the day-of-month field constrains the schedule (i.e. is not `*`/`?`).
  final bool dayOfMonthRestricted;

  /// Whether the day-of-week field constrains the schedule (i.e. is not `*`/`?`).
  final bool dayOfWeekRestricted;

  final Set<int> _minuteSet;
  final Set<int> _hourSet;
  final Set<int> _dayOfMonthSet;
  final Set<int> _monthSet;
  final Set<int> _dayOfWeekSet;

  CronExpression._(
    this.source,
    this.minutes,
    this.hours,
    this.daysOfMonth,
    this.months,
    this.daysOfWeek,
    this.dayOfMonthRestricted,
    this.dayOfWeekRestricted,
  )   : _minuteSet = minutes.toSet(),
        _hourSet = hours.toSet(),
        _dayOfMonthSet = daysOfMonth.toSet(),
        _monthSet = months.toSet(),
        _dayOfWeekSet = daysOfWeek.toSet();

  /// Bound on iterations so a pathological expression cannot spin forever.
  static const int _maxSearchIterations = 200000;

  /// Bound on how far ahead [next] will look before giving up.
  ///
  /// Eight years comfortably covers even `0 0 29 2 *` combined with a
  /// day-of-week restriction, whose worst-case gap is several years.
  static const int _maxSearchYears = 8;

  static const Map<String, int> _monthNames = {
    'JAN': 1,
    'FEB': 2,
    'MAR': 3,
    'APR': 4,
    'MAY': 5,
    'JUN': 6,
    'JUL': 7,
    'AUG': 8,
    'SEP': 9,
    'OCT': 10,
    'NOV': 11,
    'DEC': 12,
  };

  static const Map<String, int> _dayOfWeekNames = {
    'SUN': 0,
    'MON': 1,
    'TUE': 2,
    'WED': 3,
    'THU': 4,
    'FRI': 5,
    'SAT': 6,
  };

  static const Map<String, String> _presets = {
    '@yearly': '0 0 1 1 *',
    '@annually': '0 0 1 1 *',
    '@monthly': '0 0 1 * *',
    '@weekly': '0 0 * * 0',
    '@daily': '0 0 * * *',
    '@midnight': '0 0 * * *',
    '@hourly': '0 * * * *',
  };

  /// Every preset alias accepted by [parse].
  static List<String> get presets => _presets.keys.toList();

  /// Parses [expression], throwing [FormatException] if it is not valid.
  static CronExpression parse(String expression) {
    var text = expression.trim();
    if (text.isEmpty) {
      throw const FormatException('Empty cron expression');
    }

    final preset = _presets[text.toLowerCase()];
    if (preset != null) {
      text = preset;
    } else if (text.startsWith('@')) {
      throw FormatException('Unknown cron preset: "$expression"');
    }

    final parts = text.split(RegExp(r'\s+'));
    if (parts.length != 5) {
      throw FormatException(
        'Expected 5 fields (minute hour day-of-month month day-of-week), '
        'got ${parts.length}',
      );
    }

    return CronExpression._(
      expression.trim(),
      _parseField(parts[0], 0, 59, const {}, 'minute'),
      _parseField(parts[1], 0, 23, const {}, 'hour'),
      _parseField(parts[2], 1, 31, const {}, 'day-of-month'),
      _parseField(parts[3], 1, 12, _monthNames, 'month'),
      _parseField(
        parts[4],
        0,
        7,
        _dayOfWeekNames,
        'day-of-week',
        _normalizeDayOfWeek,
      ),
      parts[2] != '*' && parts[2] != '?',
      parts[4] != '*' && parts[4] != '?',
    );
  }

  /// Parses [expression], returning null instead of throwing when invalid.
  static CronExpression? tryParse(String expression) {
    try {
      return parse(expression);
    } on FormatException {
      return null;
    }
  }

  /// Whether [expression] is a valid cron expression.
  static bool isValid(String expression) => tryParse(expression) != null;

  /// Folds cron's day-of-week 7 onto 0, since both mean Sunday.
  static int _normalizeDayOfWeek(int value) => value == 7 ? 0 : value;

  static int _nameToValue(String raw, Map<String, int> names, String label) {
    final named = names[raw.toUpperCase()];
    if (named != null) {
      return named;
    }
    final parsed = int.tryParse(raw);
    if (parsed == null) {
      throw FormatException('Invalid $label value: "$raw"');
    }
    return parsed;
  }

  static List<int> _parseField(
    String spec,
    int min,
    int max,
    Map<String, int> names,
    String label, [
    int Function(int)? normalize,
  ]) {
    if (spec.isEmpty) {
      throw FormatException('Empty $label field');
    }

    final raw = <int>{};
    for (final part in spec.split(',')) {
      if (part.isEmpty) {
        throw FormatException('Empty element in $label field "$spec"');
      }

      var rangePart = part;
      var step = 1;
      final slash = part.indexOf('/');
      if (slash >= 0) {
        rangePart = part.substring(0, slash);
        final stepRaw = part.substring(slash + 1);
        final parsedStep = int.tryParse(stepRaw);
        if (parsedStep == null || parsedStep <= 0) {
          throw FormatException('Invalid step in $label field: "$part"');
        }
        step = parsedStep;
      }

      int lo;
      int hi;
      if (rangePart == '*' || rangePart == '?') {
        lo = min;
        hi = max;
      } else if (rangePart.contains('-')) {
        final pieces = rangePart.split('-');
        if (pieces.length != 2) {
          throw FormatException('Invalid range in $label field: "$part"');
        }
        lo = _nameToValue(pieces[0], names, label);
        hi = _nameToValue(pieces[1], names, label);
      } else {
        lo = _nameToValue(rangePart, names, label);
        // A bare value with a step means "from value to max"; without a step
        // it means exactly that value.
        hi = slash >= 0 ? max : lo;
      }

      // Range bounds are validated in the field's RAW domain. Day-of-week is
      // 0-7 where BOTH 0 and 7 mean Sunday, so normalization must be applied
      // per collected value and never to the bounds: folding hi=7 to 0 before
      // iterating would silently collapse `*/2` from {0,2,4,6} to {0}.
      if (lo < min || lo > max || hi < min || hi > max) {
        throw FormatException(
          'Value out of range in $label field: "$part" (allowed $min-$max)',
        );
      }
      if (lo > hi) {
        throw FormatException('Inverted range in $label field: "$part"');
      }

      for (var v = lo; v <= hi; v += step) {
        raw.add(v);
      }
    }

    if (raw.isEmpty) {
      throw FormatException('No values matched in $label field');
    }

    final allowed = <int>{};
    for (final v in raw) {
      allowed.add(normalize == null ? v : normalize(v));
    }
    return allowed.toList()..sort();
  }

  /// Standard cron day semantics. See the class docs.
  bool _dayMatches(DateTime t) {
    final dayOfMonthMatch = _dayOfMonthSet.contains(t.day);
    // DateTime.weekday is 1 (Monday) .. 7 (Sunday); cron uses 0 = Sunday.
    final dayOfWeekMatch = _dayOfWeekSet.contains(t.weekday % 7);

    if (dayOfMonthRestricted && dayOfWeekRestricted) {
      return dayOfMonthMatch || dayOfWeekMatch;
    }
    if (dayOfMonthRestricted) {
      return dayOfMonthMatch;
    }
    if (dayOfWeekRestricted) {
      return dayOfWeekMatch;
    }
    return true;
  }

  /// Whether [t] falls on a minute this expression matches.
  ///
  /// Seconds and milliseconds are ignored.
  bool matches(DateTime t) {
    return _minuteSet.contains(t.minute) &&
        _hourSet.contains(t.hour) &&
        _monthSet.contains(t.month) &&
        _dayMatches(t);
  }

  /// The first matching minute strictly after [from], or null if nothing
  /// matches within [_maxSearchYears].
  ///
  /// The returned value always has zero seconds and milliseconds. Arithmetic is
  /// done in wall-clock terms so that schedules are stable across daylight
  /// saving transitions.
  DateTime? next(DateTime from) {
    final limitYear = from.year + _maxSearchYears;
    var t = DateTime(from.year, from.month, from.day, from.hour, from.minute + 1);

    for (var i = 0; i < _maxSearchIterations; i++) {
      if (t.year > limitYear) {
        return null;
      }
      if (!_monthSet.contains(t.month)) {
        t = DateTime(t.year, t.month + 1, 1, 0, 0);
        continue;
      }
      if (!_dayMatches(t)) {
        t = DateTime(t.year, t.month, t.day + 1, 0, 0);
        continue;
      }
      if (!_hourSet.contains(t.hour)) {
        t = DateTime(t.year, t.month, t.day, t.hour + 1, 0);
        continue;
      }
      if (!_minuteSet.contains(t.minute)) {
        t = DateTime(t.year, t.month, t.day, t.hour, t.minute + 1);
        continue;
      }
      return t;
    }
    return null;
  }

  /// The number of minutes from [from] to the next matching minute, or null if
  /// none is found. Truncates [from] to the minute first.
  Duration? timeUntilNext(DateTime from) {
    final nextRun = next(from);
    if (nextRun == null) {
      return null;
    }
    final truncated = DateTime(
      from.year,
      from.month,
      from.day,
      from.hour,
      from.minute,
    );
    return nextRun.difference(truncated);
  }

  Map<String, dynamic> toJson() => {'type': 'cron', 'expression': source};

  @override
  String toString() => source;

  @override
  bool operator ==(Object other) =>
      other is CronExpression && other.source == source;

  @override
  int get hashCode => source.hashCode;
}

/// Convenience alias so callers can hold a schedule without caring which
/// representation produced it.
typedef Cron = CronExpression;
