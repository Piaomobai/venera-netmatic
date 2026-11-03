import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_netmatic/foundation/async_control.dart';

void main() {
  test(
    'cancellation ends a stalled read and observes its late error',
    () async {
      final operation = Completer<void>();
      var cancelled = false;
      final waiting = waitCancellable(
        operation.future,
        checkCancelled: () {
          if (cancelled) throw StateError('cancelled');
        },
      );
      cancelled = true;
      await expectLater(waiting, throwsStateError);
      operation.completeError(StateError('late network error'));
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'read deadline runs cleanup without waiting for a hung source',
    () async {
      final operation = Completer<void>();
      var cleaned = false;
      Future<void> run() async {
        try {
          await waitCancellable(
            operation.future,
            checkCancelled: () {},
            timeout: const Duration(milliseconds: 20),
          );
        } finally {
          cleaned = true;
        }
      }

      await expectLater(run(), throwsA(isA<TimeoutException>()));
      expect(cleaned, isTrue);
      operation.complete();
    },
  );
}
