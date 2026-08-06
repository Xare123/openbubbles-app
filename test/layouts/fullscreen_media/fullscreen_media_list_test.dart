import 'package:bluebubbles/app/layouts/fullscreen_media/fullscreen_media_list.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:flutter_test/flutter_test.dart';

Attachment attachment(String guid, String? mimeType) => Attachment(
      guid: guid,
      mimeType: mimeType,
      transferName: '$guid.dat',
      totalBytes: 1,
    );

void main() {
  test('keeps ordered media, removes duplicate GUIDs, and filters documents', () {
    final image = attachment('image', 'image/jpeg');
    final video = attachment('video', 'video/mp4');
    final document = attachment('document', 'application/pdf');

    final result = buildFullscreenMediaList(
      [image, document, image, video],
      image,
    );

    expect(result.map((item) => item.guid), ['image', 'video']);
  });

  test('adds the selected media when it is outside the loaded candidates', () {
    final loaded = attachment('loaded', 'image/jpeg');
    final selected = attachment('selected', 'image/png');

    final result = buildFullscreenMediaList([loaded], selected);

    expect(result.map((item) => item.guid), ['loaded', 'selected']);
  });

  test('retains a selected attachment whose MIME type is not hydrated yet', () {
    final selected = attachment('selected', null);

    final result = buildFullscreenMediaList(const [], selected);

    expect(result, [selected]);
  });

  test('does not confuse different attachments with missing GUIDs', () {
    final loaded = attachment('loaded', 'image/jpeg')..guid = null;
    final selected = attachment('selected', null)..guid = null;

    final result = buildFullscreenMediaList([loaded], selected);

    expect(result, [loaded, selected]);
  });
}
