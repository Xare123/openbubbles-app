import 'dart:convert';

import 'package:xml/xml.dart';

/// Inspection of the native serializer only. Raw credentials stay in memory;
/// failures and command receipts never contain these values.
final class IdsRegistrationSnapshot {
  IdsRegistrationSnapshot._(this.value);
  final Map<String, Object?> value;

  static const requiredServices = {
    'com.apple.madrid',
    'com.apple.private.alloy.multiplex1',
    'com.apple.private.alloy.facetime.multi',
    'com.apple.ess',
  };
  static final _uint64Max = (BigInt.one << 64) - BigInt.one;
  static final _uint32Max = (BigInt.one << 32) - BigInt.one;

  factory IdsRegistrationSnapshot.parse(String source) {
    try {
      return IdsRegistrationSnapshot._parse(source);
    } catch (_) {
      return _refuse();
    }
  }

  /// Native serialization can suspend. Its result must not authorize a later
  /// credential write after the account or active maintenance fence is lost.
  static Future<IdsRegistrationSnapshot> capture({
    required Future<String> Function() serialize,
    required void Function() validate,
  }) async {
    validate();
    final source = await serialize();
    validate();
    return IdsRegistrationSnapshot.parse(source);
  }

  static IdsRegistrationSnapshot _parse(String source) {
    if (source.length > 1024 * 1024) {
      _refuse();
    }
    final document = XmlDocument.parse(source);
    final root = document.rootElement;
    if (document.childElements.length != 1 ||
        root.name.qualified != 'plist' ||
        root.childElements.length != 1 ||
        root.attributes.length != 1 ||
        root.attributes.single.name.qualified != 'version' ||
        root.attributes.single.value != '1.0') {
      _refuse();
    }
    _requireContainerText(root);
    final value = _dictionary(_decode(root.childElements.single, 0));
    _requireKeys(value, const {
      'user_id',
      'user_type',
      'protocol_version',
      'auth_keypair',
      'registration',
    });
    _string(value['user_id']);
    if (value['user_type'] != 'Apple' ||
        _unsigned(value['protocol_version'], _uint32Max) == BigInt.zero) {
      _refuse();
    }
    _keypair(value['auth_keypair']);
    final snapshot = IdsRegistrationSnapshot._(value);
    // Empty registration is valid only as the fresh authentication result.
    if (snapshot.registrations.isNotEmpty) {
      snapshot.requireRepairable();
    }
    return snapshot;
  }

  String get userId => value['user_id'] as String;
  BigInt get protocolVersion => value['protocol_version'] as BigInt;
  Map<String, Object?> get registrations => _dictionary(value['registration']);

  /// The caller separately requires exactly one native saved IDS user before
  /// serializing it. No missing service or phone/extra-user shape is repaired.
  void requireRepairable() {
    final services = registrations;
    _requireKeys(services, requiredServices);
    final auth = _keypair(value['auth_keypair']);
    for (final service in requiredServices) {
      final registration = _dictionary(services[service]);
      _requireKeys(
        registration,
        const {'id_keypair', 'handles', 'registered_at_s', 'data_hash'},
        const {'heartbeat_interval_s'},
      );
      final pair = _keypair(registration['id_keypair']);
      if (pair['private'] != auth['private']) {
        _refuse();
      }
      _unsigned(registration['registered_at_s'], _uint64Max);
      _unsigned(registration['data_hash'], _uint64Max);
      if (registration.containsKey('heartbeat_interval_s')) {
        _unsigned(registration['heartbeat_interval_s'], _uint64Max);
      }
      final handles = registration['handles'];
      if (handles is! List || handles.isEmpty || handles.length > 256) {
        _refuse();
      }
      final unique = <String>{};
      for (final handle in handles) {
        final text = _string(handle);
        if (!RegExp(r'^mailto:[^@\s<>?#]+@[^@\s<>?#]+$').hasMatch(text) ||
            !unique.add(text)) {
          _refuse();
        }
      }
    }
  }

  /// A fresh authenticated Apple user must replace this exact sole user.
  /// The Windows recipe deliberately refuses multi-user/phone-user profiles.
  void requireSameUser(IdsRegistrationSnapshot other) {
    if (userId != other.userId || protocolVersion != other.protocolVersion) {
      _refuse();
    }
  }

  void requireFreshUser(IdsRegistrationSnapshot other) {
    requireRepairable();
    requireSameUser(other);
    if (other.registrations.isNotEmpty) {
      _refuse();
    }
  }

  void requireRegisteredReplacement(
    IdsRegistrationSnapshot other,
    int beganAtS, {
    required IdsRegistrationSnapshot fresh,
  }) {
    requireFreshUser(fresh);
    requireSameUser(other);
    other.requireRepairable();
    final began = BigInt.from(beganAtS);
    if (began <= BigInt.zero ||
        began > _uint64Max ||
        !_same(
          value: other.value['auth_keypair'],
          other: fresh.value['auth_keypair'],
        )) {
      _refuse();
    }
    for (final entry in registrations.entries) {
      final before = _dictionary(entry.value);
      final after = _dictionary(other.registrations[entry.key]);
      final at = after['registered_at_s'] as BigInt;
      if (at < began ||
          at <= (before['registered_at_s'] as BigInt) ||
          !(before['handles'] as List).every(
            (after['handles'] as List).contains,
          )) {
        _refuse();
      }
    }
  }

  bool sameSavedValue(IdsRegistrationSnapshot other) =>
      _same(value: value, other: other.value);

  static bool _same({required Object? value, required Object? other}) =>
      jsonEncode(_canonical(value)) == jsonEncode(_canonical(other));

  static Map<String, Object?> _dictionary(Object? value) =>
      value is Map<String, Object?> ? value : _refuse();

  static void _requireKeys(
    Map<String, Object?> value,
    Set<String> required, [
    Set<String> optional = const {},
  ]) {
    if (!required.every(value.containsKey) ||
        value.keys.any(
          (key) => !required.contains(key) && !optional.contains(key),
        )) {
      _refuse();
    }
  }

  static String _string(Object? value) {
    if (value is! String ||
        value.isEmpty ||
        value.length > 4096 ||
        value.trim() != value ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
      _refuse();
    }
    return value;
  }

  static BigInt _unsigned(Object? value, BigInt max) =>
      value is BigInt && value >= BigInt.zero && value <= max
      ? value
      : _refuse();

  static Map<String, Object?> _keypair(Object? value) {
    final pair = _dictionary(value);
    _requireKeys(pair, const {'cert', 'private'});
    if (pair['cert'] is! _PlistData ||
        (pair['cert'] as _PlistData).base64.isEmpty) {
      _refuse();
    }
    _string(pair['private']);
    return pair;
  }

  static void _requireContainerText(XmlElement element) {
    for (final node in element.children) {
      if (node is! XmlElement &&
          (node is! XmlText || node.value.trim().isNotEmpty)) {
        _refuse();
      }
    }
  }

  static String _text(XmlElement element) {
    if (element.children.any((node) => node is! XmlText)) {
      _refuse();
    }
    return element.innerText;
  }

  static Object? _decode(XmlElement element, int depth) {
    if (depth > 16 ||
        element.attributes.isNotEmpty ||
        element.name.prefix != null) {
      _refuse();
    }
    final children = element.childElements.toList();
    switch (element.name.local) {
      case 'dict':
        _requireContainerText(element);
        if (children.length.isOdd) {
          _refuse();
        }
        final result = <String, Object?>{};
        for (var i = 0; i < children.length; i += 2) {
          final key = children[i];
          if (key.name.qualified != 'key' || key.attributes.isNotEmpty) {
            _refuse();
          }
          final name = _text(key);
          if (name.isEmpty || result.containsKey(name)) {
            _refuse();
          }
          result[name] = _decode(children[i + 1], depth + 1);
        }
        return Map<String, Object?>.unmodifiable(result);
      case 'array':
        _requireContainerText(element);
        return List<Object?>.unmodifiable([
          for (final child in children) _decode(child, depth + 1),
        ]);
      case 'string':
        return _text(element);
      case 'data':
        // Canonical bytes, retaining the plist type separately from strings.
        final encoded = _text(element).replaceAll(RegExp(r'\s'), '');
        if (!RegExp(
          r'^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$',
        ).hasMatch(encoded)) {
          _refuse();
        }
        return _PlistData(base64Encode(base64Decode(encoded)));
      case 'integer':
        final text = _text(element);
        if (!RegExp(r'^-?(?:0|[1-9][0-9]*)$').hasMatch(text)) {
          _refuse();
        }
        return BigInt.parse(text);
      case 'true':
        if (_text(element).isNotEmpty) {
          _refuse();
        }
        return true;
      case 'false':
        if (_text(element).isNotEmpty) {
          _refuse();
        }
        return false;
      default:
        return _refuse();
    }
  }

  static Object? _canonical(Object? value) {
    if (value is BigInt) {
      return ['integer', value.toString()];
    }
    if (value is _PlistData) {
      return ['data', value.base64];
    }
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return [
        'dict',
        for (final key in keys) [key, _canonical(value[key])],
      ];
    }
    if (value is List) {
      return ['array', ...value.map(_canonical)];
    }
    if (value is String) {
      return ['string', value];
    }
    if (value is bool) {
      return ['boolean', value];
    }
    return _refuse();
  }

  static Never _refuse() =>
      throw StateError('ids_registration_snapshot_refused');
}

final class _PlistData {
  const _PlistData(this.base64);
  final String base64;
}
