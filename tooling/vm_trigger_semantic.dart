import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty ||
      args.length > 2 ||
      (args.length == 2 && args[1] != '--catch-up')) {
    throw ArgumentError(
      'usage: vm_trigger_semantic.dart <ws-uri> [--catch-up]',
    );
  }
  final catchUp = args.length == 2;
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
        final result = await service.invoke(
          isolateId,
          target.id!,
          selector,
          const [],
        );
        if (result is ErrorRef) {
          throw StateError('semantic_pull_invoke_error:${result.kind}');
        }
        print(
          'semantic_pull_invoked mode=${catchUp ? 'catch-up' : 'single'} '
          'isolate=${isolateRef.name}',
        );
        return;
      }
    }
    throw StateError('rustpush_service_library_not_found');
  } finally {
    await service.dispose();
  }
}
