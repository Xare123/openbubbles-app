import 'dart:convert';
import 'dart:typed_data';

import 'package:bluebubbles/helpers/types/constants.dart' show PayloadType;
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_sync_prepared_extension.dart';
import 'package:flutter_test/flutter_test.dart';

const _bundle = 'com.example.synthetic';
const _uuid = '01010101-0101-0101-0101-010101010101';

Map<String, dynamic> _fixture() => {
  'version': 1,
  'metadata': <String, dynamic>{
    'name': 'Synthetic App',
    'app_id': 1234,
    'bundle_id': _bundle,
    'balloon': <String, dynamic>{
      'url': 'app:synthetic',
      'session': _uuid,
      'ld_text': 'Synthetic description',
      'is_live': true,
      'icon': [0, 1, 127, 128, 255],
      'layout': <String, dynamic>{
        'image_subtitle': 'is',
        'image_title': 'it',
        'caption': 'c',
        'secondary_subcaption': 'ss',
        'tertiary_subcaption': 'ts',
        'subcaption': 's',
      },
    },
  },
};

CloudSyncPreparedExtension _parse(
  Map<String, dynamic> value, {
  String bundle = _bundle,
}) => CloudSyncPreparedExtension.parse(
  jsonEncode(value),
  expectedParentBundleId: bundle,
);

Map<String, dynamic> _at(Map<String, dynamic> root, List<String> path) {
  var value = root;
  for (final key in path) {
    value = value[key] as Map<String, dynamic>;
  }
  return value;
}

final _failure = throwsA(
  isA<CloudSyncPreparedExtensionFailure>().having(
    (e) => e.toString(),
    'fixed failure',
    'CloudSyncPreparedExtensionFailure: invalid metadata',
  ),
);

void main() {
  // Intentionally no Get.put, service registration, native initialization,
  // app-status mocks, database, HTTP client or widget binding setup.
  test('copies every legacy renderer field without service initialization', () {
    final prepared = _parse(_fixture());
    final data = prepared.toPayloadData();
    expect(prepared.metadata.bundleId, _bundle);
    expect(data.type, PayloadType.app);
    expect(data.urlData, isNull);
    expect(data.appData, hasLength(1));
    expect(data.toJson(), {
      'type': PayloadType.app.index,
      'urlData': null,
      'appData': [
        {
          'an': 'Synthetic App',
          'ldtext': 'Synthetic description',
          'URL': {'NS.relative': 'app:synthetic'},
          'session': _uuid,
          'appIcon': base64Encode([0, 1, 127, 128, 255]),
          'appId': 1234,
          'isLive': true,
          'userInfo': {
            'image-subtitle': 'is',
            'image-title': 'it',
            'caption': 'c',
            'secondary-subcaption': 'ss',
            'tertiary-subcaption': 'ts',
            'subcaption': 's',
          },
        },
      ],
    });
  });

  test('preserves null optionals and false rather than inventing defaults', () {
    final value = _fixture();
    value['metadata']['app_id'] = null;
    final balloon = value['metadata']['balloon'];
    for (final key in ['session', 'ld_text', 'icon', 'layout']) {
      balloon[key] = null;
    }
    balloon['is_live'] = false;
    final prepared = _parse(value);
    final app = prepared.toPayloadData().appData!.single;
    expect(prepared.metadata.appId, isNull);
    expect(prepared.metadata.balloon.session, isNull);
    expect(prepared.metadata.balloon.ldText, isNull);
    expect(prepared.metadata.balloon.icon, isNull);
    expect(prepared.metadata.balloon.layout, isNull);
    expect(app.appId, isNull);
    expect(app.session, isNull);
    expect(app.ldText, isNull);
    expect(app.appIcon, isNull);
    expect(app.userInfo, isNull);
    expect(app.isLive, isFalse);
  });

  test('valid empty text and icon stay empty, not null', () {
    final value = _fixture();
    value['metadata']['name'] = '';
    value['metadata']['balloon']['url'] = '';
    value['metadata']['balloon']['ld_text'] = '';
    value['metadata']['balloon']['icon'] = <int>[];
    value['metadata']['balloon']['layout']['caption'] = '';
    final app = _parse(value).toPayloadData().appData!.single;
    expect(app.appName, '');
    expect(app.url, '');
    expect(app.ldText, '');
    expect(app.appIcon, '');
    expect(app.userInfo!.caption, '');
  });

  test('transport bytes preserve whitespace, escapes, Unicode and key order', () {
    final source =
        ' \n${jsonEncode(_fixture()).replaceFirst('Synthetic App', r'Synthetic \u0041pp'
            ' 🌊')}\t';
    final prepared = CloudSyncPreparedExtension.parse(
      source,
      expectedParentBundleId: _bundle,
    );
    expect(prepared.canonicalUtf8, utf8.encode(source));
    expect(prepared.metadata.name, 'Synthetic App 🌊');
    expect(utf8.decode(prepared.canonicalUtf8), source);
    expect(() => prepared.canonicalUtf8[0] = 0, throwsUnsupportedError);
    expect(
      () => prepared.canonicalUtf8.buffer.asUint8List()[0] = 0,
      throwsUnsupportedError,
    );
    final reordered =
        '{"metadata":${jsonEncode(_fixture()['metadata'])},"version":1}';
    final other = CloudSyncPreparedExtension.parse(
      reordered,
      expectedParentBundleId: _bundle,
    );
    expect(other.canonicalUtf8, utf8.encode(reordered));
  });

  test(
    'immutable icon and fresh legacy models isolate repeated conversions',
    () {
      final prepared = _parse(_fixture());
      final icon = prepared.metadata.balloon.icon!;
      expect(() => icon[0] = 255, throwsUnsupportedError);
      expect(
        () => Uint8List.view(icon.buffer)[0] = 255,
        throwsUnsupportedError,
      );
      final first = prepared.toPayloadData();
      first.appData!.single.appName = 'changed';
      first.appData!.single.userInfo!.caption = 'changed';
      first.appData!.clear();
      final second = prepared.toPayloadData().appData!.single;
      expect(second.appName, 'Synthetic App');
      expect(second.userInfo!.caption, 'c');
      expect(prepared.metadata.balloon.icon, [0, 1, 127, 128, 255]);
    },
  );

  for (final path in <List<String>>[
    [],
    ['metadata'],
    ['metadata', 'balloon'],
    ['metadata', 'balloon', 'layout'],
  ]) {
    test('exact required keys and object type at $path', () {
      final fields = _at(_fixture(), path).keys.toList();
      for (final key in fields) {
        final value = _fixture();
        _at(value, path).remove(key);
        expect(() => _parse(value), _failure, reason: 'missing $key');
      }
      final extra = _fixture();
      _at(extra, path)['future_field'] = null;
      expect(() => _parse(extra), _failure);
      if (path.isNotEmpty) {
        for (final wrong in [
          true,
          1,
          '',
          <Object?>[],
          if (path.last != 'layout') null,
        ]) {
          final value = _fixture();
          _at(value, path.sublist(0, path.length - 1))[path.last] = wrong;
          expect(() => _parse(value), _failure);
        }
      }
    });
  }

  test(
    'versions and app IDs require actual integers within signed64 range',
    () {
      for (final version in [null, false, '1', 1.0, 0, 2, -1]) {
        final value = _fixture()..['version'] = version;
        expect(() => _parse(value), _failure);
      }
      for (final appId in [false, '1', 1.0, -1, [], {}]) {
        final value = _fixture();
        value['metadata']['app_id'] = appId;
        expect(() => _parse(value), _failure);
      }
      for (final appId in [0, 9223372036854775807]) {
        final value = _fixture();
        value['metadata']['app_id'] = appId;
        expect(_parse(value).metadata.appId, appId);
      }
      for (final number in [
        '9223372036854775808',
        '18446744073709551615',
        '1e3',
      ]) {
        final source = jsonEncode(_fixture()).replaceFirst('1234', number);
        expect(
          () => CloudSyncPreparedExtension.parse(
            source,
            expectedParentBundleId: _bundle,
          ),
          _failure,
        );
      }
    },
  );

  test('bundle binding is exact, bounded UTF-8 and free of controls', () {
    expect(() => _parse(_fixture(), bundle: _bundle.toUpperCase()), _failure);
    for (final bundle in [
      '',
      'bad\nidentifier',
      'bad\u007f',
      'bad\u0085',
      'b' * 1025,
      'é' * 513,
    ]) {
      final value = _fixture();
      value['metadata']['bundle_id'] = bundle;
      expect(() => _parse(value, bundle: bundle), _failure);
    }
    for (final bundle in ['b' * 1024, 'é' * 512]) {
      final value = _fixture();
      value['metadata']['bundle_id'] = bundle;
      expect(_parse(value, bundle: bundle).metadata.bundleId, bundle);
    }
    final value = _fixture();
    value['metadata']['bundle_id'] = ' $_bundle';
    expect(() => _parse(value), _failure);
  });

  test(
    'UUID shape matches native arbitrary 128-bit UUIDs without coercion',
    () {
      for (final session in [
        _uuid,
        '00000000-0000-0000-0000-000000000000',
        'FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF',
      ]) {
        final value = _fixture();
        value['metadata']['balloon']['session'] = session;
        expect(_parse(value).metadata.balloon.session, session);
      }
      for (final session in [
        '',
        1,
        false,
        _uuid.replaceAll('-', ''),
        '{$_uuid}',
        'urn:uuid:$_uuid',
        '$_uuid\n',
        ' $_uuid',
        'g1010101-0101-0101-0101-010101010101',
      ]) {
        final value = _fixture();
        value['metadata']['balloon']['session'] = session;
        expect(() => _parse(value), _failure);
      }
    },
  );

  final textPaths = <List<String>>[
    ['metadata', 'name'],
    ['metadata', 'balloon', 'url'],
    ['metadata', 'balloon', 'ld_text'],
    for (final field in _fixture()['metadata']['balloon']['layout'].keys)
      ['metadata', 'balloon', 'layout', field as String],
  ];
  for (final path in textPaths) {
    test('strict type and UTF-8 byte boundary for ${path.last}', () {
      void set(Map<String, dynamic> root, Object? text) =>
          _at(root, path.sublist(0, path.length - 1))[path.last] = text;
      for (final wrong in [
        1,
        false,
        [],
        {},
        if (path.last != 'ld_text') null,
      ]) {
        final value = _fixture();
        set(value, wrong);
        expect(() => _parse(value), _failure);
      }
      for (final text in ['a' * 16384, 'é' * 8192, '🌊' * 4096]) {
        final value = _fixture();
        set(value, text);
        expect(() => _parse(value), returnsNormally);
        set(value, '${text}a');
        expect(() => _parse(value), _failure);
      }
      for (final malformed in ['\ud800', '\udc00', '\ud800x']) {
        final value = _fixture();
        set(value, malformed);
        expect(() => _parse(value), _failure);
      }
    });
  }

  test('strict live marker and icon bytes including maximum size', () {
    for (final live in [null, 0, 1, 'false', [], {}]) {
      final value = _fixture();
      value['metadata']['balloon']['is_live'] = live;
      expect(() => _parse(value), _failure);
    }
    for (final icon in [
      '',
      false,
      1,
      {},
      [-1],
      [256],
      [1.0],
      ['1'],
      [null],
      [true],
      [[]],
    ]) {
      final value = _fixture();
      value['metadata']['balloon']['icon'] = icon;
      expect(() => _parse(value), _failure);
    }
    final value = _fixture();
    value['metadata']['balloon']['icon'] = List.filled(1024 * 1024, 255);
    expect(_parse(value).metadata.balloon.icon, hasLength(1024 * 1024));
    value['metadata']['balloon']['icon'] = List.filled(1024 * 1024 + 1, 0);
    expect(() => _parse(value), _failure);
  });

  test('8 MiB JSON boundary is measured in bytes before decoding', () {
    final source = jsonEncode(_fixture());
    final padding =
        CloudSyncPreparedExtension.maxJsonBytes - utf8.encode(source).length;
    final exact = source + ' ' * padding;
    expect(
      CloudSyncPreparedExtension.parse(
        exact,
        expectedParentBundleId: _bundle,
      ).canonicalUtf8.length,
      CloudSyncPreparedExtension.maxJsonBytes,
    );
    expect(
      () => CloudSyncPreparedExtension.parse(
        '$exact ',
        expectedParentBundleId: _bundle,
      ),
      _failure,
    );
    final multibyte = 'é' * (CloudSyncPreparedExtension.maxJsonBytes ~/ 2 + 1);
    expect(
      () => CloudSyncPreparedExtension.parse(
        multibyte,
        expectedParentBundleId: _bundle,
      ),
      _failure,
    );
  });

  test(
    'malformed, duplicate, raw archive and nested input has fixed failure',
    () {
      final source = jsonEncode(_fixture());
      for (final invalid in [
        '',
        'secret-invalid-input',
        'bplist00',
        'null',
        'true',
        '[]',
        '1',
        '{}',
        '$source trailing',
        '$source$source',
        source.substring(0, source.length - 1),
        '\ud800',
        source.replaceFirst('"version":1', '"version":2,"version":1'),
        source.replaceFirst('"version":1', r'"version":1,"vers\u0069on":1'),
        source.replaceFirst('"name":', '"name":"other","name":'),
        source.replaceFirst('"url":', '"url":"other","url":'),
        source.replaceFirst('"caption":', '"caption":"other","caption":'),
        '${'[' * 10000}0${']' * 10000}',
      ]) {
        expect(
          () => CloudSyncPreparedExtension.parse(
            invalid,
            expectedParentBundleId: _bundle,
          ),
          _failure,
        );
      }
    },
  );

  test('quoted delimiters and escaped quotes do not confuse preflight', () {
    final value = _fixture();
    value['metadata']['name'] = r'"quoted" \\ {[,]}, "version":2';
    expect(_parse(value).metadata.name, value['metadata']['name']);
  });
}
