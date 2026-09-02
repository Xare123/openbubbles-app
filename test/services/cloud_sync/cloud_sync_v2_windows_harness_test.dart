import 'dart:io';

import 'package:bluebubbles/cloud_sync_v2_windows_harness.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_provenance.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter_test/flutter_test.dart';

void main() {
  const launchId = '0123456789abcdef0123456789abcdef';

  test(
    'parses interactive, run-once, drain, attachment, and viewers',
    () {
      expect(
        CloudSyncV2WindowsHarnessLaunch.parse(const [
          '--launch-id=$launchId',
        ]).operation,
        CloudSyncV2WindowsHarnessOperation.interactive,
      );
      expect(
        CloudSyncV2WindowsHarnessLaunch.parse(const [
          'run-once',
          '--launch-id=$launchId',
        ]).operation,
        CloudSyncV2WindowsHarnessOperation.runOnce,
      );
      expect(
        CloudSyncV2WindowsHarnessLaunch.parse(const [
          '--launch-id=$launchId',
          'drain',
        ]).operation,
        CloudSyncV2WindowsHarnessOperation.drain,
      );
      expect(
        CloudSyncV2WindowsHarnessLaunch.parse(const [
          'probe-attachment',
          '--launch-id=$launchId',
        ]).operation,
        CloudSyncV2WindowsHarnessOperation.attachmentProbe,
      );
      expect(
        CloudSyncV2WindowsHarnessLaunch.parse(const [
          'view-projection',
          '--launch-id=$launchId',
        ]).operation,
        CloudSyncV2WindowsHarnessOperation.projectionViewer,
      );
      expect(
        CloudSyncV2WindowsHarnessLaunch.parse(const [
          'view-projection-detail',
          '--launch-id=$launchId',
        ]).operation,
        CloudSyncV2WindowsHarnessOperation.projectionDetailViewer,
      );
    },
  );

  test('rejects missing, malformed, duplicate, and ambiguous launch input', () {
    final candidates = <List<String>>[
      const [],
      const ['drain'],
      const ['--launch-id=not-hex'],
      const ['--launch-id=$launchId', '--launch-id=$launchId'],
      const ['run-once', 'drain', '--launch-id=$launchId'],
      const ['probe-attachment', 'drain', '--launch-id=$launchId'],
      const ['view-projection', 'run-once', '--launch-id=$launchId'],
      const [
        'view-projection-detail',
        'view-projection',
        '--launch-id=$launchId',
      ],
    ];

    for (final candidate in candidates) {
      expect(
        () => CloudSyncV2WindowsHarnessLaunch.parse(candidate),
        throwsStateError,
        reason: candidate.toString(),
      );
    }
  });

  test('status payload binds every record to the launch id and Dart pid', () {
    final payload = cloudSyncV2WindowsHarnessStatusPayload(
      launchId: launchId,
      processId: 4242,
      state: 'running',
      stage: 'semantic-drain',
      updatedUtc: DateTime.utc(2026, 8, 31, 12),
    );

    expect(payload['version'], 'cloud-sync-v2-windows-harness-status-v2');
    expect(payload['launch_id'], launchId);
    expect(payload['process_id'], 4242);
    expect(payload['state'], 'running');
    expect(payload['stage'], 'semantic-drain');
  });

  test(
    'status replacement retries transient Windows sharing violations',
    () async {
      var attempts = 0;
      final delays = <Duration>[];

      await retryCloudSyncV2WindowsHarnessStatusReplace(
        replace: () async {
          attempts += 1;
          if (attempts < 3) {
            throw const FileSystemException('sharing violation');
          }
        },
        delay: (duration) async => delays.add(duration),
      );

      expect(attempts, 3);
      expect(delays, const [
        Duration(milliseconds: 25),
        Duration(milliseconds: 25),
      ]);
    },
  );

  test('status replacement preserves the final filesystem failure', () async {
    var attempts = 0;

    await expectLater(
      retryCloudSyncV2WindowsHarnessStatusReplace(
        maximumAttempts: 2,
        replace: () async {
          attempts += 1;
          throw const FileSystemException('still locked');
        },
        delay: (_) async {},
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(attempts, 2);
  });

  test(
    'pass limit is resumable while remote-drained outcomes are finished',
    () {
      final passLimit = cloudSyncV2WindowsHarnessDrainTerminalStatus(
        reachedPassLimit: true,
        projectionComplete: true,
      );
      expect(passLimit.state, 'resumable');
      expect(passLimit.stage, 'semantic-drain-pass-limit');

      final complete = cloudSyncV2WindowsHarnessDrainTerminalStatus(
        reachedPassLimit: false,
        projectionComplete: true,
      );
      expect(complete.state, 'finished');
      expect(complete.stage, 'semantic-drain-complete');

      final projectionPartial = cloudSyncV2WindowsHarnessDrainTerminalStatus(
        reachedPassLimit: false,
        projectionComplete: false,
      );
      expect(projectionPartial.state, 'finished');
      expect(
        projectionPartial.stage,
        'semantic-drain-remote-complete-projection-partial',
      );
    },
  );

  test('cold read authentication starts one fresh login only', () {
    expect(
      cloudSyncV2WindowsHarnessShouldStartFreshReadAuthentication(
        safeCode: 'cloud_sync_native_auth_refresh_session_missing',
        alreadyAttempted: false,
      ),
      isTrue,
    );
    expect(
      cloudSyncV2WindowsHarnessShouldStartFreshReadAuthentication(
        safeCode: 'cloud_sync_native_auth_refresh_session_missing',
        alreadyAttempted: true,
      ),
      isFalse,
    );
    expect(
      cloudSyncV2WindowsHarnessShouldStartFreshReadAuthentication(
        safeCode: 'cloud_sync_native_auth_refresh_transport_failed',
        alreadyAttempted: false,
      ),
      isFalse,
    );
  });

  test('projection titles prefer display name and use safe fallbacks', () {
    expect(
      cloudSyncV2WindowsProjectionChatTitle(
        displayName: '  Family  ',
        chatIdentifier: 'fallback',
      ),
      'Family',
    );
    expect(
      cloudSyncV2WindowsProjectionChatTitle(
        displayName: '   ',
        chatIdentifier: '  identifier  ',
      ),
      'identifier',
    );
    expect(
      cloudSyncV2WindowsProjectionChatTitle(
        displayName: null,
        chatIdentifier: null,
      ),
      'Unnamed conversation',
    );
  });

  test('attachment probe selects the smallest absent materializable body', () {
    Map<String, dynamic> metadata(CloudAttachmentBodyCapability capability) =>
        <String, dynamic>{
          cloudAttachmentV2MetadataKey: cloudAttachmentV2MetadataVersion,
          cloudAttachmentV2BodyCapabilityKey: capability.metadataValue,
        };
    final candidates = <Attachment>[
      Attachment(
        id: 1,
        guid: 'already-present',
        transferName: 'one.bin',
        totalBytes: 1,
        metadata: metadata(CloudAttachmentBodyCapability.materializable),
      ),
      Attachment(
        id: 2,
        guid: 'larger',
        transferName: 'two.bin',
        totalBytes: 2048,
        metadata: metadata(CloudAttachmentBodyCapability.materializable),
      ),
      Attachment(
        id: 3,
        guid: 'smallest',
        transferName: 'three.bin',
        totalBytes: 1024,
        metadata: metadata(CloudAttachmentBodyCapability.materializable),
      ),
      Attachment(
        id: 4,
        guid: 'metadata-only',
        transferName: 'four.bin',
        totalBytes: 8,
        metadata: metadata(
          CloudAttachmentBodyCapability.metadataOnlyUnsupportedMediaCredentials,
        ),
      ),
      Attachment(
        id: 5,
        guid: 'too-large',
        transferName: 'five.bin',
        totalBytes: 4096,
        metadata: metadata(CloudAttachmentBodyCapability.materializable),
      ),
    ];

    final selected = cloudSyncV2WindowsSelectAttachmentProbeCandidate(
      candidates,
      maximumExpectedBytes: 3000,
      existsOnDisk: (attachment) => attachment.guid == 'already-present',
    );

    expect(selected?.guid, 'smallest');
  });

  test('attachment probe rejects incomplete or legacy candidates', () {
    final legacyV2 = <String, dynamic>{
      cloudAttachmentV2MetadataKey: cloudAttachmentV2LegacyMetadataVersion,
    };
    final currentV2 = <String, dynamic>{
      cloudAttachmentV2MetadataKey: cloudAttachmentV2MetadataVersion,
      cloudAttachmentV2BodyCapabilityKey:
          CloudAttachmentBodyCapability.materializable.metadataValue,
    };
    final candidates = <Attachment>[
      Attachment(
        guid: 'legacy',
        transferName: 'legacy.bin',
        totalBytes: 1,
        metadata: legacyV2,
      ),
      Attachment(guid: 'missing-name', totalBytes: 1, metadata: currentV2),
      Attachment(
        guid: 'missing-size',
        transferName: 'missing-size.bin',
        metadata: currentV2,
      ),
    ];

    expect(
      cloudSyncV2WindowsSelectAttachmentProbeCandidate(
        candidates,
        existsOnDisk: (_) => false,
      ),
      isNull,
    );
    expect(
      () => cloudSyncV2WindowsSelectAttachmentProbeCandidate(
        const <Attachment>[],
        maximumExpectedBytes: 0,
      ),
      throwsArgumentError,
    );
  });

  test('attachment probe accepts only the exact disposable marker', () async {
    final directory = await Directory.systemTemp.createTemp(
      'openbubbles-attachment-probe-marker-',
    );
    addTearDown(() async {
      if (directory.existsSync()) await directory.delete(recursive: true);
    });
    final marker = File(
      '${directory.path}${Platform.pathSeparator}'
      '$cloudSyncV2WindowsAttachmentProbeMarkerFileName',
    );

    expect(cloudSyncV2WindowsAttachmentProbeProfileIsMarked(directory), isFalse);
    await marker.writeAsString('wrong');
    expect(cloudSyncV2WindowsAttachmentProbeProfileIsMarked(directory), isFalse);
    await marker.writeAsString(
      cloudSyncV2WindowsAttachmentProbeMarkerContents,
    );
    expect(cloudSyncV2WindowsAttachmentProbeProfileIsMarked(directory), isTrue);
  });

  test('projection bodies normalize content and identify non-text rows', () {
    String body({
      String? text,
      String? attributedText,
      String? subject,
      bool attachment = false,
      bool associated = false,
      bool event = false,
    }) => cloudSyncV2WindowsProjectionBody(
      text: text,
      attributedText: attributedText,
      subject: subject,
      hasAttachments: attachment,
      isAssociated: associated,
      isEvent: event,
    );

    expect(body(text: '  one\n two  ', attributedText: 'ignored'), 'one two');
    expect(body(attributedText: ' attributed '), 'attributed');
    expect(body(subject: ' subject '), 'subject');
    expect(body(attachment: true), '[Attachment]');
    expect(body(associated: true), '[Reaction or associated message]');
    expect(body(event: true), '[Conversation event]');
    expect(body(), '[No renderable content]');
  });

  test(
    'fresh login state selects only an explicit authenticated or 2FA lane',
    () {
      expect(
        cloudSyncV2WindowsHarnessReadAuthAction(
          const api.LoginState.loggedIn(),
        ),
        CloudSyncV2WindowsReadAuthAction.activate,
      );
      expect(
        cloudSyncV2WindowsHarnessReadAuthAction(
          const api.LoginState.needsSms2Fa(),
        ),
        CloudSyncV2WindowsReadAuthAction.requestSmsTwoFactor,
      );
      expect(
        cloudSyncV2WindowsHarnessReadAuthAction(
          const api.LoginState.needsDevice2Fa(),
        ),
        CloudSyncV2WindowsReadAuthAction.requestSmsTwoFactor,
      );
      expect(
        cloudSyncV2WindowsHarnessReadAuthAction(
          const api.LoginState.needsLogin(),
        ),
        CloudSyncV2WindowsReadAuthAction.reject,
      );
    },
  );
}
