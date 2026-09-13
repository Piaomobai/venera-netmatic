import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/scheduler/cron.dart';

// ============================================================================
// Differential test for CronExpression.
//
// CronExpression uses an O(fields) "advance to the next candidate" algorithm.
// That is fast but easy to get subtly wrong (step handling, the day-of-month /
// day-of-week OR rule, month and leap-year rollover). So every result is
// cross-checked against a deliberately naive oracle defined further down:
// it expands each field by testing every candidate value and finds the next run
// by scanning minute by minute.
//
// The two implementations share no code, so a bug cannot hide in both.
// The same comparison was first run against a JavaScript mirror of the
// algorithm while the Dart toolchain was unavailable; this file is the
// permanent in-repo version of that check.
// ============================================================================

// ---------------------------------------------------------------------------
// Oracle: independent, obviously-correct, slow.
// ---------------------------------------------------------------------------

const _monthNames = {
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

const _dayOfWeekNames = {
  'SUN': 0,
  'MON': 1,
  'TUE': 2,
  'WED': 3,
  'THU': 4,
  'FRI': 5,
  'SAT': 6,
};

const _presets = {
  '@yearly': '0 0 1 1 *',
  '@annually': '0 0 1 1 *',
  '@monthly': '0 0 1 * *',
  '@weekly': '0 0 * * 0',
  '@daily': '0 0 * * *',
  '@midnight': '0 0 * * *',
  '@hourly': '0 * * * *',
};

int _toValue(String raw, Map<String, int> names) {
  final named = names[raw.toUpperCase()];
  if (named != null) {
    return named;
  }
  return int.parse(raw);
}

/// Does one comma-separated element match candidate [v]?
///
/// Written by testing membership directly rather than by walking ranges.
bool _elementMatches(
  String element,
  int v,
  int min,
  int max,
  Map<String, int> names,
) {
  if (element == '*' || element == '?') {
    return true;
  }
  var body = element;
  var step = 1;
  final slash = element.indexOf('/');
  if (slash >= 0) {
    body = element.substring(0, slash);
    step = int.parse(element.substring(slash + 1));
  }

  int lo;
  int hi;
  if (body == '*' || body == '?') {
    lo = min;
    hi = max;
  } else if (body.contains('-')) {
    final bits = body.split('-');
    lo = _toValue(bits[0], names);
    hi = _toValue(bits[1], names);
  } else {
    lo = _toValue(body, names);
    hi = slash >= 0 ? max : lo;
  }

  if (v < lo || v > hi) {
    return false;
  }
  return (v - lo) % step == 0;
}

List<int> _expand(String spec, int min, int max, Map<String, int> names) {
  final out = <int>[];
  for (var v = min; v <= max; v++) {
    for (final element in spec.split(',')) {
      if (_elementMatches(element, v, min, max, names)) {
        out.add(v);
        break;
      }
    }
  }
  return out;
}

class _OracleCron {
  _OracleCron(String source) {
    var text = source.trim();
    final preset = _presets[text.toLowerCase()];
    if (preset != null) {
      text = preset;
    }
    final parts = text.split(RegExp(r'\s+'));
    if (parts.length != 5) {
      throw FormatException('bad field count: ${parts.length}');
    }
    minutes = _expand(parts[0], 0, 59, const {});
    hours = _expand(parts[1], 0, 23, const {});
    daysOfMonth = _expand(parts[2], 1, 31, const {});
    months = _expand(parts[3], 1, 12, _monthNames);
    // Day-of-week: expand over 0..7, then fold 7 onto 0.
    final rawDow = _expand(parts[4], 0, 7, _dayOfWeekNames);
    daysOfWeek = rawDow.map((v) => v == 7 ? 0 : v).toSet().toList()..sort();
    dayOfMonthRestricted = parts[2] != '*' && parts[2] != '?';
    dayOfWeekRestricted = parts[4] != '*' && parts[4] != '?';
  }

  late final List<int> minutes;
  late final List<int> hours;
  late final List<int> daysOfMonth;
  late final List<int> months;
  late final List<int> daysOfWeek;
  late final bool dayOfMonthRestricted;
  late final bool dayOfWeekRestricted;

  bool matches(DateTime t) {
    if (!minutes.contains(t.minute)) {
      return false;
    }
    if (!hours.contains(t.hour)) {
      return false;
    }
    if (!months.contains(t.month)) {
      return false;
    }
    final domMatch = daysOfMonth.contains(t.day);
    final dowMatch = daysOfWeek.contains(t.weekday % 7);
    if (dayOfMonthRestricted && dayOfWeekRestricted) {
      return domMatch || dowMatch;
    }
    if (dayOfMonthRestricted) {
      return domMatch;
    }
    if (dayOfWeekRestricted) {
      return dowMatch;
    }
    return true;
  }

  /// Brute-force minute-by-minute scan.
  DateTime? next(DateTime from, int maxMinutes) {
    var t = DateTime(from.year, from.month, from.day, from.hour, from.minute + 1);
    for (var i = 0; i < maxMinutes; i++) {
      if (matches(t)) {
        return t;
      }
      t = DateTime(t.year, t.month, t.day, t.hour, t.minute + 1);
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// Deterministic PRNG so failures reproduce exactly.
// ---------------------------------------------------------------------------
class _Rng {
  _Rng(this._state);

  int _state;

  double next() {
    _state = (_state * 1664525 + 1013904223) & 0xFFFFFFFF;
    return _state / 4294967296;
  }

  int pick(int max) => (next() * max).floor();
}

// ---------------------------------------------------------------------------
// Corpus: one expression per syntax feature.
// ---------------------------------------------------------------------------
const _corpus = <String>[
  '* * * * *',
  '0 * * * *',
  '0 0 * * *',
  '@daily',
  '@hourly',
  '@weekly',
  '@monthly',
  '@yearly',
  '@midnight',
  '@annually',
  '30 3 * * *',
  '*/5 * * * *',
  '*/17 * * * *',
  '0,15,30,45 * * * *',
  '5-20 * * * *',
  '5-55/10 * * * *',
  '7/13 * * * *',
  '0 */2 * * *',
  '0 9-17 * * *',
  '0 1-23/7 * * *',
  '0 22/2 * * *',
  '0 0,12 * * *',
  '0 0 1 * *',
  '0 0 15 * *',
  '0 0 1,15 * *',
  '0 0 */3 * *',
  '0 0 10-20 * *',
  '0 0 1-7/2 * *',
  '0 0 * * 0',
  '0 0 * * 7',
  '0 0 * * MON',
  '0 0 * * mon-fri',
  '0 0 * * 0,6',
  '0 0 * * SAT,SUN',
  '0 0 * * */2',
  '0 0 * 1 *',
  '0 0 * JAN *',
  '0 0 * */3 *',
  '0 0 * 1,6,12 *',
  '0 0 * MAR-JUN *',
  '0 0 * 2-11/3 *',
  '0 0 1 1 *',
  '0 0 29 2 *',
  '0 0 31 * *',
  '15 2 1,15 1,4,7,10 *',
  '0 0 ? * MON',
  '0 0 1 * ?',
  '30 4 1,15 * 5',
  '0 0 13 * 5',
  '0 0 1 * 0',
  '23 0-20/2 * * *',
  '0 0,12 1 */2 *',
  '0 0 * * 1-5',
  '0 6 * * 1',
];

const _minutePool = [
  '*', '0', '15', '30', '45', '*/5', '*/17', '0,30', '5-20', '5-55/10',
  '7/13', '1,2,3',
];
const _hourPool = [
  '*', '0', '3', '12', '23', '*/2', '*/5', '9-17', '0,12', '1-23/7', '22/2',
];
const _domPool = [
  '*', '?', '1', '15', '29', '31', '1,15', '*/3', '10-20', '1-7/2',
];
const _monthPool = [
  '*', '1', '2', '6', '12', 'JAN', '*/3', '1,6,12', 'MAR-JUN', '2-11/3', 'DEC',
];
const _dowPool = [
  '*', '?', '0', '1', '5', '6', '7', 'MON', 'MON-FRI', '0,6', '*/2', 'SAT,SUN',
  'WED',
];

String _randomExpression(_Rng rng) => [
      _minutePool[rng.pick(_minutePool.length)],
      _hourPool[rng.pick(_hourPool.length)],
      _domPool[rng.pick(_domPool.length)],
      _monthPool[rng.pick(_monthPool.length)],
      _dowPool[rng.pick(_dowPool.length)],
    ].join(' ');

DateTime _randomStart(_Rng rng) => DateTime(
      2024 + rng.pick(4),
      rng.pick(12),
      1 + rng.pick(28),
      rng.pick(24),
      rng.pick(60),
      rng.pick(60),
    );

String _fmt(DateTime? d) {
  if (d == null) {
    return 'null';
  }
  String p(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}'
      ' (dow=${d.weekday % 7})';
}

void main() {
  group('CronExpression validation', () {
    test('rejects malformed expressions', () {
      const invalid = [
        '',
        '   ',
        '* * * *',
        '* * * * * *',
        '60 * * * *',
        '* 24 * * *',
        '* * 0 * *',
        '* * 32 * *',
        '* * * 0 *',
        '* * * 13 *',
        '* * * * 8',
        '*/0 * * * *',
        'a * * * *',
        '*-5 * * * *',
        '5-1 * * * *',
        '@nonsense',
        '1-2-3 * * * *',
      ];
      for (final expr in invalid) {
        expect(
          CronExpression.tryParse(expr),
          isNull,
          reason: '"$expr" should be rejected',
        );
        expect(() => CronExpression.parse(expr), throwsFormatException);
      }
    });

    test('accepts valid edge syntax', () {
      const valid = [
        '0 0 * * 7',
        '0 0 * * SUN',
        '5/15 * * * *',
        '@daily',
        '0 0 ? * MON',
        '  0 0 * * *  ',
      ];
      for (final expr in valid) {
        expect(
          CronExpression.isValid(expr),
          isTrue,
          reason: '"$expr" should be valid',
        );
      }
    });

    test('day-of-week 7 and 0 both mean Sunday', () {
      final seven = CronExpression.parse('0 0 * * 7');
      final zero = CronExpression.parse('0 0 * * 0');
      expect(seven.daysOfWeek, [0]);
      expect(zero.daysOfWeek, [0]);
      expect(seven.daysOfWeek, zero.daysOfWeek);
    });

    test('day-of-week step expands over the raw 0-7 domain', () {
      // Regression guard: folding 7 -> 0 before iterating would collapse this
      // to {0} instead of {0,2,4,6}.
      expect(CronExpression.parse('0 0 * * */2').daysOfWeek, [0, 2, 4, 6]);
      expect(CronExpression.parse('0 0 * * 1-5').daysOfWeek, [1, 2, 3, 4, 5]);
      expect(CronExpression.parse('0 0 * * 5-7').daysOfWeek, [0, 5, 6]);
      expect(CronExpression.parse('0 0 * * mon-fri').daysOfWeek, [1, 2, 3, 4, 5]);
    });

    test('presets expand to their documented expressions', () {
      expect(CronExpression.parse('@daily').next(DateTime(2025, 1, 1, 12, 0)),
          DateTime(2025, 1, 2, 0, 0));
      expect(CronExpression.parse('@hourly').next(DateTime(2025, 1, 1, 12, 30)),
          DateTime(2025, 1, 1, 13, 0));
      expect(CronExpression.parse('@weekly').next(DateTime(2025, 1, 1, 0, 0)),
          DateTime(2025, 1, 5, 0, 0)); // Sunday
      expect(CronExpression.parse('@monthly').next(DateTime(2025, 1, 5, 0, 0)),
          DateTime(2025, 2, 1, 0, 0));
      expect(CronExpression.parse('@yearly').next(DateTime(2025, 5, 5, 0, 0)),
          DateTime(2026, 1, 1, 0, 0));
    });
  });

  group('CronExpression semantics', () {
    test('next() is strictly after the given instant', () {
      final c = CronExpression.parse('0 0 1 * *');
      // Exactly on a match: must roll forward, not return the same minute.
      expect(c.next(DateTime(2025, 1, 1, 0, 0)), DateTime(2025, 2, 1, 0, 0));
      expect(c.next(DateTime(2025, 1, 1, 0, 1)), DateTime(2025, 2, 1, 0, 0));
      expect(c.next(DateTime(2025, 1, 31, 23, 59)), DateTime(2025, 2, 1, 0, 0));
    });

    test('seconds and milliseconds are truncated', () {
      final c = CronExpression.parse('*/15 * * * *');
      expect(c.next(DateTime(2025, 1, 1, 10, 7, 42, 500)), DateTime(2025, 1, 1, 10, 15));
      expect(c.next(DateTime(2025, 1, 1, 10, 0, 0, 0)), DateTime(2025, 1, 1, 10, 15));
    });

    test('day-of-month alone constrains the day', () {
      final c = CronExpression.parse('0 0 13 * *');
      expect(c.next(DateTime(2025, 1, 1, 0, 0)), DateTime(2025, 1, 13, 0, 0));
      expect(c.next(DateTime(2025, 1, 13, 0, 0)), DateTime(2025, 2, 13, 0, 0));
    });

    test('day-of-week alone constrains the day', () {
      // 2025-01-01 is a Wednesday; the next Monday is 2025-01-06.
      final c = CronExpression.parse('0 0 * * 1');
      expect(c.next(DateTime(2025, 1, 1, 0, 0)), DateTime(2025, 1, 6, 0, 0));
    });

    test('both day fields restricted means OR, not AND', () {
      // 2025-01-03 is a Friday, 2025-01-13 is a Monday.
      final c = CronExpression.parse('0 0 13 * 5');
      expect(c.dayOfMonthRestricted, isTrue);
      expect(c.dayOfWeekRestricted, isTrue);
      // Fires on BOTH the 13th and every Friday.
      expect(c.next(DateTime(2025, 1, 1, 0, 0)), DateTime(2025, 1, 3, 0, 0));
      expect(c.next(DateTime(2025, 1, 3, 0, 0)), DateTime(2025, 1, 10, 0, 0));
      expect(c.next(DateTime(2025, 1, 10, 0, 0)), DateTime(2025, 1, 13, 0, 0));
    });

    test('a star in either day field disables the OR rule', () {
      final domOnly = CronExpression.parse('0 0 13 * *');
      expect(domOnly.dayOfWeekRestricted, isFalse);
      final dowOnly = CronExpression.parse('0 0 * * 5');
      expect(dowOnly.dayOfMonthRestricted, isFalse);
    });

    test('leap day schedules are found across the 4-year cycle', () {
      final c = CronExpression.parse('0 0 29 2 *');
      expect(c.next(DateTime(2025, 1, 1, 0, 0)), DateTime(2028, 2, 29, 0, 0));
      expect(c.next(DateTime(2028, 2, 29, 0, 0)), DateTime(2032, 2, 29, 0, 0));
      // 2100 is not a leap year, so the cycle skips it.
      expect(c.next(DateTime(2096, 3, 1, 0, 0)), DateTime(2104, 2, 29, 0, 0));
    });

    test('month rollover and year rollover are handled', () {
      final c = CronExpression.parse('0 0 1 12 *');
      expect(c.next(DateTime(2025, 1, 1, 0, 0)), DateTime(2025, 12, 1, 0, 0));
      expect(c.next(DateTime(2025, 12, 1, 0, 0)), DateTime(2026, 12, 1, 0, 0));
    });

    test('"31st" is skipped in short months', () {
      final c = CronExpression.parse('0 0 31 * *');
      // Feb and Apr have no 31st.
      expect(c.next(DateTime(2025, 1, 31, 0, 0)), DateTime(2025, 3, 31, 0, 0));
      expect(c.next(DateTime(2025, 4, 1, 0, 0)), DateTime(2025, 5, 31, 0, 0));
    });

    test('matches() ignores seconds but respects every field', () {
      final c = CronExpression.parse('30 4 * * *');
      expect(c.matches(DateTime(2025, 1, 1, 4, 30)), isTrue);
      expect(c.matches(DateTime(2025, 1, 1, 4, 30, 59)), isTrue);
      expect(c.matches(DateTime(2025, 1, 1, 4, 31)), isFalse);
      expect(c.matches(DateTime(2025, 1, 1, 5, 30)), isFalse);
    });

    test('timeUntilNext measures from the truncated minute', () {
      final c = CronExpression.parse('*/15 * * * *');
      expect(c.timeUntilNext(DateTime(2025, 1, 1, 10, 7, 42)),
          const Duration(minutes: 8));
    });

    test('toString and equality round-trip the source text', () {
      final c = CronExpression.parse('  0 5 * * 1  ');
      expect(c.toString(), '0 5 * * 1');
      expect(c, equals(CronExpression.parse('0 5 * * 1')));
      expect(c.toJson(), {'type': 'cron', 'expression': '0 5 * * 1'});
    });
  });

  group('CronExpression matches: differential vs brute-force oracle', () {
    test('agrees on a dense minute grid across rollover boundaries', () {
      // Windows chosen to span leap February, a 30-day month, and a year end.
      final windows = [
        DateTime(2025, 1, 1),
        DateTime(2024, 2, 27),
        DateTime(2025, 12, 28),
      ];
      const minutesPerWindow = 2 * 24 * 60;
      var comparisons = 0;
      final mismatches = <String>[];

      for (final expr in _corpus) {
        final fast = CronExpression.parse(expr);
        final oracle = _OracleCron(expr);
        for (final window in windows) {
          var t = window;
          for (var i = 0; i < minutesPerWindow; i++) {
            final a = fast.matches(t);
            final b = oracle.matches(t);
            comparisons++;
            if (a != b && mismatches.length < 20) {
              mismatches.add('"$expr" at ${_fmt(t)}: fast=$a oracle=$b');
            }
            t = DateTime(t.year, t.month, t.day, t.hour, t.minute + 1);
          }
        }
      }

      expect(mismatches, isEmpty);
      // 54 expressions x 3 windows x 2880 minutes. The floor exists to catch the
      // loops silently not running, so it must track the sample count.
      expect(comparisons, greaterThan(400000));
    });
  });

  group('CronExpression next: differential vs brute-force scan', () {
    test('agrees with a minute-by-minute scan (corpus)', () {
      // The oracle scans a minute at a time, so its cost is the budget times
      // the number of samples. Three days is enough for every expression in the
      // corpus; sparse expressions that exhaust the budget are handled by the
      // fallback assertion below and by the explicit leap-year expectations.
      const budgetMinutes = 3 * 24 * 60;
      final rng = _Rng(0xC0FFEE);
      var comparisons = 0;
      final mismatches = <String>[];

      for (final expr in _corpus) {
        final fast = CronExpression.parse(expr);
        final oracle = _OracleCron(expr);
        for (var i = 0; i < 3; i++) {
          final start = _randomStart(rng);
          final a = fast.next(start);
          final b = oracle.next(start, budgetMinutes);
          comparisons++;
          if (b != null && a != b) {
            mismatches.add('"$expr" from ${_fmt(start)}: fast=${_fmt(a)} '
                'oracle=${_fmt(b)}');
          } else if (b == null && a != null) {
            // The oracle only gave up because of its budget; the fast answer
            // must still be genuinely far away, self-consistent, and accepted
            // by the oracle's own field logic.
            final delta = a.difference(start).inMinutes;
            if (delta < budgetMinutes) {
              mismatches.add('"$expr" from ${_fmt(start)}: fast=${_fmt(a)} '
                  'but oracle found nothing within budget ($delta min)');
            }
            if (!fast.matches(a)) {
              mismatches.add('"$expr": next() returned non-matching ${_fmt(a)}');
            }
            if (!oracle.matches(a)) {
              mismatches.add('"$expr": oracle rejects next() result ${_fmt(a)}');
            }
          }
        }
      }

      expect(mismatches, isEmpty);
      // 54 expressions x 3 starts each.
      expect(comparisons, greaterThan(150));
    });

    test('agrees with a minute-by-minute scan (randomized)', () {
      const budgetMinutes = 3 * 24 * 60;
      final rng = _Rng(0x1234567);
      final mismatches = <String>[];
      var comparisons = 0;

      for (var i = 0; i < 150; i++) {
        final expr = _randomExpression(rng);
        final fast = CronExpression.parse(expr);
        final oracle = _OracleCron(expr);
        for (var j = 0; j < 2; j++) {
          final start = _randomStart(rng);
          final a = fast.next(start);
          final b = oracle.next(start, budgetMinutes);
          comparisons++;
          if (b != null && a != b) {
            mismatches.add('"$expr" from ${_fmt(start)}: fast=${_fmt(a)} '
                'oracle=${_fmt(b)}');
          }
        }
      }

      expect(mismatches, isEmpty);
      expect(comparisons, 300);
    });

    test('a schedule that can never fire returns null', () {
      // February has no 30th, so this exhausts the search horizon.
      expect(
        CronExpression.parse('0 0 30 2 *').next(DateTime(2025, 1, 1)),
        isNull,
      );
      expect(CronExpression.isValid('0 0 30 2 *'), isTrue);
    });

    test('the oracle fallback path is self-consistent', () {
      // Sparse schedules can be years apart, which the minute-scanning oracle
      // cannot reach. Rather than spend minutes of scan budget proving nothing,
      // assert the properties that matter: the answer is real, it matches, and
      // it is far beyond the oracle's reach. The concrete leap-year dates are
      // pinned by the explicit expectations above.
      const budgetMinutes = 3 * 24 * 60;
      for (final expr in ['0 0 29 2 *', '30 12 29 2 1']) {
        final fast = CronExpression.parse(expr);
        final oracle = _OracleCron(expr);
        final start = DateTime(2025, 1, 1, 0, 0);
        final a = fast.next(start);
        expect(a, isNotNull, reason: '"$expr" should eventually match');
        expect(fast.matches(a!), isTrue, reason: '"$expr" result must match');
        expect(oracle.matches(a), isTrue,
            reason: '"$expr" oracle must accept the result');
        expect(oracle.next(start, budgetMinutes), isNull,
            reason: '"$expr" should be beyond the oracle budget');
      }
    });

    test('advance chains stay monotonic, matching, and minute-aligned', () {
      final mismatches = <String>[];
      for (final expr in _corpus) {
        final fast = CronExpression.parse(expr);
        final oracle = _OracleCron(expr);
        var t = DateTime(2025, 1, 1, 0, 0);
        for (var i = 0; i < 25; i++) {
          final next = fast.next(t);
          if (next == null) {
            break;
          }
          if (!next.isAfter(t)) {
            mismatches.add('"$expr" at ${_fmt(t)}: ${_fmt(next)} did not advance');
            break;
          }
          if (next.second != 0 || next.millisecond != 0) {
            mismatches.add('"$expr": ${_fmt(next)} not truncated to the minute');
            break;
          }
          if (!oracle.matches(next)) {
            mismatches.add('"$expr": ${_fmt(next)} rejected by oracle');
            break;
          }
          t = next;
        }
      }
      expect(mismatches, isEmpty);
    });
  });
}
