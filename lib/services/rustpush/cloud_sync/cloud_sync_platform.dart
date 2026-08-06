import 'package:path/path.dart' as path;

import 'cloud_sync_engine.dart';
import 'cloud_sync_runtime.dart';

enum CloudSyncPlatformKind { android, windows }

enum CloudSyncArchitecture { arm64, x64 }

/// Account and private-storage boundary supplied by the platform bootstrap.
///
/// [accountFingerprint] is the protected application-scoped fingerprint, never
/// a DSID or Apple Account address. The private storage directory is used only
/// for platform protection material and must not be a filesystem root.
final class CloudSyncPlatformContext {
  CloudSyncPlatformContext({
    required this.platform,
    required this.architecture,
    required String accountFingerprint,
    required String privateStorageDirectory,
  }) : accountFingerprint = _requireNonempty(
         accountFingerprint,
         'accountFingerprint',
       ),
       privateStorageDirectory = _validatePrivateStorageDirectory(
         privateStorageDirectory,
       );

  final CloudSyncPlatformKind platform;
  final CloudSyncArchitecture architecture;
  final String accountFingerprint;
  final String privateStorageDirectory;

  static String _requireNonempty(String value, String name) {
    final normalized = value.trim();
    if (normalized.isEmpty) throw ArgumentError.value(value, name);
    return normalized;
  }

  static String _validatePrivateStorageDirectory(String value) {
    final normalized = _requireNonempty(value, 'privateStorageDirectory');
    final style = normalized.startsWith('/')
        ? path.Style.posix
        : path.Style.windows;
    final context = path.Context(style: style);
    if (!context.isAbsolute(normalized)) {
      throw ArgumentError.value(
        value,
        'privateStorageDirectory',
        'Must be an absolute private application-support directory',
      );
    }
    final canonical = context.normalize(normalized);
    if (canonical == context.rootPrefix(canonical)) {
      throw ArgumentError.value(
        value,
        'privateStorageDirectory',
        'A filesystem root is not a valid private storage directory',
      );
    }
    return canonical;
  }
}

/// Future platform wake sources. Every source is disabled by default.
///
/// Enabling a field alone is insufficient: [automaticTriggerRolloutEnabled]
/// must also be enabled when composing the adapter. This two-key boundary
/// prevents a platform callback from accidentally activating the dormant
/// shadow engine.
class CloudSyncPlatformTriggerPolicy {
  const CloudSyncPlatformTriggerPolicy({
    this.androidApnsWake = false,
    this.androidWorkManagerWake = false,
    this.windowsStartup = false,
    this.windowsResume = false,
    this.networkReconnect = false,
  });

  final bool androidApnsWake;
  final bool androidWorkManagerWake;
  final bool windowsStartup;
  final bool windowsResume;
  final bool networkReconnect;
}

/// Dormant lifecycle owner for one account-scoped shadow runtime.
///
/// It contains no timers or polling. A manual run is possible only when the
/// developer sampler gate is explicitly supplied by its future composition.
class CloudSyncPlatformAdapter {
  CloudSyncPlatformAdapter({
    required this.context,
    required CloudSyncShadowRuntime runtime,
    this.triggerPolicy = const CloudSyncPlatformTriggerPolicy(),
    this.manualSamplerEnabled = false,
    this.automaticTriggerRolloutEnabled = false,
  }) : _runtime = runtime {
    if (_runtime.automaticTriggersEnabled) {
      throw ArgumentError.value(
        runtime,
        'runtime',
        'Platform composition requires a dormant shadow runtime',
      );
    }
  }

  final CloudSyncPlatformContext context;
  final CloudSyncPlatformTriggerPolicy triggerPolicy;
  final bool manualSamplerEnabled;
  final bool automaticTriggerRolloutEnabled;
  final CloudSyncShadowRuntime _runtime;
  Future<void>? _disposeFuture;

  bool get isDisposed => _disposeFuture != null || _runtime.isDisposed;

  Future<List<CloudSyncRunResult>> synchronizeNow() {
    if (isDisposed) {
      throw StateError('Cloud Sync platform adapter is disposed');
    }
    if (!manualSamplerEnabled) {
      throw StateError('Cloud Sync V2 manual sampler is disabled');
    }
    return _runtime.synchronizeNow();
  }

  void onAndroidApnsWake() {
    if (_automaticAllowed(triggerPolicy.androidApnsWake)) {
      _runtime.onIdsReconnect();
    }
  }

  void onAndroidWorkManagerWake() {
    if (_automaticAllowed(triggerPolicy.androidWorkManagerWake)) {
      _runtime.onNetworkReconnect();
    }
  }

  void onWindowsStartup() {
    if (_automaticAllowed(triggerPolicy.windowsStartup)) {
      _runtime.onStartup();
    }
  }

  void onWindowsResume() {
    if (_automaticAllowed(triggerPolicy.windowsResume)) {
      _runtime.onNetworkReconnect();
    }
  }

  void onNetworkReconnect() {
    if (_automaticAllowed(triggerPolicy.networkReconnect)) {
      _runtime.onNetworkReconnect();
    }
  }

  Future<void> dispose() => _disposeFuture ??= _runtime.dispose();

  bool _automaticAllowed(bool sourceEnabled) =>
      !isDisposed && automaticTriggerRolloutEnabled && sourceEnabled;
}

typedef CloudSyncPlatformAdapterBuilder =
    Future<CloudSyncPlatformAdapter> Function(CloudSyncPlatformContext context);

/// Owns at most one account composition and quiesces it before replacement.
///
/// This is the lifecycle boundary for logout/account switch. It prevents old
/// credentials from remaining active while a new account opens its namespace.
class CloudSyncPlatformHost {
  CloudSyncPlatformAdapter? _active;
  int _activationGeneration = 0;

  CloudSyncPlatformAdapter? get active => _active;

  Future<CloudSyncPlatformAdapter> activate({
    required CloudSyncPlatformContext context,
    required CloudSyncPlatformAdapterBuilder build,
  }) async {
    final generation = ++_activationGeneration;
    final previous = _active;
    _active = null;
    if (previous != null) await previous.dispose();

    final created = await build(context);
    if (generation != _activationGeneration) {
      await created.dispose();
      throw StateError('Cloud Sync platform activation was superseded');
    }
    if (created.context.accountFingerprint != context.accountFingerprint ||
        created.context.privateStorageDirectory !=
            context.privateStorageDirectory ||
        created.context.platform != context.platform ||
        created.context.architecture != context.architecture) {
      await created.dispose();
      throw StateError('Cloud Sync platform composition context mismatch');
    }
    _active = created;
    return created;
  }

  Future<void> dispose() async {
    _activationGeneration++;
    final current = _active;
    _active = null;
    await current?.dispose();
  }
}
