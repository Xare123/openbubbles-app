// Local Flutter-runtime characterization, no app profile or network access.
import 'dart:convert';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter_test/flutter_test.dart';

void registerUntilKilled((String, SendPort) input) {
  final receiver = ReceivePort();
  receiver.listen((_) {});
  input.$2.send(
    IsolateNameServer.registerPortWithName(receiver.sendPort, input.$1),
  );
}

void main() {
  test(
    'observe registry after its owning isolate is confirmed stopped',
    () async {
      final name =
          'openbubbles.synthetic.exit.${DateTime.now().microsecondsSinceEpoch}';
      final ready = ReceivePort();
      final exited = ReceivePort();
      Isolate? owner;
      try {
        owner = await Isolate.spawn(registerUntilKilled, (
          name,
          ready.sendPort,
        ), onExit: exited.sendPort);
        expect(await ready.first.timeout(const Duration(seconds: 5)), isTrue);
        expect(IsolateNameServer.lookupPortByName(name), isNotNull);
        owner.kill(priority: Isolate.immediate);
        await exited.first.timeout(const Duration(seconds: 5));
        owner = null;
        final mappingRetained =
            IsolateNameServer.lookupPortByName(name) != null;
        final successor = ReceivePort();
        try {
          final admitted = IsolateNameServer.registerPortWithName(
            successor.sendPort,
            name,
          );
          // ignore: avoid_print
          print(
            'ISOLATE_EXIT_PROBE=${jsonEncode({'ownerStopped': true, 'mappingRetained': mappingRetained, 'successorAdmitted': admitted, 'nativeOperationsStarted': 0})}',
          );
        } finally {
          successor.close();
        }
      } finally {
        owner?.kill(priority: Isolate.immediate);
        // Only this synthetic test name, after the owner has exited. This is
        // never an instruction to remove a production lock on timeout.
        IsolateNameServer.removePortNameMapping(name);
        ready.close();
        exited.close();
      }
    },
  );
}
