/// Execution limits also apply to one-shot CLI commands. Daemons have no
/// implicit lifetime limit; their individual service requests are bounded.
Duration? defaultExecutionTimeout(String command) {
  if (['service serve', 'scheduler serve', 'help'].contains(command)) {
    return null;
  }
  if (['nas upload', 'nas download'].contains(command)) {
    return const Duration(hours: 6);
  }
  if ([
    'downloads add',
    'downloads run',
    'scheduler run',
    'scheduler rundue',
  ].contains(command)) {
    return const Duration(hours: 1);
  }
  if ([
    'webdav up',
    'webdav down',
    'updatescript all',
    'updatesubscribe',
  ].contains(command)) {
    return const Duration(minutes: 5);
  }
  if (['nas test', 'nas library'].contains(command)) {
    return const Duration(minutes: 2);
  }
  return const Duration(minutes: 1);
}

class ServiceQueuePolicy {
  const ServiceQueuePolicy({
    this.queryQueueTimeout = const Duration(seconds: 30),
    this.commandQueueTimeout = const Duration(minutes: 10),
    this.backgroundQueueTimeout = const Duration(hours: 1),
    this.executionTimeout,
    this.exclusiveGrace = const Duration(seconds: 1),
    this.backgroundDeferral = const Duration(seconds: 2),
    this.writerAging = const Duration(seconds: 30),
    this.queryBurstLimit = 8,
    this.maxPending = 256,
    this.reservedInteractivePending = 32,
    this.maxBackgroundPending = 192,
  }) : assert(maxPending > reservedInteractivePending),
       assert(reservedInteractivePending >= 0),
       assert(maxBackgroundPending > 0),
       assert(maxBackgroundPending <= maxPending - reservedInteractivePending);

  final Duration queryQueueTimeout;
  final Duration commandQueueTimeout;
  final Duration backgroundQueueTimeout;
  final Duration? executionTimeout;
  final Duration exclusiveGrace;
  final Duration backgroundDeferral;
  final Duration writerAging;
  final int queryBurstLimit;
  final int maxPending;
  final int reservedInteractivePending;
  final int maxBackgroundPending;
}
