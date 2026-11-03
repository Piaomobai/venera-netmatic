import 'dart:io';
import 'package:venera_netmatic/foundation/process_lock.dart';

Future<void> main(List<String> args) async {
  try {
    final lock = await AppProcessLock.acquire(args.single);
    stdout.writeln('acquired');
    await lock.close();
  } on AppBusyException {
    stdout.writeln('busy');
    exitCode = 3;
  }
}
