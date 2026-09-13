// Synthetic process-discovery fixture. No packages, profile, FFI or network.
import 'dart:async';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  if (arguments.length == 2 && arguments.first == 'spawn') {
    final child = await Process.start(arguments[1], [Platform.script.toFilePath()]);
    await child.exitCode;
  } else {
    await Future<void>.delayed(const Duration(seconds: 30));
  }
}
