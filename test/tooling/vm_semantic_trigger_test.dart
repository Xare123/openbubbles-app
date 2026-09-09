import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import '../../tooling/vm_trigger_semantic.dart' as trigger;
import '../../tooling/vm_trigger_cloudkit_write.dart' as write_trigger;

Future<String> _waitForServiceUri(File info) async {
  final watch = Stopwatch()..start();
  while (watch.elapsed < const Duration(seconds: 20)) {
    // Fixture main and VM-service startup run independently. The readiness
    // marker does not guarantee that this file exists or is fully written.
    try {
      final decoded = jsonDecode(await info.readAsString());
      if (decoded is Map && decoded['uri'] is String) {
        return decoded['uri'] as String;
      }
    } on PathNotFoundException {
      // VM-service startup has not created the file yet.
    } on FormatException {
      // The service may still be writing its JSON document.
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  throw StateError('fixture_vm_service_not_ready');
}

void main() {
  Directory? temporary;
  Process? child;
  VmService? connectedService;
  late VmService service;
  late String isolateId;
  late String libraryId;

  setUpAll(() async {
    final configFile = File('.dart_tool/package_config.json').absolute;
    final config = jsonDecode(await configFile.readAsString()) as Map;
    final flutter = (config['packages'] as List).cast<Map>().singleWhere(
      (package) => package['name'] == 'flutter',
    );
    final packageRoot = Directory.fromUri(
      configFile.uri.resolve(flutter['rootUri'] as String),
    );
    final dart = p.normalize(
      p.join(
        packageRoot.path,
        '..',
        '..',
        'bin',
        'cache',
        'dart-sdk',
        'bin',
        Platform.isWindows ? 'dart.exe' : 'dart',
      ),
    );
    final directory = await Directory.systemTemp.createTemp(
      'cloud-sync-vm-test-',
    );
    temporary = directory;
    final info = File(p.join(directory.path, 'service.json'));
    final process = await Process.start(dart, [
      '--enable-vm-service=0',
      '--write-service-info=${info.path}',
      'test/tooling/fixtures/semantic_vm_fixture.dart',
    ]);
    child = process;
    final ready = Completer<void>();
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line == 'fixture-ready' && !ready.isCompleted) ready.complete();
        });
    // Consume output without exposing the ephemeral VM credential or details.
    process.stderr.listen((_) {});
    await ready.future.timeout(const Duration(seconds: 20));
    final uri = await _waitForServiceUri(info);
    service = await vmServiceConnectUri(
      '${uri.replaceFirst('http:', 'ws:')}ws',
    );
    connectedService = service;
    final vm = await service.getVM();
    isolateId = vm.isolates!
        .singleWhere((isolate) => isolate.name == 'main')
        .id!;
    final isolate = await service.getIsolate(isolateId);
    libraryId = isolate.libraries!
        .singleWhere(
          (library) => library.uri!.endsWith('/semantic_vm_fixture.dart'),
        )
        .id!;
  });

  tearDownAll(() async {
    await connectedService?.dispose();
    final process = child;
    if (process != null) {
      try {
        await process.stdin.close();
      } on IOException {
        // Setup may have failed after the fixture process already exited.
      }
      try {
        await process.exitCode.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        process.kill();
        await process.exitCode.timeout(const Duration(seconds: 5));
      }
    }
    // Only this fixture's unique temporary directory, after its process exits.
    await temporary?.delete(recursive: true);
  });

  Future<void> run(
    String mode, {
    bool catchUp = false,
    Duration? timeout,
  }) async {
    final target = await service.evaluate(
      isolateId,
      libraryId,
      "FixtureService('$mode')",
    );
    expect(target, isA<InstanceRef>());
    await trigger.invokeSemanticAndWait(
      service: service,
      isolateId: isolateId,
      libraryId: libraryId,
      targetId: (target as InstanceRef).id!,
      selector: catchUp
          ? 'runCloudSyncV2ManualSemanticCatchUpConfirmed'
          : 'runCloudSyncV2ManualSemanticPullConfirmed',
      timeout: timeout ?? const Duration(seconds: 10),
    );
  }

  test('real VM waits for asynchronous success', () async {
    final watch = Stopwatch()..start();
    await run('success');
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(150));
  });

  test('unsupported CLI mode is rejected before connection', () async {
    await expectLater(
      trigger.main(['not-a-vm-uri', '--unsupported']),
      throwsArgumentError,
    );
    await expectLater(
      trigger.main(['not-a-vm-uri', '--catch-up', 'unexpected']),
      throwsArgumentError,
    );
  });

  for (final partial in [false, true]) {
    test(
      'VM readiness waits for ${partial ? 'partial' : 'missing'} info',
      () async {
        final info = File(p.join(temporary!.path, 'readiness-$partial.json'));
        if (partial) await info.writeAsString('{');
        final observed = _waitForServiceUri(info);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await info.writeAsString('{"uri":"http://127.0.0.1:1/synthetic/"}');
        expect(await observed, 'http://127.0.0.1:1/synthetic/');
      },
    );
  }

  test(
    'catch-up uses the same completion protocol',
    () => run('success', catchUp: true),
  );

  test(
    'immediate asynchronous failure is observed, not called success',
    () async {
      await expectLater(
        run('failure'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'code',
            'cloud_sync_fixture_failure',
          ),
        ),
      );
    },
  );

  test('arbitrary error details are not exported', () async {
    await expectLater(
      run('private'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'code',
          'semantic_operation_failed',
        ),
      ),
    );
  });

  test(
    'timeout is explicitly unresolved, not success or cancellation',
    () async {
      await expectLater(
        run('pending', timeout: const Duration(milliseconds: 250)),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'code',
            'semantic_operation_still_running',
          ),
        ),
      );
      // Observation timeout neither kills the VM nor prevents another target.
      await run('success');
    },
  );

  Future<InstanceRef> writeTarget(String mode) async {
    final target = await service.evaluate(
      isolateId,
      libraryId,
      "FixtureService('$mode')",
    );
    expect(target, isA<InstanceRef>());
    return target as InstanceRef;
  }

  test(
    'write preparation returns only content-free selection evidence',
    () async {
      final target = await writeTarget('write-success');
      final result = await write_trigger.invokePrepareAndSelect(
        service: service,
        isolateId: isolateId,
        libraryId: libraryId,
        targetId: target.id!,
        recipient: '+15555550123',
      );
      expect(result.candidateFound, isTrue);
      expect(result.guidHash, '0123456789abcdef');
      expect(result.createdAtUtc, '2026-09-10T01:02:03.000Z');
      expect(result.toJson().toString(), isNot(contains('+15555550123')));
    },
  );

  test('write preparation reports no candidate without fallback', () async {
    final target = await writeTarget('write-none');
    final result = await write_trigger.invokePrepareAndSelect(
      service: service,
      isolateId: isolateId,
      libraryId: libraryId,
      targetId: target.id!,
      recipient: '+15555550123',
    );
    expect(result.candidateFound, isFalse);
    expect(result.guidHash, isNull);
  });

  test('write preparation suppresses arbitrary error detail', () async {
    final target = await writeTarget('write-private');
    await expectLater(
      write_trigger.invokePrepareAndSelect(
        service: service,
        isolateId: isolateId,
        libraryId: libraryId,
        targetId: target.id!,
        recipient: '+15555550123',
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'code',
          'cloud_sync_write_operation_failed',
        ),
      ),
    );
  });

  test('exact write waits for the production result shape', () async {
    final target = await writeTarget('write-success');
    final result = await write_trigger.invokeExactIntentAndWait(
      service: service,
      isolateId: isolateId,
      libraryId: libraryId,
      targetId: target.id!,
      recipient: '+15555550123',
      expectedGuidHash: '0123456789abcdef',
    );
    expect(result.admitted, 1);
    expect(result.deferred, 0);
    expect(result.outboxBlocked, isFalse);
    expect(result.chatReadbackPending, isFalse);
  });

  test(
    'exact write rejects candidate drift before invoking the pass',
    () async {
      final target = await writeTarget('write-changed');
      await expectLater(
        write_trigger.invokeExactIntentAndWait(
          service: service,
          isolateId: isolateId,
          libraryId: libraryId,
          targetId: target.id!,
          recipient: '+15555550123',
          expectedGuidHash: '0123456789abcdef',
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'code',
            'cloud_sync_outbound_candidate_changed',
          ),
        ),
      );
    },
  );

  test('recipient hash normalization matches app endpoint normalization', () {
    expect(
      write_trigger.normalizedRecipientSha256(' tel:+15555550123 '),
      write_trigger.normalizedRecipientSha256('+15555550123'),
    );
    expect(
      write_trigger.normalizedRecipientSha256('MAILTO:Test@Example.COM'),
      write_trigger.normalizedRecipientSha256('test@example.com'),
    );
  });
}
