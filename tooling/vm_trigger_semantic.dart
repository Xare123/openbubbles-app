import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

/// The VM invocation response can be a Future reference, not its outcome.
/// Attach the completion/error observer in the same evaluation as invocation
/// so even an immediate asynchronous failure is caught. Only fixed entry
/// points and content-free result codes cross this diagnostic boundary.
Future<void> invokeSemanticAndWait({
  required VmService service,
  required String isolateId,
  required String libraryId,
  required String targetId,
  required String selector,
  Duration timeout = const Duration(seconds: 210),
}) async {
  if (!const {
    'runCloudSyncV2ManualSemanticPullConfirmed',
    'runCloudSyncV2ManualSemanticCatchUpConfirmed',
  }.contains(selector)) {
    throw ArgumentError('semantic_selector_invalid');
  }
  final observer = await service.evaluate(
    isolateId,
    libraryId,
    '''
    (() {
      final observation = <String>['pending', ''];
      Future<void> run() async {
        try {
          await semanticTarget.$selector();
          observation[0] = 'completed';
        } catch (error) {
          observation[0] = 'failed';
          observation[1] = 'semantic_operation_failed';
          final candidate = error is StateError ? error.message.toString() : '';
          observation[1] = RegExp(r'^cloud_sync_[a-z0-9_]+\$').hasMatch(candidate)
              ? candidate : 'semantic_operation_failed';
        }
      }
      // Schedule after evaluation returns. The real-VM regression reproduces
      // a missing immediate async error when run() is invoked inline here.
      Future<void>(run);
      return observation;
    })()
  ''',
    scope: {'semanticTarget': targetId},
    disableBreakpoints: true,
  );
  if (observer is! InstanceRef || observer.id == null) {
    throw StateError('semantic_observer_unavailable');
  }
  final watch = Stopwatch()..start();
  while (watch.elapsed < timeout) {
    final current = await service.getObject(isolateId, observer.id!);
    if (current is! Instance || current.elements?.length != 2) {
      throw StateError('semantic_observer_invalid');
    }
    final state = current.elements![0];
    final detail = current.elements![1];
    if (state is! InstanceRef || detail is! InstanceRef) {
      throw StateError('semantic_observer_invalid');
    }
    if (state.valueAsString == 'completed' && detail.valueAsString == '') {
      return;
    }
    if (state.valueAsString == 'failed') {
      final code = detail.valueAsString ?? '';
      throw StateError(
        RegExp(r'^cloud_sync_[a-z0-9_]+$').hasMatch(code)
            ? code
            : 'semantic_operation_failed',
      );
    }
    if (state.valueAsString != 'pending' || detail.valueAsString != '') {
      throw StateError('semantic_observer_invalid');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  // A timeout is not cancellation. Leave the remote operation alone.
  throw StateError('semantic_operation_still_running');
}

Future<void> main(List<String> args) async {
  if (args.isEmpty ||
      args.length > 2 ||
      (args.length == 2 && !['--catch-up', '--status'].contains(args[1]))) {
    throw ArgumentError(
      'usage: vm_trigger_semantic.dart <ws-uri> [--catch-up|--status]',
    );
  }
  final catchUp = args.length == 2 && args[1] == '--catch-up';
  final statusOnly = args.length == 2 && args[1] == '--status';
  var statusPrinted = false;
  final selector = catchUp
      ? 'runCloudSyncV2ManualSemanticCatchUpConfirmed'
      : 'runCloudSyncV2ManualSemanticPullConfirmed';

  final service = await vmServiceConnectUri(args.first);
  try {
    final vm = await service.getVM();
    for (final isolateRef in vm.isolates ?? const <IsolateRef>[]) {
      final isolateId = isolateRef.id;
      if (isolateId == null) continue;
      final isolate = await service.getIsolate(isolateId);
      for (final library in isolate.libraries ?? const <LibraryRef>[]) {
        if (!(library.uri ?? '').endsWith('/rustpush_service.dart')) continue;
        final libraryId = library.id;
        if (libraryId == null) continue;
        if (statusOnly) {
          final result = await service.evaluate(isolateId, libraryId, '''
            <String, bool>{
              'ui': ls.isUiThread,
              'canary': pushService._cloudSyncV2CanaryRuntimeAllowed,
              'developer': pushService._cloudSyncV2DeveloperRuntimeAllowed,
              'available': pushService.cloudSyncV2ManualSemanticPullAvailable,
              'inFlight': pushService._cloudSyncV2SemanticPullInFlight != null,
              'quiescing': pushService._cloudSyncV2SemanticPullQuiescing,
              'loggingOut': pushService.loggingOut,
              'hasState': pushService.state != null,
              'hasStorage': pushService.statePath.isNotEmpty,
              'hasCloudClient': pushService.state?.icloudServices?.cloudMessagesClient != null,
              'legacyEnabled': ss.settings.cloudSyncingEnabled.value,
              'legacyActive': pushService.isSyncing.value != null,
            }.toString()
          ''');
          if (result is! InstanceRef || result.valueAsString == null) {
            throw StateError('semantic_status_unavailable');
          }
          print(
            'semantic_pull_status isolate=${isolateRef.name} ${result.valueAsString}',
          );
          statusPrinted = true;
          continue;
        }
        final ready = await service.evaluate(
          isolateId,
          libraryId,
          'ls.isUiThread && pushService.cloudSyncV2ManualSemanticPullAvailable',
        );
        if (ready is! InstanceRef || ready.valueAsString != 'true') continue;
        final libraryObject = await service.getObject(isolateId, libraryId);
        if (libraryObject is! Library) {
          throw StateError('rustpush_service_library_unavailable');
        }
        FieldRef? variable;
        for (final field in libraryObject.variables ?? const <FieldRef>[]) {
          if (field.name == 'pushService') {
            variable = field;
            break;
          }
        }
        if (variable == null) {
          throw StateError('rustpush_service_variable_not_found');
        }
        final fieldObject = await service.getObject(isolateId, variable.id!);
        if (fieldObject is! Field) {
          throw StateError('rustpush_service_field_unavailable');
        }
        final target = fieldObject.staticValue;
        if (target is! InstanceRef || target.id == null) {
          throw StateError('rustpush_service_target_unavailable');
        }
        await invokeSemanticAndWait(
          service: service,
          isolateId: isolateId,
          libraryId: libraryId,
          targetId: target.id!,
          selector: selector,
        );
        print(
          'semantic_pull_completed mode=${catchUp ? 'catch-up' : 'single'} '
          'isolate=${isolateRef.name}',
        );
        return;
      }
    }
    if (!statusPrinted) throw StateError('semantic_ready_ui_isolate_not_found');
  } finally {
    await service.dispose();
  }
}
