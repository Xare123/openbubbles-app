import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

void main(List<String> arguments) {
  if (arguments.length != 2) {
    stderr.writeln('Usage: dart smoke_library.dart <library> <export>');
    exitCode = 64;
    return;
  }

  final libraryPath = File(arguments[0]).absolute.path;
  final exportName = arguments[1];
  if (!File(libraryPath).existsSync()) {
    stderr.writeln('Native library does not exist: $libraryPath');
    exitCode = 66;
    return;
  }

  final library = DynamicLibrary.open(libraryPath);
  library.lookup<NativeFunction<Void Function()>>(exportName);
  stdout.writeln(
    jsonEncode(<String, Object>{
      'result': 'passed',
      'abi': Abi.current().toString(),
      'library': libraryPath,
      'export': exportName,
    }),
  );
}
