import 'package:bluebubbles/backend_harness/backend_harness_account.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('actual read-auth success result is serializable and grants no archive scope', () {
    final result = BackendHarnessAccount.readAuthenticationReady().toJson();
    expect(result['phase'], 'idle');
    expect(result['flags'], {
      'read_auth_ready': true,
      'existing_native_client_retained': true,
    });
    expect(result['counts'], isEmpty);
    expect((result['flags'] as Map).containsKey('archive_enabled'), isFalse);
    expect((result['flags'] as Map).containsKey('readback_verified'), isFalse);
  });
}
