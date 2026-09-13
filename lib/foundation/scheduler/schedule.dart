import 'cron.dart';

/// How a [ScheduleSpec] decides when the next run happens.
enum ScheduleType {
  /// Fixed delay between runs, measured from the end of the previous run.
  interval,

  /// Friendly preset: once per day at a chosen time.
  daily,

  /// Friendly preset: once per week on chosen weekdays.
  weekly,

  /// Friendly preset: once per month on a chosen day.
  monthly,

  /// A raw 5-field cron expression typed by the user.
  cron,
}

/// A user-facing schedule.
///
/// Interval schedules are handled directly. Every other type is compiled down
/// to a [CronExpression] so that all next-run computation flows through one
/// verified code path -- the friendly presets add no scheduling logic of their
/// own and therefore cannot drift from the cron engine's semantics.
///
/// Schedules are evaluated in the device's local time.
class ScheduleSpec {
  const ScheduleSpec._({
    required this.type,
    this.interval,
    this.cronExpression,
    this.hour = 0,
    this.minute = 0,
    this.weekdays = const [],
    this.dayOfMonth = 1,
  });

  final ScheduleType type;

  /// Only set when [type] is [ScheduleType.interval]. Must be positive.
  final Duration? interval;

  /// Only set when [type] is [ScheduleType.cron]: the raw expression.
  final String? cronExpression;

  /// Hour of day (0-23) for [ScheduleType.daily], [ScheduleType.weekly] and
  /// [ScheduleType.monthly].
  final int hour;

  /// Minute of hour (0-59) for the friendly preset types.
  final int minute;

  /// Cron day-of-week numbers (0 = Sunday .. 6 = Saturday) for
  /// [ScheduleType.weekly]. Must be non-empty for that type.
  final List<int> weekdays;

  /// Day of month (1-31) for [ScheduleType.monthly].
  final int dayOfMonth;

  /// The shortest interval the scheduler accepts.
  ///
  /// Guards against a user configuring a task that hammers comic sites.
  static const Duration minimumInterval = Duration(minutes: 5);

  // ---------------------------------------------------------------------------
  // Constructors
  // ---------------------------------------------------------------------------

  /// Run every [interval], measured from the previous run.
  static ScheduleSpec everyInterval(Duration interval) {
    if (interval.inSeconds < 1) {
      throw ArgumentError('Interval must be positive');
    }
    if (interval < minimumInterval) {
      throw ArgumentError(
        'Interval must be at least ${minimumInterval.inMinutes} minutes, '
        'got ${interval.inMinutes} minutes',
      );
    }
    return ScheduleSpec._(type: ScheduleType.interval, interval: interval);
  }

  /// Run once per day at [hour]:[minute].
  static ScheduleSpec daily({required int hour, required int minute}) {
    _checkTime(hour, minute);
    return ScheduleSpec._(
      type: ScheduleType.daily,
      hour: hour,
      minute: minute,
    );
  }

  /// Run once per week at [hour]:[minute] on each of [weekdays].
  ///
  /// [weekdays] uses cron numbering: 0 = Sunday .. 6 = Saturday. Pass
  /// [weekdaysMondayFirst] to supply Dart's `DateTime.weekday` numbering
  /// (1 = Monday .. 7 = Sunday) instead.
  static ScheduleSpec weekly({
    required Iterable<int> weekdays,
    required int hour,
    required int minute,
  }) {
    _checkTime(hour, minute);
    final raw = weekdays.toList();
    if (raw.isEmpty) {
      throw ArgumentError('At least one weekday is required');
    }
    // Validate the RAW value before normalizing. 0-6 is cron numbering and 7 is
    // accepted as an alias for Sunday, but normalizing first would silently wrap
    // an out-of-range value such as 8 or 14 onto a valid day.
    for (final day in raw) {
      if (day < 0 || day > 7) {
        throw ArgumentError('Weekday out of range (expected 0-7): $day');
      }
    }
    final normalized = raw.map(normalizeWeekday).toSet().toList()..sort();
    return ScheduleSpec._(
      type: ScheduleType.weekly,
      hour: hour,
      minute: minute,
      weekdays: normalized,
    );
  }

  /// Run once per month on [dayOfMonth] at [hour]:[minute].
  ///
  /// Months without that day are skipped, matching cron `31` semantics rather
  /// than clamping to the last day of the month.
  static ScheduleSpec monthly({
    required int dayOfMonth,
    required int hour,
    required int minute,
  }) {
    _checkTime(hour, minute);
    if (dayOfMonth < 1 || dayOfMonth > 31) {
      throw ArgumentError('Day of month must be 1-31, got $dayOfMonth');
    }
    return ScheduleSpec._(
      type: ScheduleType.monthly,
      hour: hour,
      minute: minute,
      dayOfMonth: dayOfMonth,
    );
  }

  /// Run on a raw 5-field cron expression.
  static ScheduleSpec cron(String expression) {
    CronExpression.parse(expression); // validate eagerly
    return ScheduleSpec._(
      type: ScheduleType.cron,
      cronExpression: expression.trim(),
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Folds [weekday] from Dart's `DateTime.weekday` numbering (1 = Monday ..
  /// 7 = Sunday) onto cron numbering (0 = Sunday .. 6 = Saturday).
  static int normalizeWeekday(int weekday) {
    // Dart: Mon=1..Sat=6, Sun=7. Cron: Sun=0, Mon=1..Sat=6.
    return weekday % 7;
  }

  /// Converts a cron day-of-week number to Dart's `DateTime.weekday` numbering.
  static int toDartWeekday(int cronWeekday) {
    return cronWeekday == 0 ? 7 : cronWeekday;
  }

  static void _checkTime(int hour, int minute) {
    if (hour < 0 || hour > 23) {
      throw ArgumentError('Hour must be 0-23, got $hour');
    }
    if (minute < 0 || minute > 59) {
      throw ArgumentError('Minute must be 0-59, got $minute');
    }
  }

  /// The compiled cron expression, or null for interval schedules.
  CronExpression? get asCron {
    switch (type) {
      case ScheduleType.interval:
        return null;
      case ScheduleType.cron:
        return CronExpression.parse(cronExpression!);
      case ScheduleType.daily:
        return CronExpression.parse('$minute $hour * * *');
      case ScheduleType.weekly:
        return CronExpression.parse('$minute $hour * * ${weekdays.join(',')}');
      case ScheduleType.monthly:
        return CronExpression.parse('$minute $hour $dayOfMonth * *');
    }
  }

  /// The first run strictly after [from], or null when there is none.
  ///
  /// For interval schedules this is simply `from + interval`; the engine is
  /// responsible for anchoring that to the previous run's completion time.
  DateTime? nextAfter(DateTime from) {
    if (type == ScheduleType.interval) {
      return from.add(interval!);
    }
    return asCron!.next(from);
  }

  /// Non-null when the spec cannot produce a run within a reasonable horizon.
  ///
  /// Returns a human-readable reason, which the editor UI can surface.
  String? validationError() {
    switch (type) {
      case ScheduleType.interval:
        final value = interval;
        if (value == null || value.inSeconds < 1) {
          return 'Interval must be positive';
        }
        if (value < minimumInterval) {
          return 'Interval must be at least ${minimumInterval.inMinutes} minutes';
        }
        return null;
      case ScheduleType.cron:
        final expression = cronExpression;
        if (expression == null || expression.trim().isEmpty) {
          return 'Cron expression is required';
        }
        if (!CronExpression.isValid(expression)) {
          return 'Invalid cron expression';
        }
        // An expression that never fires in the search horizon is useless and
        // would silently stall the task forever.
        if (asCron!.next(DateTime.now()) == null) {
          return 'Cron expression never matches a date in the next 8 years';
        }
        return null;
      case ScheduleType.daily:
        if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
          return 'Invalid time of day';
        }
        return null;
      case ScheduleType.weekly:
        if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
          return 'Invalid time of day';
        }
        if (weekdays.isEmpty) {
          return 'Select at least one weekday';
        }
        return null;
      case ScheduleType.monthly:
        if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
          return 'Invalid time of day';
        }
        if (dayOfMonth < 1 || dayOfMonth > 31) {
          return 'Day of month must be 1-31';
        }
        return null;
    }
  }

  bool get isValid => validationError() == null;

  static const List<String> _weekdayNames = [
    'Sun',
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
  ];

  /// A short English summary for display, e.g. `Every 6 hours` or
  /// `Mon, Wed at 03:30`.
  ///
  /// The UI translates these by passing the returned text through
  /// `AppTranslation.tl`, which falls back to the English source string.
  String get description {
    String two(int n) => n.toString().padLeft(2, '0');
    final time = '${two(hour)}:${two(minute)}';
    switch (type) {
      case ScheduleType.interval:
        final value = interval!;
        if (value.inMinutes % 60 == 0 && value.inMinutes >= 60) {
          final hours = value.inHours;
          return hours == 1 ? 'Every hour' : 'Every $hours hours';
        }
        final minutes = value.inMinutes;
        return minutes == 1 ? 'Every minute' : 'Every $minutes minutes';
      case ScheduleType.daily:
        return 'Every day at $time';
      case ScheduleType.weekly:
        if (weekdays.length == 7) {
          return 'Every day at $time';
        }
        final names = weekdays.map((d) => _weekdayNames[d]).join(', ');
        return '$names at $time';
      case ScheduleType.monthly:
        return 'Day $dayOfMonth of every month at $time';
      case ScheduleType.cron:
        return 'Cron: $cronExpression';
    }
  }

  // ---------------------------------------------------------------------------
  // Serialization
  // ---------------------------------------------------------------------------

  Map<String, dynamic> toJson() {
    return {
      'type': type.name,
      if (interval != null) 'intervalSeconds': interval!.inSeconds,
      if (cronExpression != null) 'cronExpression': cronExpression,
      if (type != ScheduleType.interval && type != ScheduleType.cron)
        'hour': hour,
      if (type != ScheduleType.interval && type != ScheduleType.cron)
        'minute': minute,
      if (type == ScheduleType.weekly) 'weekdays': weekdays,
      if (type == ScheduleType.monthly) 'dayOfMonth': dayOfMonth,
    };
  }

  /// Rebuilds a spec from [json], or returns null if it is unusable.
  ///
  /// Never throws: persisted data can be corrupt or from an older version, and
  /// a bad schedule must not take the whole task list down.
  static ScheduleSpec? fromJson(Map<String, dynamic> json) {
    try {
      final rawType = json['type'];
      if (rawType is! String) {
        return null;
      }
      final type = ScheduleType.values.firstWhere(
        (t) => t.name == rawType,
        orElse: () => ScheduleType.interval,
      );
      switch (type) {
        case ScheduleType.interval:
          final seconds = json['intervalSeconds'];
          if (seconds is! num || seconds < 1) {
            return null;
          }
          return everyInterval(Duration(seconds: seconds.toInt()));
        case ScheduleType.cron:
          final expression = json['cronExpression'];
          if (expression is! String) {
            return null;
          }
          return ScheduleSpec.cron(expression);
        case ScheduleType.daily:
          return ScheduleSpec.daily(
            hour: (json['hour'] as num).toInt(),
            minute: (json['minute'] as num).toInt(),
          );
        case ScheduleType.weekly:
          return ScheduleSpec.weekly(
            weekdays: (json['weekdays'] as List).cast<num>().map((e) => e.toInt()),
            hour: (json['hour'] as num).toInt(),
            minute: (json['minute'] as num).toInt(),
          );
        case ScheduleType.monthly:
          return ScheduleSpec.monthly(
            dayOfMonth: (json['dayOfMonth'] as num).toInt(),
            hour: (json['hour'] as num).toInt(),
            minute: (json['minute'] as num).toInt(),
          );
      }
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() => description;

  @override
  bool operator ==(Object other) =>
      other is ScheduleSpec &&
      other.type == type &&
      other.interval == interval &&
      other.cronExpression == cronExpression &&
      other.hour == hour &&
      other.minute == minute &&
      other.dayOfMonth == dayOfMonth &&
      _listEquals(other.weekdays, weekdays);

  @override
  int get hashCode => Object.hash(
        type,
        interval,
        cronExpression,
        hour,
        minute,
        dayOfMonth,
        Object.hashAll(weekdays),
      );

  static bool _listEquals(List<int> a, List<int> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }
}
