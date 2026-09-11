import 'dart:io';

import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('IDS 6005 produces a registration repair notice', () {
    expect(
      faceTimeOutgoingStartFailureMessage(
        Exception('Registration Error Bad authentication. (6005)'),
      ),
      'Your iMessage registration needs repair. No FaceTime call was placed.',
    );
  });

  test('other start failures never claim a call was placed', () {
    expect(
      faceTimeOutgoingStartFailureMessage(Exception('network unavailable')),
      'FaceTime could not start. No call was placed.',
    );
  });

  test('ringing overlay is admitted only after session creation succeeds', () {
    final source = File(
      'lib/services/rustpush/rustpush_service.dart',
    ).readAsStringSync();
    final start = source.indexOf('Future<void> placeOutgoingCall(');
    final end = source.indexOf(
      '\n  // returns handle to show poster of',
      start,
    );
    final method = source.substring(start, end);

    expect(method.indexOf('await api.createFacetime('), greaterThan(-1));
    expect(method.indexOf('showOutgoingFaceTimeOverlay('), greaterThan(-1));
    expect(
      method.indexOf('await api.createFacetime('),
      lessThan(method.indexOf('showOutgoingFaceTimeOverlay(')),
    );
    expect(method, contains('await _outgoingCalls.complete(call, () async {'));
    expect(method, contains('faceTimeOutgoingStartFailureMessage(error)'));
  });

  test('timed-out sessions release local state even if cancellation fails', () {
    final source = File(
      'lib/services/rustpush/rustpush_service.dart',
    ).readAsStringSync();
    final timeoutStart = source.indexOf(
      '_outgoingCalls.armTimeout(call, () async {',
    );
    final timeoutFinish = source.indexOf('Uint8List? icon;', timeoutStart);

    expect(timeoutStart, greaterThanOrEqualTo(0));
    expect(timeoutFinish, greaterThan(timeoutStart));
    final timeoutBlock = source.substring(timeoutStart, timeoutFinish);
    expect(timeoutBlock, contains('await api.cancelFacetime('));
    expect(timeoutBlock, contains('} catch (error, trace) {'));
    expect(timeoutBlock, contains('} finally {'));
    expect(timeoutBlock, contains('call.state.value = "timeout";'));
    expect(timeoutBlock, contains('"callUuid": outgoingguid'));
    final lifecycle = File(
      'lib/services/rustpush/face_time_outgoing_lifecycle.dart',
    ).readAsStringSync();
    expect(
      lifecycle,
      contains('if (identical(current, call)) _current = null;'),
    );
    expect(lifecycle, contains('unawaited(complete(call, action))'));
  });

  test('End releases local state even if remote cancellation fails', () {
    final source = File(
      'lib/helpers/ui/facetime_helpers.dart',
    ).readAsStringSync();
    final endStart = source.indexOf('phoneButton("End"');
    final endFinish = source.indexOf('const SizedBox(height: 60,)', endStart);

    expect(endStart, greaterThanOrEqualTo(0));
    expect(endFinish, greaterThan(endStart));
    final endBlock = source.substring(endStart, endFinish);
    expect(
      endBlock,
      contains('await pushService.endOutgoingFaceTime(callUuid)'),
    );
    expect(endBlock, isNot(contains('outgoingCallTimer')));
    final service = File(
      'lib/services/rustpush/rustpush_service.dart',
    ).readAsStringSync();
    final endMethod = service.substring(
      service.indexOf('Future<void> endOutgoingFaceTime('),
      service.indexOf('Future<void> placeOutgoingCall('),
    );
    expect(
      endMethod,
      contains('if (call == null || call.id != callUuid) return;'),
    );
    expect(
      endMethod,
      contains('await _outgoingCalls.complete(call, () async {'),
    );
    expect(endMethod, contains('await api.cancelFacetime('));
    expect(endMethod, contains('} catch (error, trace) {'));
  });

  test('Call Again is an explicit manual retry after dismissing stale UI', () {
    final source = File(
      'lib/helpers/ui/facetime_helpers.dart',
    ).readAsStringSync();
    final retryStart = source.indexOf('phoneButton("Call Again"');
    final retryFinish = source.indexOf('phoneButton("End"', retryStart);

    expect(retryStart, greaterThanOrEqualTo(0));
    expect(retryFinish, greaterThan(retryStart));
    final retryBlock = source.substring(retryStart, retryFinish);
    expect(retryBlock, contains('hideFaceTimeOverlay(callUuid);'));
    expect(retryBlock, contains('await pushService.placeOutgoingCall('));
    expect(
      retryBlock.indexOf('hideFaceTimeOverlay(callUuid);'),
      lessThan(retryBlock.indexOf('await pushService.placeOutgoingCall(')),
    );
  });

  test('session creation failure returns without an automatic retry', () {
    final source = File(
      'lib/services/rustpush/rustpush_service.dart',
    ).readAsStringSync();
    final start = source.indexOf('Future<void> placeOutgoingCall(');
    final finish = source.indexOf(
      '\n  // returns handle to show poster of',
      start,
    );
    final method = source.substring(start, finish);
    final catchStart = method.indexOf('} catch (error, trace) {');
    final catchFinish = method.indexOf(
      '// Failure to prepare a subsequent link',
      catchStart,
    );

    expect(catchStart, greaterThanOrEqualTo(0));
    expect(catchFinish, greaterThan(catchStart));
    final catchBlock = method.substring(catchStart, catchFinish);
    expect(
      catchBlock,
      contains('await _outgoingCalls.complete(call, () async {'),
    );
    expect(catchBlock, contains('return;'));
    expect(catchBlock, isNot(contains('placeOutgoingCall(')));
    expect(catchBlock, isNot(contains('showOutgoingFaceTimeOverlay(')));
  });

  test(
    'production setup, JoinEvent and decline all use the tested identity seam',
    () {
      final source = File(
        'lib/services/rustpush/rustpush_service.dart',
      ).readAsStringSync();
      final start = source.indexOf('Future<void> placeOutgoingCall(');
      final finish = source.indexOf(
        '// returns handle to show poster of',
        start,
      );
      final setup = source.substring(start, finish);
      expect(
        setup.indexOf('_outgoingCalls.begin('),
        lessThan(setup.indexOf('await api.getFtLink(')),
      );
      expect(
        setup.indexOf('if (!_outgoingCalls.isPending(call)) return;'),
        lessThan(setup.indexOf('await api.createFacetime(')),
      );
      expect(setup, contains('if (_outgoingCalls.isPending(call)) {'));
      expect(
        source,
        contains('await _outgoingCalls.complete(outgoingCall, () async {'),
      );
      expect(source, contains('outgoingCall.state.value = "accepted";'));
      expect(source, contains('outgoingCall.state.value = "declined";'));
      expect(source, contains('"launch-facetime", outgoingCall.metadata'));
      expect(source, isNot(contains('currentOutgoingCall = null;')));
      expect(source, isNot(contains('outgoingCallMeta = {}')));
    },
  );
}
