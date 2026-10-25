import 'dart:convert';

import 'package:bluebubbles/services/rustpush/ids_registration_refresh.dart';
import 'package:flutter_test/flutter_test.dart';

const services = [
  'com.apple.madrid',
  'com.apple.private.alloy.multiplex1',
  'com.apple.private.alloy.facetime.multi',
  'com.apple.ess',
];

final class Data {
  const Data(this.text);
  final String text;
}

Map<String, Object?> user({
  String name = 'owned-id',
  String type = 'Apple',
  bool registered = true,
  int at = 100,
  int protocol = 1660,
  String auth = 'historical-auth',
  String alias = 'ids:owned-id',
}) => {
  'user_id': name,
  'user_type': type,
  'protocol_version': protocol,
  'auth_keypair': {'cert': Data(auth), 'private': alias},
  'registration': <String, Object?>{
    if (registered)
      for (final service in services)
        service: <String, Object?>{
          'registered_at_s': at,
          'id_keypair': {
            'cert': Data('registration-$service-$at'),
            'private': alias,
          },
          'data_hash': BigInt.parse('18446744073709551615'),
          'heartbeat_interval_s': 3600,
          'handles': <Object?>[
            'mailto:synthetic@example.invalid',
            'mailto:retained@example.invalid',
          ],
        },
  },
};

String plist(Object? value, {bool reordered = false, bool wrapData = false}) {
  String node(Object? value) {
    if (value is Data) {
      final encoded = base64Encode(utf8.encode(value.text));
      return '<data>${wrapData ? '\n  $encoded\n' : encoded}</data>';
    }
    if (value is String) {
      return '<string>${htmlEscape.convert(value)}</string>';
    }
    if (value is int || value is BigInt) {
      return '<integer>$value</integer>';
    }
    if (value is List) {
      return '<array>${value.map(node).join()}</array>';
    }
    if (value is Map) {
      final keys = value.keys.cast<String>().toList();
      return '<dict>${(reordered ? keys.reversed : keys).map((key) => '<key>${htmlEscape.convert(key)}</key>${node(value[key])}').join()}</dict>';
    }
    throw ArgumentError('unsupported synthetic plist value');
  }

  return '<plist version="1.0">${node(value)}</plist>';
}

IdsRegistrationSnapshot snapshot(Map<String, Object?> value) =>
    IdsRegistrationSnapshot.parse(plist(value));

Map<String, Object?> registration(Map<String, Object?> value, String service) =>
    (value['registration'] as Map)[service] as Map<String, Object?>;

void refused(void Function() action) => expect(
  action,
  throwsA(
    isA<StateError>().having(
      (error) => error.toString(),
      'content-free refusal',
      'Bad state: ids_registration_snapshot_refused',
    ),
  ),
);

void main() {
  test(
    'strict single Apple retains all native services and both mailto handles',
    () {
      final before = snapshot(user());
      final fresh = snapshot(user(registered: false, auth: 'fresh-auth'));
      before.requireRepairable();
      before.requireFreshUser(fresh);
      before.requireRegisteredReplacement(
        snapshot(user(at: 200, auth: 'fresh-auth')),
        199,
        fresh: fresh,
      );
    },
  );

  test('fresh empty registration cannot serve as retained preflight', () {
    refused(() => snapshot(user(registered: false)).requireRepairable());
  });

  test(
    'phone and array profile shapes refuse rather than dropping any user',
    () {
      for (final source in [
        plist(user(type: 'Phone')),
        plist([user()]),
        plist([user(), user(name: 'second-id')]),
        plist([user(), user(type: 'Phone')]),
      ]) {
        refused(() => IdsRegistrationSnapshot.parse(source));
      }
    },
  );

  for (final service in services) {
    test('preflight requires $service', () {
      final value = user();
      (value['registration'] as Map).remove(service);
      refused(() => snapshot(value).requireRepairable());
    });

    test(
      'replacement requires fresh timestamps and retained handles in $service',
      () {
        final before = snapshot(user());
        final fresh = snapshot(user(registered: false, auth: 'fresh-auth'));
        for (final at in [100, 198]) {
          final value = user(at: 200, auth: 'fresh-auth');
          registration(value, service)['registered_at_s'] = at;
          refused(
            () => before.requireRegisteredReplacement(
              snapshot(value),
              199,
              fresh: fresh,
            ),
          );
        }
        final lost = user(at: 200, auth: 'fresh-auth');
        (registration(lost, service)['handles'] as List).removeLast();
        refused(
          () => before.requireRegisteredReplacement(
            snapshot(lost),
            199,
            fresh: fresh,
          ),
        );
      },
    );

    test(
      'preflight refuses empty, duplicate and phone handles in $service',
      () {
        for (final handles in [
          <String>[],
          ['mailto:'],
          ['mailto:no-domain'],
          ['tel:+10000000000'],
          ['mailto:synthetic@example.invalid', 'tel:+10000000000'],
          [
            'mailto:synthetic@example.invalid',
            'mailto:synthetic@example.invalid',
          ],
        ]) {
          final value = user();
          registration(value, service)['handles'] = handles;
          refused(() => snapshot(value).requireRepairable());
        }
      },
    );
  }

  test('unexpected native service and unknown schema fields refuse', () {
    final extraService = user();
    (extraService['registration'] as Map)['unexpected-service'] = registration(
      extraService,
      services.first,
    );
    final extraField = user()
      ..['unexpected-private-field'] = 'private-synthetic';
    final missingField = user()..remove('registration');
    final missingHash = user();
    registration(missingHash, services.first).remove('data_hash');
    for (final value in [extraService, extraField, missingField, missingHash]) {
      refused(() => snapshot(value));
    }
  });

  test(
    'fresh user must have exact Apple identity and protocol with no registrations',
    () {
      final before = snapshot(user());
      for (final value in [
        user(registered: false, name: 'other-id'),
        user(registered: false, protocol: 1661),
        user(registered: false, type: 'Phone'),
        user(),
      ]) {
        refused(() => before.requireFreshUser(snapshot(value)));
      }
    },
  );

  test(
    'replacement authentication must match fresh user rather than historical user',
    () {
      final before = snapshot(user());
      final fresh = snapshot(user(registered: false, auth: 'fresh-auth'));
      for (final value in [
        user(at: 200),
        user(at: 200, auth: 'fresh-auth', alias: 'other-key'),
        user(at: 200, auth: 'different-auth'),
        user(at: 200, auth: 'fresh-auth', name: 'other-id'),
        user(at: 200, auth: 'fresh-auth', protocol: 1661),
        user(registered: false, auth: 'fresh-auth'),
      ]) {
        refused(
          () => before.requireRegisteredReplacement(
            snapshot(value),
            199,
            fresh: fresh,
          ),
        );
      }
      before.requireRegisteredReplacement(
        snapshot(user(at: 199, auth: 'fresh-auth')),
        199,
        fresh: fresh,
      );
    },
  );

  test(
    'replacement may use a fresh alias while registration aliases stay bound to it',
    () {
      final before = snapshot(user());
      final fresh = snapshot(
        user(registered: false, auth: 'fresh-auth', alias: 'fresh-key'),
      );
      final after = user(at: 200, auth: 'fresh-auth', alias: 'fresh-key');
      before.requireRegisteredReplacement(snapshot(after), 199, fresh: fresh);
      (registration(after, services.last)['id_keypair'] as Map)['private'] =
          'wrong-key';
      refused(
        () => before.requireRegisteredReplacement(
          snapshot(after),
          199,
          fresh: fresh,
        ),
      );
    },
  );

  test(
    'registration timestamps must advance even if an old future timestamp exceeds start',
    () {
      final before = snapshot(user(at: 300));
      final fresh = snapshot(user(registered: false, auth: 'fresh-auth'));
      refused(
        () => before.requireRegisteredReplacement(
          snapshot(user(at: 300, auth: 'fresh-auth')),
          199,
          fresh: fresh,
        ),
      );
    },
  );

  test('invalid repair start times refuse', () {
    final before = snapshot(user());
    final fresh = snapshot(user(registered: false, auth: 'fresh-auth'));
    for (final start in [0, -1]) {
      refused(
        () => before.requireRegisteredReplacement(
          snapshot(user(at: 200, auth: 'fresh-auth')),
          start,
          fresh: fresh,
        ),
      );
    }
  });

  test(
    'native uint64 fields retain exact precision and reject invalid ranges',
    () {
      final valid = snapshot(user());
      expect(
        (valid.registrations[services.first] as Map)['data_hash'],
        BigInt.parse('18446744073709551615'),
      );
      for (final field in [
        'data_hash',
        'registered_at_s',
        'heartbeat_interval_s',
      ]) {
        for (final number in [BigInt.from(-1), BigInt.one << 64]) {
          final value = user();
          registration(value, services.first)[field] = number;
          refused(() => snapshot(value));
        }
      }
      for (final number in [BigInt.from(-1), BigInt.zero, BigInt.one << 32]) {
        final value = user()..['protocol_version'] = number;
        refused(() => snapshot(value));
      }
    },
  );

  test(
    'absent optional heartbeat is accepted and remains distinct in readback',
    () {
      final value = user();
      registration(value, services.first).remove('heartbeat_interval_s');
      final parsed = snapshot(value);
      parsed.requireRepairable();
      expect(parsed.sameSavedValue(snapshot(user())), false);
    },
  );

  test(
    'full persisted comparison normalizes dictionaries and certificate data whitespace',
    () {
      final value = user(at: 200, auth: 'fresh-auth');
      final returned = snapshot(value);
      final persisted = IdsRegistrationSnapshot.parse(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '${plist(value, reordered: true, wrapData: true)}',
      );
      expect(returned.sameSavedValue(persisted), true);
    },
  );

  test(
    'persisted full comparison detects every returned credential and service change',
    () {
      final returned = snapshot(user(at: 200, auth: 'fresh-auth'));
      final changedAuth = user(at: 200, auth: 'changed-auth');
      final changedAlias = user(
        at: 200,
        auth: 'fresh-auth',
        alias: 'changed-key',
      );
      final changedCert = user(at: 200, auth: 'fresh-auth');
      (registration(changedCert, services.last)['id_keypair'] as Map)['cert'] =
          const Data('changed-service-certificate');
      final changedHash = user(at: 200, auth: 'fresh-auth');
      registration(changedHash, services.last)['data_hash'] = 1;
      final changedHeartbeat = user(at: 200, auth: 'fresh-auth');
      registration(changedHeartbeat, services.last)['heartbeat_interval_s'] = 1;
      final changedHandles = user(at: 200, auth: 'fresh-auth');
      final handles =
          registration(changedHandles, services.last)['handles'] as List;
      registration(changedHandles, services.last)['handles'] = handles.reversed
          .toList();
      for (final value in [
        changedAuth,
        changedAlias,
        changedCert,
        changedHash,
        changedHeartbeat,
        changedHandles,
        user(at: 201, auth: 'fresh-auth'),
      ]) {
        expect(returned.sameSavedValue(snapshot(value)), false);
      }
    },
  );

  test(
    'malformed XML, typed values and credential payloads always give a fixed refusal',
    () {
      final valid = plist(user());
      for (final source in [
        '<private-synthetic>',
        valid.replaceFirst('<plist version="1.0">', '<plist>'),
        valid.replaceFirst('<dict>', '<dict>private-synthetic'),
        valid.replaceFirst('<dict>', '<dict><!-- private-synthetic -->'),
        valid.replaceFirst(
          '<key>user_id</key>',
          '<key><string>user_id</string></key>',
        ),
        valid.replaceFirst(
          '<string>owned-id</string>',
          '<string><integer>1</integer></string>',
        ),
        valid.replaceFirst(
          '<key>user_id</key>',
          '<key>user_id</key><string>private-synthetic</string><key>user_id</key>',
        ),
        valid.replaceFirst(
          '<integer>1660</integer>',
          '<integer>private-synthetic</integer>',
        ),
        valid.replaceFirst(
          '<integer>1660</integer>',
          '<integer>+1660</integer>',
        ),
        valid.replaceFirst(
          '<integer>1660</integer>',
          '<integer><string>1660</string></integer>',
        ),
        valid.replaceFirst('<data>', '<data>!private-synthetic!'),
        valid.replaceFirst(
          '<data>aGlzdG9yaWNhbC1hdXRo</data>',
          '<string>aGlzdG9yaWNhbC1hdXRo</string>',
        ),
        valid.replaceFirst('<data>aGlzdG9yaWNhbC1hdXRo</data>', '<data/>'),
        valid.replaceFirst(
          '<key>private</key><string>ids:owned-id</string>',
          '<key>private</key><data>a2V5</data>',
        ),
        valid.replaceFirst(
          '<key>user_id</key><string>owned-id</string>',
          '<key>user_id</key><string/>',
        ),
        valid.replaceFirst(
          '<key>user_id</key>',
          '<key unexpected="private-synthetic">user_id</key>',
        ),
        valid.replaceFirst('<dict>', '<dict xmlns="unexpected-namespace">'),
        valid.replaceFirst('<integer>3600</integer>', '<real>3600</real>'),
        valid.replaceFirst(
          '<integer>3600</integer>',
          '<true>private-synthetic</true>',
        ),
      ]) {
        refused(() => IdsRegistrationSnapshot.parse(source));
      }
    },
  );

  test(
    'oversized and deeply nested snapshots refuse without parser diagnostics',
    () {
      refused(() => IdsRegistrationSnapshot.parse('x' * (1024 * 1024 + 1)));
      final arrays = List.filled(18, '<array>').join();
      final ends = List.filled(18, '</array>').join();
      refused(
        () => IdsRegistrationSnapshot.parse(
          '<plist version="1.0">$arrays<string>private-synthetic</string>$ends</plist>',
        ),
      );
    },
  );

  test(
    'parsed credentials and nested registration evidence cannot be mutated',
    () {
      final parsed = snapshot(user());
      expect(
        () => parsed.value['user_id'] = 'other-id',
        throwsUnsupportedError,
      );
      expect(() => parsed.registrations.clear(), throwsUnsupportedError);
      final service = parsed.registrations[services.first] as Map;
      expect(
        () => service['registered_at_s'] = BigInt.zero,
        throwsUnsupportedError,
      );
      expect(
        () => (service['handles'] as List).clear(),
        throwsUnsupportedError,
      );
    },
  );
}
