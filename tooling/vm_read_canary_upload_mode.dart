import 'dart:convert';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

/// Observe compiled gates and the existing service's pure build-id getter.
/// No source evaluation, account changes, Apple requests or database writes.
///
/// Default mode verifies the automatic-build gates (uploads on). Pass
/// `--expect-uploads-off` for Pixel qualification, which instead requires
/// manualOutboundCanaryEnabled == false, localSendRuntimeEnabled == false,
/// no automatic worker instance, and a present build commit. Emits only
/// booleans, the build commit, and the checked mode.
Future<void> main(List<String> args) async {
  if (args.isEmpty ||
      args.length > 2 ||
      (args.length == 2 && args[1] != '--expect-uploads-off')) {
    throw ArgumentError(
      'usage: vm_read_canary_upload_mode.dart <ws-uri> [--expect-uploads-off]',
    );
  }
  final uploadsOffExpected = args.length == 2;
  final service = await vmServiceConnectUri(args.first);
  try {
    final vm = await service.getVM();
    final reports = <Map<String, Object?>>[];
    for (final ref in vm.isolates ?? <IsolateRef>[]) {
      final id = ref.id!;
      final isolate = await service.getIsolate(id);
      final report = <String, Object?>{};
      for (final lib in isolate.libraries ?? <LibraryRef>[]) {
        final uri = lib.uri ?? '';
        if (!uri.endsWith('/cloud_sync/cloud_sync_dev_gate.dart') &&
            !uri.endsWith('/rustpush/rustpush_service.dart')) {
          continue;
        }
        final library = await service.getObject(id, lib.id!);
        if (library is! Library) continue;
        for (final klass in library.classes ?? <ClassRef>[]) {
          if (klass.name == 'CloudSyncDevGate') {
            final object = await service.getObject(id, klass.id!);
            if (object is! Class) continue;
            for (final field in object.fields ?? <FieldRef>[]) {
              if (!const {
                'manualOutboundCanaryEnabled',
                'localSendRuntimeEnabled',
              }.contains(field.name)) {
                continue;
              }
              final value = await service.getObject(id, field.id!);
              if (value is Field && value.staticValue is InstanceRef) {
                final flag = value.staticValue as InstanceRef;
                if (flag.kind == 'Bool') {
                  report[field.name!] = flag.valueAsString == 'true';
                }
              }
            }
          } else if (klass.name == 'RustPushService') {
            final instances = await service.getInstances(id, klass.id!, 1);
            if (instances.instances?.length != 1) continue;
            final instance = instances.instances!.single;
            final build = await service.invoke(
              id,
              instance.id!,
              '_cloudSyncV2BuildIdentifier',
              const [],
              disableBreakpoints: true,
            );
            if (build is InstanceRef &&
                RegExp(r'^[0-9a-f]{40}$').hasMatch(build.valueAsString ?? '')) {
              report['buildCommit'] = build.valueAsString;
            }
            final object = await service.getObject(id, instance.id!);
            if (object is! Instance) continue;
            for (final field in object.fields ?? <BoundField>[]) {
              if (field.decl?.name == '_cloudSyncV2LocalSendRuntime' &&
                  field.value is InstanceRef) {
                report['automaticWorkerCreated'] =
                    (field.value as InstanceRef).kind != 'Null';
              }
            }
          }
        }
      }
      if (report.isNotEmpty) reports.add(report);
    }
    print(
      jsonEncode({
        'mode': uploadsOffExpected ? 'uploads-off' : 'automatic-build',
        'isolates': reports,
      }),
    );
    if (uploadsOffExpected) {
      final committed = reports.where((r) => r['buildCommit'] != null).toList();
      if (committed.isEmpty) {
        throw StateError('uploads_not_off');
      }
      if (committed.length != 1) {
        throw StateError('multiple_service_instances');
      }
      for (final r in reports) {
        if (r['localSendRuntimeEnabled'] == true ||
            r['manualOutboundCanaryEnabled'] == true ||
            r['automaticWorkerCreated'] == true) {
          throw StateError('uploads_not_off');
        }
      }
      final only = committed.single;
      if (only['localSendRuntimeEnabled'] != false ||
          only['manualOutboundCanaryEnabled'] != false ||
          only['automaticWorkerCreated'] != false) {
        throw StateError('uploads_not_off');
      }
      return;
    }
    if (!reports.any(
      (r) =>
          r['localSendRuntimeEnabled'] == true &&
          r['manualOutboundCanaryEnabled'] == true &&
          r['buildCommit'] != null,
    )) {
      throw StateError('automatic_build_not_verified');
    }
  } finally {
    await service.dispose();
  }
}
