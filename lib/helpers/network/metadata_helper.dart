import 'dart:async';

import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:dio/dio.dart';
import 'package:html/parser.dart' as parser;
import 'package:metadata_fetch/metadata_fetch.dart';
import 'package:universal_io/io.dart';

class MetadataHelper {
  static bool mapIsNotEmpty(Map<String, dynamic>? data) {
    if (data == null) return false;
    return data.containsKey("title") && data["title"] != null;
  }

  static bool isNotEmpty(Metadata? data) {
    return data?.title != null || data?.description != null || data?.image != null;
  }

  static final Map<String, Completer<Metadata?>> _metaCache = {};

  /// Fetches link preview metadata for [previewUrl], falling back to the first
  /// URL in the message when no URL is given.
  ///
  /// [previewUrl] exists because a message can carry more than one link. The
  /// cache used to be keyed by message GUID alone and the URL was always
  /// `message.url`, which is the *first* URL in the whole message text. A
  /// message with three links therefore fetched the first link three times and
  /// shared a single cache entry between all three previews, so the second and
  /// third rendered as empty boxes.
  static Future<Metadata?> fetchMetadata(Message message, {String? previewUrl}) async {
    Metadata? data;

    // Get the URL
    final url = _resolveUrl(previewUrl) ?? _resolveUrl(message.url);
    if (url == null) return null;

    // Key on the message and the URL together. Keying on the message alone
    // made every link in a multi-link message collide.
    final cacheKey = "${message.guid}|$url";

    // If we have a cached item for this already, return that future
    if (_metaCache.containsKey(cacheKey)) {
      return _metaCache[cacheKey]!.future;
    }

    // Create a new completer for this request
    Completer<Metadata?> completer = Completer();
    _metaCache[cacheKey] = completer;
    try {
      data = await MetadataFetch.extract(url);
    } catch (ex, stack) {
      Logger.error('An error occurred while fetching URL Preview Metadata!', error: ex, trace: stack);
    }

    // If the everything in the metadata is null or empty, try to manually parse
    if (data?.toMap().values.where((e) => !isNullOrEmpty(e)).isEmpty ?? true) {
      data = await MetadataHelper._manuallyGetMetadata(url);
    }

    // If the URL points at an actual image, use it as the preview image.
    //
    // This used to test `data.url`, which is not assigned until the bottom of
    // this method, so for a bare image link it was still null here and the
    // check could never fire. A link straight to a .jpg has no HTML metadata
    // to scrape, so this fallback is the only thing that gives it a preview,
    // and it rendered as an empty card instead.
    //
    // The pattern is matched against the path so a query string does not
    // defeat the anchor, and the dots are escaped: unescaped `.jpg` matches
    // any character before "jpg".
    final urlPath = Uri.tryParse(url)?.path ?? url;
    final imageExtension = RegExp(r"\.(png|jpe?g|gif|tiff?|webp|heic|bmp)$", caseSensitive: false);
    if (data?.image == null && data?.title == null && imageExtension.hasMatch(urlPath)) {
      data ??= Metadata();
      data.image = url;
      data.title = "Image Preview";
    }

    // Remove the image data if the image data links to an "empty image"
    String imageData = data?.image ?? "";
    if (imageData.contains("renderTimingPixel.png") || imageData.contains("fls-na.amazon.com")) {
      data?.image = null;
    } else if (imageData.startsWith('//')) {
      data?.image = 'https:$imageData';
    // In case the image is just a relative URL path
    } else if (imageData.startsWith('/')) {
      data?.image = '$url$imageData';
    }

    // Remove title or description if either are the "null" string
    if (data?.title == "null") data?.title = null;
    if (data?.description == "null") data?.description = null;

    // Set the OG URL
    data?.url = url;

    // Delete from the cache after 15 seconds (arbitrary)
    Future.delayed(const Duration(seconds: 15), () {
      _metaCache.remove(cacheKey);
    });

    // Tell everyone that it's complete
    completer.complete(data);
    return completer.future;
  }

  static String? _resolveUrl(String? candidate) {
    final value = candidate?.trim();
    if (value == null || value.isEmpty || value.contains(RegExp(r"\s")) || !value.hasUrl) {
      return null;
    }

    final parsed = Uri.tryParse(value);
    final normalized = parsed?.hasScheme == true ? value : "https://$value";
    final normalizedUri = Uri.tryParse(normalized);
    if (normalizedUri == null || normalizedUri.host.isEmpty ||
        !["http", "https"].contains(normalizedUri.scheme.toLowerCase())) {
      return null;
    }
    return normalized;
  }

  /// Manually tries to parse out metadata from a given [url]
  static Future<Metadata> _manuallyGetMetadata(String url) async {
    Metadata meta = Metadata();

    try {
      final response = await http.dio.get(url, options: Options(headers: {
        // pretend to be a social media crawler
        "User-Agent": "Mozilla/5.0 (Windows NT 6.1; rv:6.0) Gecko/20110814 Firefox/6.0 Google (+https://developers.google.com/+/web/snippet/)"
      }));
      if (response.headers.value('content-type')?.startsWith("image/") ?? false) {
        meta.image = url;
      }
      final document = parser.parse(response.data);
      final props = document.head?.children
          .where((e) => e.localName == "meta" && e.attributes["property"].toString().contains("og:"))
          .map((e) => MapEntry(e.attributes["property"], e.attributes["content"])).toList() ?? [];
      for (MapEntry entry in props) {
        if (entry.key == "og:title") {
          meta.title = entry.value;
        } else if (entry.key == "og:description") {
          meta.description = entry.value;
        } else if (entry.key == "og:image") {
          meta.image = entry.value;
        } else if (entry.key == "og:video" && meta.image != null) {
          meta.image = entry.value;
        } else if (entry.key == "og:url") {
          meta.url = entry.value;
        }
      }
    } on HandshakeException catch (ex) {
      meta.title = 'Invalid SSL Certificate';
      meta.description = ex.message;
    } catch (ex, stack) {
      // meta.title = ex.toString();
      Logger.error('Failed to manually get metadata!', error: ex, trace: stack);
      rethrow;
    }

    return meta;
  }
}
