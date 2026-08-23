import 'dart:math';

import 'cloud_sync_models.dart';

typedef CloudRandomUnit = double Function();

class CloudSyncBackoffPolicy {
  CloudSyncBackoffPolicy({
    this.baseDelay = const Duration(seconds: 2),
    this.maximumDelay = const Duration(minutes: 15),
    CloudRandomUnit? randomUnit,
  }) : _randomUnit = randomUnit ?? Random.secure().nextDouble {
    if (baseDelay.isNegative || baseDelay == Duration.zero) {
      throw ArgumentError.value(baseDelay, 'baseDelay');
    }
    if (maximumDelay < baseDelay) {
      throw ArgumentError.value(maximumDelay, 'maximumDelay');
    }
  }

  final Duration baseDelay;
  final Duration maximumDelay;
  final CloudRandomUnit _randomUnit;

  Duration delayFor({
    required int attempt,
    required CloudFailureCategory category,
    Duration? retryAfter,
  }) {
    if (attempt <= 0) {
      throw ArgumentError.value(attempt, 'attempt');
    }

    final exponent = min(attempt - 1, 30);
    final exponentialMs = min(
      baseDelay.inMilliseconds * (1 << exponent),
      maximumDelay.inMilliseconds,
    );
    final unit = _randomUnit().clamp(0.0, 1.0);
    final jitterMs = (exponentialMs * unit).round();
    var delay = Duration(milliseconds: jitterMs);

    if (category == CloudFailureCategory.pcsUnavailable &&
        delay < const Duration(seconds: 30)) {
      delay = const Duration(seconds: 30);
    }
    if (retryAfter != null && retryAfter > delay) {
      delay = retryAfter;
    }
    return delay > maximumDelay && retryAfter == null ? maximumDelay : delay;
  }

  DateTime nextEligibleAt({
    required DateTime now,
    required int attempt,
    required CloudFailureCategory category,
    Duration? retryAfter,
  }) {
    return now.add(
      delayFor(attempt: attempt, category: category, retryAfter: retryAfter),
    );
  }
}
