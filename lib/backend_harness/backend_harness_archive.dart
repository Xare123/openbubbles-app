import 'dart:math';

import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_automatic_archive_preference.dart';

import 'backend_harness_protocol.dart';

typedef BackendArchiveWriter =
    Future<CloudSyncAutomaticArchivePreference> Function(
      CloudSyncAutomaticArchivePreference expected,
      bool enabled,
      bool acknowledgeQueuedUploads,
      bool includeReceived,
      bool includeReceivedMedia,
    );

/// A bounded confirmation for the existing account/store/epoch-bound Profile
/// preference. No direct preference writes, queue processing or IDS sending.
final class BackendHarnessArchive {
  BackendHarnessArchive({
    required this.read,
    required this.write,
    this.readCounts,
    DateTime Function()? now,
    Random? random,
  }) : _now = now ?? DateTime.now,
       _random = random ?? Random.secure();
  final Future<CloudSyncAutomaticArchivePreference> Function() read;
  final BackendArchiveWriter write;
  final Map<String, int> Function(CloudSyncAutomaticArchivePreference)? readCounts;
  final DateTime Function() _now;
  final Random _random;
  CloudSyncAutomaticArchivePreference? _expected;
  String? _confirmation;
  DateTime? _expires;

  static bool validScope(Map<String, Object?> args) =>
      args.length == 5 &&
      args.keys.every(
        const {
          'confirmationId',
          'enabled',
          'acknowledgeQueuedUploads',
          'includeReceived',
          'includeReceivedMedia',
        }.contains,
      ) &&
      args['confirmationId'] is String &&
      RegExp(r'^[a-f0-9]{32}$').hasMatch(args['confirmationId'] as String) &&
      const [
        'enabled',
        'acknowledgeQueuedUploads',
        'includeReceived',
        'includeReceivedMedia',
      ].every((key) => args[key] is bool) &&
      (args['enabled'] == false || args['acknowledgeQueuedUploads'] == true) &&
      (args['includeReceivedMedia'] == false ||
          args['includeReceived'] == true);

  BackendHarnessPayload _payload(
    CloudSyncAutomaticArchivePreference value, {
    BackendHarnessChallenge? challenge,
  }) => BackendHarnessPayload(
    flags: {
      'archive_enabled': value.enabled,
      'received_text_enabled': value.includesReceived,
      'received_media_enabled': value.includesReceivedMedia,
    },
    counts: readCounts?.call(value) ?? const {},
    challenge: challenge,
  );

  Future<BackendHarnessPayload> status() async => _payload(await read());

  Future<BackendHarnessPayload> prepare() async {
    final expected = await read();
    final id = List.generate(
      16,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    _expected = expected;
    _confirmation = id;
    _expires = _now().add(const Duration(minutes: 2));
    return _payload(
      expected,
      challenge: BackendHarnessChallenge(
        id,
        BackendHarnessChallengeKind.archiveConsent,
      ),
    );
  }

  Future<BackendHarnessPayload> setScope(Map<String, Object?> args) async {
    if (!validScope(args)) {
      throw BackendHarnessFailure('backend_invalid_arguments');
    }
    final expected = _expected;
    final expires = _expires;
    if (expected == null ||
        args['confirmationId'] != _confirmation ||
        expires == null ||
        !_now().isBefore(expires)) {
      throw BackendHarnessFailure('backend_stale_session');
    }
    // Consume before any asynchronous write. An uncertain save cannot cause
    // the host to repeat this confirmation with a different request ID.
    _expected = null;
    _confirmation = null;
    _expires = null;
    return _payload(
      await write(
        expected,
        args['enabled'] as bool,
        args['acknowledgeQueuedUploads'] as bool,
        args['includeReceived'] as bool,
        args['includeReceivedMedia'] as bool,
      ),
    );
  }
}
