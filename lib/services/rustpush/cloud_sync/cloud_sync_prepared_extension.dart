import 'dart:convert';
import 'dart:typed_data';

import 'package:bluebubbles/database/global/payload_data.dart';
import 'package:bluebubbles/helpers/types/constants.dart' show PayloadType;

/// Content-free failure: the parent must retain/defer, never fall back to an
/// empty payload or treat this as successful record admission.
final class CloudSyncPreparedExtensionFailure implements Exception {
  const CloudSyncPreparedExtensionFailure();

  @override
  String toString() => 'CloudSyncPreparedExtensionFailure: invalid metadata';
}

/// Prepare the native v1 UTF-8 JSON STRING before opening a DB transaction.
/// This does not decode keyed archives, fetch URLs, or initialize services.
/// Original transport bytes are separate from the immutable renderer POD.
final class CloudSyncPreparedExtension {
  static const maxJsonBytes = 8 * 1024 * 1024;
  static const maxStringBytes = 16 * 1024;
  static const maxBundleIdBytes = 1024;
  static const maxIconBytes = 1024 * 1024;

  CloudSyncPreparedExtension._(this.metadata, this.canonicalUtf8);

  final CloudSyncExtensionMetadata metadata;

  /// Exact UTF-8 of the supplied native string, including whitespace, key
  /// order and escapes. Hash these bytes, not jsonEncode(metadata). This is
  /// not the original protected record/archive, which the parent must retain.
  final Uint8List canonicalUtf8;

  factory CloudSyncPreparedExtension.parse(
    String json, {
    required String expectedParentBundleId,
  }) {
    try {
      _checkText(json, maxJsonBytes);
      _checkBundle(expectedParentBundleId);
      _preflight(json);
      final root = _object(jsonDecode(json), const ['version', 'metadata']);
      if (root['version'] is! int || root['version'] != 1) _invalid();
      final value = _object(root['metadata'], const [
        'name',
        'app_id',
        'bundle_id',
        'balloon',
      ]);
      final bundleId = _text(value['bundle_id']);
      _checkBundle(bundleId);
      if (bundleId != expectedParentBundleId) _invalid();
      final appId = value['app_id'];
      if (appId != null &&
          (appId is! int || appId < 0 || appId > 9223372036854775807)) {
        _invalid();
      }
      final balloon = _object(value['balloon'], const [
        'url',
        'session',
        'ld_text',
        'is_live',
        'icon',
        'layout',
      ]);
      final session = _optionalText(balloon['session']);
      // Native UUID::from_slice accepts all 128-bit patterns, not just v4.
      // Preserve spelling; do not impose UUID version/variant restrictions.
      if (session != null &&
          (session.length != 36 || !_uuid.hasMatch(session))) {
        _invalid();
      }
      final isLive = balloon['is_live'];
      if (isLive is! bool) _invalid();
      final rawIcon = balloon['icon'];
      Uint8List? icon;
      if (rawIcon != null) {
        if (rawIcon is! List || rawIcon.length > maxIconBytes) _invalid();
        for (final byte in rawIcon) {
          if (byte is! int || byte < 0 || byte > 255) _invalid();
        }
        icon = Uint8List.fromList(rawIcon.cast<int>()).asUnmodifiableView();
      }
      final rawLayout = balloon['layout'];
      CloudSyncExtensionLayout? layout;
      if (rawLayout != null) {
        final fields = _object(rawLayout, const [
          'image_subtitle',
          'image_title',
          'caption',
          'secondary_subcaption',
          'tertiary_subcaption',
          'subcaption',
        ]);
        layout = CloudSyncExtensionLayout._(
          _text(fields['image_subtitle']),
          _text(fields['image_title']),
          _text(fields['caption']),
          _text(fields['secondary_subcaption']),
          _text(fields['tertiary_subcaption']),
          _text(fields['subcaption']),
        );
      }
      return CloudSyncPreparedExtension._(
        CloudSyncExtensionMetadata._(
          _text(value['name']),
          appId as int?,
          bundleId,
          CloudSyncExtensionBalloon._(
            _text(balloon['url']),
            session,
            _optionalText(balloon['ld_text']),
            isLive,
            icon,
            layout,
          ),
        ),
        Uint8List.fromList(utf8.encode(json)).asUnmodifiableView(),
      );
    } on FormatException {
      // Never propagate the decoder's source excerpt or input-derived details.
      _invalid();
    }
  }

  /// Allocates fresh legacy models, copying only appToData's known fields.
  /// Do not call their service-backed bundleId/icon/isSupported getters here.
  /// Parent integration must persist metadata.bundleId separately.
  PayloadData toPayloadData() {
    final balloon = metadata.balloon;
    final layout = balloon.layout;
    return PayloadData(
      type: PayloadType.app,
      appData: [
        iMessageAppData(
          appName: metadata.name,
          appId: metadata.appId,
          ldText: balloon.ldText,
          url: balloon.url,
          session: balloon.session,
          appIcon: balloon.icon == null ? null : base64Encode(balloon.icon!),
          isLive: balloon.isLive,
          userInfo: layout == null
              ? null
              : UserInfo(
                  imageSubtitle: layout.imageSubtitle,
                  imageTitle: layout.imageTitle,
                  caption: layout.caption,
                  secondarySubcaption: layout.secondarySubcaption,
                  tertiarySubcaption: layout.tertiarySubcaption,
                  subcaption: layout.subcaption,
                ),
        ),
      ],
    );
  }
}

final class CloudSyncExtensionMetadata {
  const CloudSyncExtensionMetadata._(
    this.name,
    this.appId,
    this.bundleId,
    this.balloon,
  );
  final String name;
  final int? appId;
  final String bundleId;
  final CloudSyncExtensionBalloon balloon;
}

final class CloudSyncExtensionBalloon {
  const CloudSyncExtensionBalloon._(
    this.url,
    this.session,
    this.ldText,
    this.isLive,
    this.icon,
    this.layout,
  );
  final String url;
  final String? session;
  final String? ldText;
  final bool isLive;
  final Uint8List? icon;
  final CloudSyncExtensionLayout? layout;
}

final class CloudSyncExtensionLayout {
  const CloudSyncExtensionLayout._(
    this.imageSubtitle,
    this.imageTitle,
    this.caption,
    this.secondarySubcaption,
    this.tertiarySubcaption,
    this.subcaption,
  );
  final String imageSubtitle;
  final String imageTitle;
  final String caption;
  final String secondarySubcaption;
  final String tertiarySubcaption;
  final String subcaption;
}

Never _invalid() => throw const CloudSyncPreparedExtensionFailure();

final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

Map<String, dynamic> _object(Object? value, List<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !keys.every(value.containsKey)) {
    _invalid();
  }
  return value;
}

String _text(Object? value) {
  if (value is! String) _invalid();
  _checkText(value, CloudSyncPreparedExtension.maxStringBytes);
  return value;
}

String? _optionalText(Object? value) => value == null ? null : _text(value);

void _checkBundle(String value) {
  _checkText(value, CloudSyncPreparedExtension.maxBundleIdBytes);
  if (value.isEmpty ||
      value.runes.any((r) => r <= 0x1f || (r >= 0x7f && r <= 0x9f))) {
    _invalid();
  }
}

/// Measure before allocating encoded bytes. Reject unpaired UTF-16 surrogates
/// instead of silently replacing them during UTF-8 encoding.
void _checkText(String value, int limit) {
  if (value.length > limit) _invalid();
  var bytes = 0;
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++i == value.length) _invalid();
      final low = value.codeUnitAt(i);
      if (low < 0xdc00 || low > 0xdfff) _invalid();
      bytes += 4;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      _invalid();
    } else {
      bytes += unit < 0x80 ? 1 : (unit < 0x800 ? 2 : 3);
    }
    if (bytes > limit) _invalid();
  }
}

/// Bound nesting before jsonDecode, and reject duplicate keys (including
/// escaped aliases) before the standard decoder can overwrite them. Full
/// syntax validation remains jsonDecode's responsibility. v1 needs depth 4.
void _preflight(String json) {
  final containers = <int>[];
  final keys = <Set<String>?>[];
  var expectingKey = false;
  for (var i = 0; i < json.length; i++) {
    final c = json.codeUnitAt(i);
    if (c == 0x22) {
      final start = i;
      while (++i < json.length && json.codeUnitAt(i) != 0x22) {
        if (json.codeUnitAt(i) == 0x5c) i++;
      }
      if (i >= json.length) _invalid();
      if (expectingKey && keys.isNotEmpty && keys.last != null) {
        final key = _text(jsonDecode(json.substring(start, i + 1)));
        if (!keys.last!.add(key)) _invalid();
      }
      expectingKey = false;
    } else if (c == 0x7b || c == 0x5b) {
      if (containers.length == 4) _invalid();
      containers.add(c);
      keys.add(c == 0x7b ? <String>{} : null);
      expectingKey = c == 0x7b;
    } else if (c == 0x7d || c == 0x5d) {
      if (containers.isEmpty ||
          containers.removeLast() != (c == 0x7d ? 0x7b : 0x5b)) {
        _invalid();
      }
      keys.removeLast();
      expectingKey = false;
    } else if (c == 0x2c) {
      expectingKey = keys.isNotEmpty && keys.last != null;
    }
  }
  if (containers.isNotEmpty) _invalid();
}
