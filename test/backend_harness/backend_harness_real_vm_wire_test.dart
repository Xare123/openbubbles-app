import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:isolate';

import 'package:bluebubbles/backend_harness/backend_harness_protocol.dart';
import 'package:bluebubbles/backend_harness/backend_harness_vm_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service_io.dart';

import '../../tooling/vm_backend_harness.dart' as host;

// Opt in explicitly with --enable-vmservice and both defines. This uses no
// application services, account/profile, UI navigation or native cloud APIs.
void main() {
  const enabled = bool.fromEnvironment('OPENBUBBLES_BACKEND_WIRE_TEST');
  test(
    'production extension and host accept a real VM-service hello',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final source = List.filled(40, 'a').join();
      final engine = BackendHarnessEngine(
        enabled: true,
        source: source,
        package: 'com.bluebubbles.messaging.backendtest',
        platform: 'android',
        operations: {
          'status': BackendHarnessOperation(
            validate: (arguments) => arguments.isEmpty,
            handler: (_) async => const BackendHarnessPayload(
              phase: BackendHarnessPhase.idle,
              flags: {'setup_finished': false, 'native_client_present': false},
            ),
          ),
        },
      );
      expect(registerBackendHarnessExtension(engine), isTrue);
      final info = await developer.Service.getInfo();
      expect(info.serverWebSocketUri, isNotNull);
      final service = await vmServiceConnectUri(
        info.serverWebSocketUri.toString(),
      );
      try {
        developer.registerExtension('ext.openbubbles.wireParameterKeys', (
          _,
          parameters,
        ) async {
          final keys = parameters.keys.toList()..sort();
          return developer.ServiceExtensionResponse.result(
            jsonEncode({'keys': keys}),
          );
        });
        final framework = await service.callServiceExtension(
          'ext.openbubbles.wireParameterKeys',
        isolateId: developer.Service.getIsolateId(Isolate.current),
          args: {'request': '{}'},
        );
        print(
          jsonEncode({'framework_parameter_keys': framework.json!['keys']}),
        );
        final response = await service.callServiceExtension(
          backendHarnessExtension,
        isolateId: developer.Service.getIsolateId(Isolate.current),
          args: {
            'request': jsonEncode({
              'protocol': 1,
              'requestId': 'wire_hello',
              'action': 'hello',
              'arguments': <String, Object?>{},
            }),
          },
        );
        final raw = response.json!;
        final keys = raw.keys.toList()..sort();
        // Closed diagnostics only, never a VM endpoint or a private reply body.
        print(
          jsonEncode({
            'wire_reply_keys': keys,
            'request_bound': raw['requestId'] == 'wire_hello',
            'wire_code': raw['code'],
            'wire_state': raw['state'],
          }),
        );
        final reply = host.validateBackendHarnessReply(
          raw,
          requestId: 'wire_hello',
          action: 'hello',
        );
        expect(reply['ok'], isTrue);
        expect((reply['data'] as Map)['source'], source);
        final client = host.BackendHarnessVmClient(
          service,
          expectedSource: source,
          expectedPackage: 'com.bluebubbles.messaging.backendtest',
        );
        final boundHello = await client.execute({
          'protocol': 1,
          'requestId': 'client_hello',
          'action': 'hello',
          'arguments': <String, Object?>{},
        });
        expect(boundHello['ok'], isTrue);
        final boundStatus = await client.execute({
          'protocol': 1,
          'requestId': 'client_status',
          'action': 'status',
          'arguments': <String, Object?>{},
        });
        expect(boundStatus['ok'], isTrue);
        expect(
          ((boundStatus['data'] as Map)['flags']
              as Map)['native_client_present'],
          false,
        );
      } finally {
        await service.dispose();
      }
    },
    skip: !enabled,
  );
}
