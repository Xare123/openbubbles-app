import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final runnerSource = File(
    'windows/runner/win32_window.cpp',
  ).readAsStringSync();
  final runnerHeader = File('windows/runner/win32_window.h').readAsStringSync();

  test('official runner claims the single-instance mutex atomically', () {
    final methodStart = runnerSource.indexOf(
      'bool Win32Window::SendAppLinkToInstance',
    );
    expect(methodStart, greaterThanOrEqualTo(0));
    final method = runnerSource.substring(methodStart);

    expect(method, isNot(contains('OpenMutex(')));

    final clearError = method.indexOf('SetLastError(ERROR_SUCCESS)');
    final createMutex = method.indexOf('CreateMutexW(');
    final captureError = method.indexOf('GetLastError()', createMutex);
    final existingDecision = method.indexOf(
      'create_error != ERROR_ALREADY_EXISTS',
      captureError,
    );
    final retainHandle = method.indexOf(
      'single_instance_mutex_ = candidate_mutex',
      existingDecision,
    );
    final secondaryClose = method.indexOf(
      'CloseHandle(candidate_mutex)',
      retainHandle,
    );

    expect(clearError, greaterThanOrEqualTo(0));
    expect(createMutex, greaterThan(clearError));
    expect(captureError, greaterThan(createMutex));
    expect(existingDecision, greaterThan(captureError));
    expect(retainHandle, greaterThan(existingDecision));
    expect(secondaryClose, greaterThan(retainHandle));
  });

  test('mutex is established before window and Flutter initialization', () {
    final createStart = runnerSource.indexOf('bool Win32Window::Create(');
    final createEnd = runnerSource.indexOf(
      'bool Win32Window::Show()',
      createStart,
    );
    expect(createStart, greaterThanOrEqualTo(0));
    expect(createEnd, greaterThan(createStart));

    final createMethod = runnerSource.substring(createStart, createEnd);
    final singleInstanceDecision = createMethod.indexOf(
      'SendAppLinkToInstance(title)',
    );
    final createWindow = createMethod.indexOf('CreateWindow(');
    final flutterInitialization = createMethod.indexOf('return OnCreate()');

    expect(singleInstanceDecision, greaterThanOrEqualTo(0));
    expect(createWindow, greaterThan(singleInstanceDecision));
    expect(flutterInitialization, greaterThan(createWindow));
  });

  test('first-instance handle lives until runner destruction', () {
    expect(runnerHeader, contains('HANDLE single_instance_mutex_ = nullptr;'));

    final destructorStart = runnerSource.indexOf('Win32Window::~Win32Window()');
    final destructorEnd = runnerSource.indexOf(
      'bool Win32Window::Create(',
      destructorStart,
    );
    expect(destructorStart, greaterThanOrEqualTo(0));
    expect(destructorEnd, greaterThan(destructorStart));
    final destructor = runnerSource.substring(destructorStart, destructorEnd);

    expect(destructor, contains('CloseHandle(single_instance_mutex_)'));
    expect(destructor, contains('single_instance_mutex_ = nullptr'));
  });

  test('secondary launch retains app-link forwarding behavior', () {
    final methodStart = runnerSource.indexOf(
      'bool Win32Window::SendAppLinkToInstance',
    );
    final method = runnerSource.substring(methodStart);
    final secondaryClose = method.indexOf('CloseHandle(candidate_mutex)');
    final windowLookup = method.indexOf(
      'FindExistingInstanceWindow(title)',
      secondaryClose,
    );
    final sendAppLink = method.indexOf('SendAppLink(hwnd)', windowLookup);
    final foreground = method.indexOf('SetForegroundWindow(hwnd)', sendAppLink);

    expect(secondaryClose, greaterThanOrEqualTo(0));
    expect(windowLookup, greaterThan(secondaryClose));
    expect(sendAppLink, greaterThan(windowLookup));
    expect(foreground, greaterThan(sendAppLink));
  });
}
