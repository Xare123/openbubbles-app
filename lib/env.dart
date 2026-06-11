import 'dart:isolate';

bool isIsolateOverride = false;
bool get isIsolate => isIsolateOverride || (Isolate.current.debugName != null && Isolate.current.debugName != 'main');
