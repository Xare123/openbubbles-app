import 'dart:async';

import 'cloud_sync_manual_shadow_sampler.dart';

typedef CloudSyncBooleanProbe = FutureOr<bool> Function();
typedef CloudSyncLocalPreflightProbe =
    FutureOr<CloudSyncLocalPreflightState> Function();

final class CloudSyncLocalPreflightState {
  const CloudSyncLocalPreflightState({
    required this.objectBoxReady,
    required this.coordinatorLeaseActive,
    required this.outboxCount,
    this.settledOutboxFingerprint,
  });

  const CloudSyncLocalPreflightState.blocked()
    : objectBoxReady = false,
      coordinatorLeaseActive = true,
      outboxCount = -1,
      settledOutboxFingerprint = null;

  final bool objectBoxReady;
  final bool coordinatorLeaseActive;
  final int outboxCount;
  final String? settledOutboxFingerprint;
}

/// Fail-closed production probe for the developer-only shadow sampler.
///
/// Platform composition supplies narrow readers instead of exposing mutable
/// service or ObjectBox objects to the sampler. A failed read is represented by
/// the safest blocking value and never includes the underlying exception in a
/// diagnostic surface.
final class CloudSyncProductionPreflightProbe {
  factory CloudSyncProductionPreflightProbe({
    required CloudSyncBooleanProbe platformSupported,
    required CloudSyncBooleanProbe uiIsolate,
    required CloudSyncBooleanProbe rustPushReady,
    required CloudSyncLocalPreflightProbe localState,
    required CloudSyncBooleanProbe privateStorageExists,
    required CloudSyncBooleanProbe logoutActive,
    required CloudSyncBooleanProbe legacySyncEnabled,
    required CloudSyncBooleanProbe legacySyncActive,
    required CloudSyncBooleanProbe protectorSentinelValid,
  }) => CloudSyncProductionPreflightProbe._(
    platformSupported,
    uiIsolate,
    rustPushReady,
    localState,
    privateStorageExists,
    logoutActive,
    legacySyncEnabled,
    legacySyncActive,
    protectorSentinelValid,
  );

  const CloudSyncProductionPreflightProbe._(
    this._platformSupported,
    this._uiIsolate,
    this._rustPushReady,
    this._localState,
    this._privateStorageExists,
    this._logoutActive,
    this._legacySyncEnabled,
    this._legacySyncActive,
    this._protectorSentinelValid,
  );

  final CloudSyncBooleanProbe _platformSupported;
  final CloudSyncBooleanProbe _uiIsolate;
  final CloudSyncBooleanProbe _rustPushReady;
  final CloudSyncLocalPreflightProbe _localState;
  final CloudSyncBooleanProbe _privateStorageExists;
  final CloudSyncBooleanProbe _logoutActive;
  final CloudSyncBooleanProbe _legacySyncEnabled;
  final CloudSyncBooleanProbe _legacySyncActive;
  final CloudSyncBooleanProbe _protectorSentinelValid;

  Future<CloudSyncShadowPreflightState> read() async {
    final localState = await _readLocalState();
    return CloudSyncShadowPreflightState(
      platformSupported: await _readBoolean(
        _platformSupported,
        failureValue: false,
      ),
      uiIsolate: await _readBoolean(_uiIsolate, failureValue: false),
      rustPushReady: await _readBoolean(_rustPushReady, failureValue: false),
      objectBoxReady: localState.objectBoxReady,
      privateStorageExists: await _readBoolean(
        _privateStorageExists,
        failureValue: false,
      ),
      // Uncertainty about teardown, legacy work, or another coordinator must
      // block the shadow sampler.
      logoutActive: await _readBoolean(_logoutActive, failureValue: true),
      legacySyncEnabled: await _readBoolean(
        _legacySyncEnabled,
        failureValue: true,
      ),
      legacySyncActive: await _readBoolean(
        _legacySyncActive,
        failureValue: true,
      ),
      coordinatorLeaseActive: localState.coordinatorLeaseActive,
      outboxCount: localState.outboxCount,
      settledOutboxFingerprint: localState.settledOutboxFingerprint,
      protectorSentinelValid: await _readBoolean(
        _protectorSentinelValid,
        failureValue: false,
      ),
    );
  }

  Future<bool> _readBoolean(
    CloudSyncBooleanProbe probe, {
    required bool failureValue,
  }) async {
    try {
      return await probe();
    } catch (_) {
      return failureValue;
    }
  }

  Future<CloudSyncLocalPreflightState> _readLocalState() async {
    try {
      final state = await _localState();
      if (state.outboxCount < 0) {
        return const CloudSyncLocalPreflightState.blocked();
      }
      return state;
    } catch (_) {
      return const CloudSyncLocalPreflightState.blocked();
    }
  }
}
