import 'dart:async';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_attachment_parent_coordinator.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_outbound_staging.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('save timeout can quiesce preparation before parent readback', () async {
    final staging = _TrackedPreparation();
    final timeline = <String>[];
    final source = Object();
    final result = await prepareCloudSyncAttachmentParent(
      staging: staging,
      prepareChildren: () async {
        expect(staging.active, isTrue);
        timeline.add('children');
        return source;
      },
      drainChildren: () async {
        // Models the native-operation quiescence used on a save timeout.
        // If the coordinator still held preparation open, this would hang.
        await staging.quiesce().timeout(const Duration(seconds: 1));
        timeline.add('drain');
        return true;
      },
      requireChildReadback: () async => timeline.add('readback'),
    );
    expect(result, same(source));
    expect(timeline, ['children', 'drain', 'readback']);
  });

  for (final failure in ['prepare', 'drain', 'readback']) {
    test('$failure failure never returns parent authority', () async {
      final staging = _TrackedPreparation();
      final timeline = <String>[];
      await expectLater(prepareCloudSyncAttachmentParent(
        staging: staging,
        prepareChildren: () async {
          timeline.add('prepare');
          if (failure == 'prepare') throw StateError('prepare failed');
          return Object();
        },
        drainChildren: () async {
          timeline.add('drain');
          return failure != 'drain';
        },
        requireChildReadback: () async {
          timeline.add('readback');
          throw StateError('readback failed');
        },
      ), throwsStateError);
      expect(staging.active, isFalse);
      expect(timeline, failure == 'prepare' ? ['prepare'] :
          failure == 'drain' ? ['prepare', 'drain'] : ['prepare', 'drain', 'readback']);
    });
  }
}

final class _TrackedPreparation implements CloudSyncOutboundStagingTransport {
  bool active = false;
  Completer<void>? completion;
  @override
  Future<T> runOutboundAdmissionExclusive<T>(Future<T> Function() action) async {
    active = true;
    completion = Completer<void>();
    try { return await action(); } finally {
      active = false;
      completion!.complete();
    }
  }
  Future<void> quiesce() async { await completion?.future; }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
