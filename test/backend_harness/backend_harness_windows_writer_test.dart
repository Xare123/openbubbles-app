import 'package:bluebubbles/backend_harness/backend_harness_windows_writer.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_automatic_archive_preference.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const owner = '12345678-1234-4123-8123-123456789abc';
  bool mode({
    bool compiled = false,
    bool environment = false,
    String recovery = '',
    bool legacy = false,
    bool v2 = false,
    bool outbound = false,
    bool automatic = false,
  }) => backendHarnessWindowsWriterModeAllowed(
    writerCompiled: compiled,
    writerEnvironment: environment,
    recoveryOwner: recovery,
    legacyWriter: legacy,
    v2Writer: v2,
    outbound: outbound,
    automaticUploads: automatic,
  );

  test('read-only cannot inherit any writer selector or recovery owner', () {
    expect(mode(), isTrue);
    expect(mode(environment: true), isFalse);
    expect(mode(recovery: owner), isFalse);
    expect(mode(legacy: true), isFalse);
    expect(mode(v2: true), isFalse);
    expect(mode(outbound: true), isFalse);
    expect(mode(automatic: true), isFalse);
  });

  test('writer requires every independent admission and a retained owner', () {
    bool writer({
      bool compiled = true,
      bool environment = true,
      String recovery = owner,
      bool legacy = false,
      bool v2 = true,
      bool outbound = true,
      bool automatic = true,
    }) => mode(
      compiled: compiled,
      environment: environment,
      recovery: recovery,
      legacy: legacy,
      v2: v2,
      outbound: outbound,
      automatic: automatic,
    );
    expect(writer(), isTrue);
    expect(writer(compiled: false), isFalse);
    expect(writer(environment: false), isFalse);
    expect(writer(recovery: ''), isFalse);
    expect(writer(recovery: '$owner\n'), isFalse);
    expect(writer(legacy: true), isFalse);
    expect(writer(v2: false), isFalse);
    expect(writer(outbound: false), isFalse);
    expect(writer(automatic: false), isFalse);
  });

  test('Windows fixture binds exact admitted owner and this boot consent', () {
    bool allowed({
      String? admitted = owner,
      Object? requested = owner,
      bool ready = true,
      bool windows = true,
    }) => backendHarnessRetainedFixtureAllowed(
      isWindows: windows,
      admittedOwner: admitted,
      requestedOwner: requested,
      archiveSessionReady: ready,
    );
    expect(allowed(), isTrue);
    expect(allowed(admitted: null), isFalse);
    expect(allowed(requested: '12345678-1234-4123-8123-123456789abd'), isFalse);
    expect(allowed(ready: false), isFalse);
    expect(allowed(windows: false, admitted: null, ready: false), isTrue);
  });

  CloudSyncAutomaticArchivePreference consent({
    String account = 'a',
    int epoch = 7,
    String grant = 'c',
    bool enabled = true,
  }) => CloudSyncAutomaticArchivePreference(
    identity: CloudSyncAutomaticArchiveIdentity(
      accountFingerprint: List.filled(43, account).join(),
      protectedStoreIdentity: 'obcs2.store.${List.filled(43, 'b').join()}',
      ownershipEpoch: epoch,
    ),
    storedValue: enabled
        ? '[1,"queued-and-future-local-sends",$epoch,"${List.filled(32, grant).join()}"]'
        : null,
  );

  test(
    'persisted archive consent never admits a fresh host boot by itself',
    () {
      final first = CloudSyncArchiveSessionAcknowledgment();
      final saved = consent();
      expect(first.ready, isFalse);
      expect(first.allows(saved), isFalse);
      var stillGranted = true;
      first.saved(saved, stillGranted: () => stillGranted);
      expect(first.ready, isTrue);
      expect(first.allows(consent()), isTrue);
      expect(first.allows(consent(account: 'd')), isFalse);
      expect(first.allows(consent(epoch: 8)), isFalse);
      expect(first.allows(consent(grant: 'e')), isFalse);
      expect(CloudSyncArchiveSessionAcknowledgment().allows(saved), isFalse);
      stillGranted = false;
      expect(first.ready, isFalse);
      expect(first.allows(saved), isFalse);
      stillGranted = true;
      first.saved(consent(enabled: false), stillGranted: () => true);
      expect(first.ready, isFalse);
      expect(first.allows(saved), isFalse);
    },
  );
}
