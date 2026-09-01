import 'package:bluebubbles/app/layouts/settings/pages/misc/troubleshoot_panel.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_engine.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_manual_outbound_canary.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_models.dart';
import 'package:flutter_test/flutter_test.dart';

CloudSyncOutboundCanaryReport _report({
  bool recovery = false,
  bool replayVerification = false,
  CloudSyncRunStatus status = CloudSyncRunStatus.completed,
  int confirmed = 1,
  int quarantined = 0,
  int retried = 0,
  CloudOutboxStatus outboxStatus = CloudOutboxStatus.confirmed,
}) => CloudSyncOutboundCanaryReport(
  timestampUtc: DateTime.utc(2026),
  status: status,
  confirmed: confirmed,
  quarantined: quarantined,
  retried: retried,
  outboxStatus: outboxStatus,
  recovery: recovery,
  replayVerification: replayVerification,
);

void main() {
  test('initial exact create confirmation reports write confirmed', () {
    final presentation = cloudSyncV2OutboundCanaryPresentation(_report());

    expect(
      presentation.outcome,
      CloudSyncV2OutboundCanaryOutcome.writeConfirmed,
    );
    expect(presentation.message, contains('One create-only message record'));
    expect(presentation.message, contains('No deletes were enabled'));
  });

  test('terminal recovery with zero saves reports replay verified', () {
    final presentation = cloudSyncV2OutboundCanaryPresentation(
      _report(recovery: true, replayVerification: true, confirmed: 0),
    );

    expect(
      presentation.outcome,
      CloudSyncV2OutboundCanaryOutcome.replayVerified,
    );
    expect(presentation.message, contains('No new message was admitted'));
    expect(presentation.message, contains('no additional save'));
  });

  test('interrupted recovery reports that one create may complete', () {
    final presentation = cloudSyncV2OutboundCanaryPresentation(
      _report(recovery: true),
    );

    expect(
      presentation.outcome,
      CloudSyncV2OutboundCanaryOutcome.recoveryCompleted,
    );
    expect(
      presentation.message,
      contains('may have completed one remote create'),
    );
    expect(presentation.message, contains('no new message was admitted'));
  });

  test('quarantine is explicit and forbids automatic retry', () {
    final presentation = cloudSyncV2OutboundCanaryPresentation(
      _report(
        status: CloudSyncRunStatus.degraded,
        confirmed: 0,
        quarantined: 1,
        outboxStatus: CloudOutboxStatus.quarantined,
      ),
    );

    expect(presentation.outcome, CloudSyncV2OutboundCanaryOutcome.quarantined);
    expect(presentation.message, contains('Do not retry automatically'));
  });

  test('unexpected status or counters remain unresolved', () {
    final reports = <CloudSyncOutboundCanaryReport>[
      _report(status: CloudSyncRunStatus.degraded),
      _report(confirmed: 0),
      _report(retried: 1),
      _report(outboxStatus: CloudOutboxStatus.unknownOutcome),
      _report(recovery: true, replayVerification: true, confirmed: 1),
    ];

    for (final report in reports) {
      final presentation = cloudSyncV2OutboundCanaryPresentation(report);
      expect(presentation.outcome, CloudSyncV2OutboundCanaryOutcome.unresolved);
      expect(presentation.message, contains('Do not retry automatically'));
    }
  });

  test('all presentation text remains content-free', () {
    final presentations = <CloudSyncV2OutboundCanaryPresentation>[
      cloudSyncV2OutboundCanaryPresentation(_report()),
      cloudSyncV2OutboundCanaryPresentation(
        _report(recovery: true, replayVerification: true, confirmed: 0),
      ),
      cloudSyncV2OutboundCanaryPresentation(_report(recovery: true)),
      cloudSyncV2OutboundCanaryPresentation(
        _report(
          status: CloudSyncRunStatus.degraded,
          confirmed: 0,
          quarantined: 1,
          outboxStatus: CloudOutboxStatus.quarantined,
        ),
      ),
      cloudSyncV2OutboundCanaryPresentation(
        _report(outboxStatus: CloudOutboxStatus.unknownOutcome),
      ),
    ];

    for (final presentation in presentations) {
      final output = '${presentation.title} ${presentation.message}';
      expect(output, isNot(contains('message.text')));
      expect(output, isNot(contains('destination')));
      expect(output, isNot(contains('recipient')));
      expect(output, isNot(contains('CloudMessage')));
    }
  });
}
