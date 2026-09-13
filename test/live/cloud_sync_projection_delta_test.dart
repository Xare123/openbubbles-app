// Opt-in comparison for hash-verified local copies captured under the profile
// lock. No network or sends; missing input files must not create empty stores.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:bluebubbles/database/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = Platform.environment['OPENBUBBLES_PROJECTION_DELTA_COPIES'];
  final validateIcons =
      Platform.environment['OPENBUBBLES_PROJECTION_VALIDATE_ICONS'] == '1';
  if (root != null && validateIcons) {
    TestWidgetsFlutterBinding.ensureInitialized();
  }
  test('compare bounded new message rows after a protected replay', () async {
    expect(root, isNotEmpty);
    expect(File('$root/before/data.mdb').existsSync(), isTrue);
    expect(File('$root/after/data.mdb').existsSync(), isTrue);
    final before = await openStore(directory: '$root/before');
    final after = await openStore(directory: '$root/after');
    try {
      final oldBox = before.box<Message>();
      final newBox = after.box<Message>();
      final latest =
          (oldBox.query()..order(Message_.id, flags: Order.descending)).build()
            ..limit = 1;
      late final int lastId;
      try {
        lastId = latest.findFirst()?.id ?? 0;
      } finally {
        latest.close();
      }
      final added = newBox.query(Message_.id.greaterThan(lastId)).build()
        ..limit = 501;
      late final List<Message> rows;
      try {
        rows = added.find();
      } finally {
        added.close();
      }
      expect(rows.length, lessThanOrEqualTo(500));
      var textBodies = 0;
      var replacementCharacters = 0;
      var replyRows = 0;
      var multipartReplyRows = 0;
      var replacementOnlyRows = 0;
      var extensionRows = 0;
      var extensionsWithDisplayText = 0;
      var extensionsWithIcon = 0;
      var extensionDisplayTextWithReplacement = 0;
      var decodedExtensionIcons = 0;
      for (final row in rows) {
        final text =
            row.text ?? row.attributedBody.map((part) => part.string).join();
        if (text.replaceAll('\uFFFC', '').trim().isNotEmpty) textBodies++;
        replacementCharacters += '\uFFFD'.allMatches(text).length;
        if (text.contains('\uFFFD') &&
            text.replaceAll(RegExp('[\\s\uFFFC\uFFFD]'), '').isEmpty) {
          replacementOnlyRows++;
        }
        final apps = row.payloadData?.appData;
        if (row.isInteractive && apps != null && apps.isNotEmpty) {
          extensionRows++;
          if (apps.any((app) => app.ldText?.trim().isNotEmpty ?? false)) {
            extensionsWithDisplayText++;
          }
          if (apps.any((app) => app.appIcon?.isNotEmpty ?? false)) {
            extensionsWithIcon++;
          }
          if (apps.any((app) => app.ldText?.contains('\uFFFD') ?? false)) {
            extensionDisplayTextWithReplacement++;
          }
          if (validateIcons) {
            for (final app in apps) {
              final icon = app.appIcon;
              if (icon == null || icon.isEmpty) continue;
              expect(decodedExtensionIcons, lessThan(32));
              await _decodeBoundedIcon(icon);
              decodedExtensionIcons++;
            }
          }
        }
        if (row.threadOriginatorGuid != null) replyRows++;
        if (row.threadOriginatorGuid != null &&
            row.threadOriginatorPart?.contains(':') == true)
          multipartReplyRows++;
      }
      // Counts are evidence, not a claim of complete-history or visual QA.
      print(
        'projection_delta=${jsonEncode({'before_message_rows': oldBox.count(), 'after_message_rows': newBox.count(), 'new_distinct_rows': rows.length, 'new_rows_with_text': textBodies, 'replacement_characters': replacementCharacters, 'replacement_only_rows': replacementOnlyRows, 'extension_rows': extensionRows, 'extensions_with_display_text': extensionsWithDisplayText, 'extensions_with_icon': extensionsWithIcon, 'extension_display_text_with_replacement': extensionDisplayTextWithReplacement, 'icon_decode_requested': validateIcons, 'decoded_extension_icons': decodedExtensionIcons, 'new_reply_rows': replyRows, 'new_multipart_reply_rows': multipartReplyRows})}',
      );
    } finally {
      after.close();
      before.close();
    }
  }, skip: root == null);
}

// Runs Flutter's real image decoder on copied canonical bytes, without files,
// network, UI actions or emitting image content. Not a full-widget visual test.
Future<void> _decodeBoundedIcon(String encoded) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    if (encoded.length > 1400000) throw StateError('icon_copy_size_limit');
    final bytes = base64Decode(encoded);
    if (bytes.isEmpty || bytes.length > 1048576) {
      throw StateError('icon_copy_size_limit');
    }
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (descriptor.width < 1 || descriptor.height < 1 ||
        descriptor.width > 1024 || descriptor.height > 1024) {
      throw StateError('icon_copy_dimension_limit');
    }
    codec = await descriptor.instantiateCodec(targetWidth: 64, targetHeight: 64);
    image = (await codec.getNextFrame()).image;
    if (image.width < 1 || image.height < 1) {
      throw StateError('icon_copy_empty_image');
    }
  } catch (_) {
    throw StateError('extension_icon_copy_decode_failed');
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}
