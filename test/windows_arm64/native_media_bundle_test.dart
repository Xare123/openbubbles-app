import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

void main() {
  const cmakePath =
      'third_party/media_kit_libs_windows_video/windows/CMakeLists.txt';
  const verifierPath = 'tooling/windows_arm64/verify_pe_machine.ps1';

  test('native media CMake pins explicit x64 and ARM64 archives', () {
    final cmake = File(cmakePath).readAsStringSync();

    expect(cmake, contains('STREQUAL "windows-x64"'));
    expect(cmake, contains('STREQUAL "windows-arm64"'));
    expect(cmake, contains('unsupported FLUTTER_TARGET_PLATFORM'));
    expect(
      cmake,
      contains(
        'd445d02ab2ee60b1b5988f08ce4d2394cdcc594e98321b746a313313e96133ae',
      ),
    );
    expect(
      cmake,
      contains(
        '151a9a191af3711cc90e1c415e0affc60854ed089fb3defdc8bbf023f3806083',
      ),
    );
    expect(cmake, contains('verify_pe_machine.ps1'));
    expect(cmake, isNot(contains('function(download_and_verify url md5')));
  });

  test(
    'PE verifier accepts ARM64 and rejects an x64 expectation',
    () async {
      final temporaryDirectory =
          await Directory.systemTemp.createTemp('openbubbles-pe-test-');
      addTearDown(() => temporaryDirectory.delete(recursive: true));

      final dll = File(
          '${temporaryDirectory.path}${Platform.pathSeparator}fixture.dll');
      await dll.writeAsBytes(_minimalPe(machine: 0xAA64));

      final powershell = File(
        '${Platform.environment['SystemRoot']}'
        r'\System32\WindowsPowerShell\v1.0\powershell.exe',
      ).path;
      final commonArguments = [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        verifierPath,
      ];

      final accepted = await Process.run(
        powershell,
        [
          ...commonArguments,
          '-Architecture',
          'arm64',
          '-Root',
          temporaryDirectory.path,
        ],
      );
      expect(accepted.exitCode, 0, reason: '${accepted.stderr}');

      final rejected = await Process.run(
        powershell,
        [
          ...commonArguments,
          '-Architecture',
          'x64',
          '-Root',
          temporaryDirectory.path,
        ],
      );
      expect(rejected.exitCode, isNot(0));
      expect('${rejected.stderr}', contains('fixture.dll=0xAA64'));
    },
    skip: !Platform.isWindows,
  );
}

Uint8List _minimalPe({required int machine}) {
  final bytes = Uint8List(512);
  final data = ByteData.sublistView(bytes);
  bytes[0] = 0x4D;
  bytes[1] = 0x5A;
  data.setUint32(0x3C, 0x80, Endian.little);
  data.setUint32(0x80, 0x00004550, Endian.little);
  data.setUint16(0x84, machine, Endian.little);
  return bytes;
}
