import 'dart:async';

/// Bounds a read/network wait and checks cooperative cancellation while waiting.
/// Late completion is observed but cannot resume the cancelled caller. Do not
/// use this to abandon file installation, upload commits or rollback work.
Future<T> waitCancellable<T>(
  Future<T> operation, {
  required void Function() checkCancelled,
  Duration timeout = const Duration(seconds: 60),
}) async {
  final result = Completer<T>();
  void check() {
    if (result.isCompleted) return;
    try {
      checkCancelled();
    } catch (error, stack) {
      result.completeError(error, stack);
    }
  }

  operation.then(
    (value) {
      check();
      if (!result.isCompleted) result.complete(value);
    },
    onError: (Object error, StackTrace stack) {
      check();
      if (!result.isCompleted) result.completeError(error, stack);
    },
  );
  check();
  final poll = Timer.periodic(const Duration(milliseconds: 50), (_) => check());
  final deadline = Timer(timeout, () {
    check();
    if (!result.isCompleted) {
      result.completeError(TimeoutException('Operation timed out.', timeout));
    }
  });
  try {
    return await result.future;
  } finally {
    poll.cancel();
    deadline.cancel();
  }
}
