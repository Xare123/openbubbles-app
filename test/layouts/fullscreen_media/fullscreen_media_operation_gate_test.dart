import 'dart:async';

import 'package:bluebubbles/app/layouts/fullscreen_media/fullscreen_media_operation_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an older image load cannot overwrite a newer generation', () async {
    final gate = FullscreenMediaOperationGate();
    final older = Completer<String>();
    final newer = Completer<String>();
    String? visibleValue;

    Future<void> applyWhenCurrent(Future<String> result, int generation) async {
      final value = await result;
      if (gate.isCurrent(generation)) {
        visibleValue = value;
      }
    }

    final olderResult = applyWhenCurrent(older.future, gate.begin());
    final newerResult = applyWhenCurrent(newer.future, gate.begin());

    newer.complete('newer');
    await newerResult;
    older.complete('older');
    await olderResult;

    expect(visibleValue, 'newer');
  });

  test('navigation prevents an off-page download from rebuilding visible state', () async {
    final gate = FullscreenMediaOperationGate();
    final completion = Completer<void>();
    var visiblePage = 'first';
    var rebuilds = 0;
    final generation = gate.begin();

    final pending = completion.future.then((_) {
      if (gate.isCurrent(generation) && visiblePage == 'first') {
        rebuilds++;
      }
    });

    visiblePage = 'second';
    completion.complete();
    await pending;

    expect(rebuilds, 0);
  });

  test('dispose rejects late completions and future generations', () {
    final gate = FullscreenMediaOperationGate();
    final activeGeneration = gate.begin();

    gate.dispose();

    expect(gate.isCurrent(activeGeneration), isFalse);
    expect(gate.isCurrent(gate.begin()), isFalse);
  });
}
