import 'package:bluebubbles/database/models.dart';
import 'package:flutter/foundation.dart';

typedef ChatMediaPageLoader = Future<ChatMediaPage> Function({
  required ChatMediaDirection direction,
  ChatMediaCursor? cursor,
  required int limit,
});

class ConversationMediaPager extends ChangeNotifier {
  ConversationMediaPager({
    required this.chat,
    this.pageSize = 24,
    ChatMediaPageLoader? loader,
  }) : _loader = loader;

  final Chat chat;
  final int pageSize;
  final ChatMediaPageLoader? _loader;

  final List<Attachment> _items = <Attachment>[];
  bool _loadingOlder = false;
  bool _loadingNewer = false;
  bool _hasOlder = true;
  bool _hasNewer = true;
  bool _disposed = false;
  int _generation = 0;
  ChatMediaCursor? _olderCursor;
  ChatMediaCursor? _newerCursor;

  List<Attachment> get items => List.unmodifiable(_items);
  bool get loadingOlder => _loadingOlder;
  bool get loadingNewer => _loadingNewer;
  bool get hasOlder => _hasOlder;
  bool get hasNewer => _hasNewer;
  Object? lastError;

  void seed(
    Iterable<Attachment> attachments, {
    Attachment? selected,
    bool hasNewer = true,
    bool hasOlder = true,
  }) {
    _generation++;
    final normalized = _normalized(attachments)..sort(_newestFirst);
    _items
      ..clear()
      ..addAll(normalized);
    if (selected != null && !_contains(selected)) {
      _items.add(selected);
      _items.sort(_newestFirst);
    }
    _newerCursor = _items.isEmpty ? null : _cursorFor(_items.first);
    _olderCursor = _items.isEmpty ? null : _cursorFor(_items.last);
    _hasNewer = hasNewer && _newerCursor != null;
    _hasOlder = hasOlder && _olderCursor != null;
    _notify();
  }

  Future<void> loadInitial() async {
    final generation = ++_generation;
    _items.clear();
    _newerCursor = null;
    _olderCursor = null;
    _hasNewer = false;
    _hasOlder = true;
    _notify();

    ChatMediaPage page;
    try {
      page = await _loadUntilMedia(
        direction: ChatMediaDirection.older,
        cursor: null,
      );
      lastError = null;
    } catch (error) {
      lastError = error;
      debugPrint('Failed to load initial conversation media: $error');
      if (!_disposed && generation == _generation) {
        _hasOlder = false;
        _notify();
      }
      return;
    }
    if (_disposed || generation != _generation) return;

    _items.addAll(_normalized(page.items));
    _olderCursor = page.nextCursor;
    _newerCursor = _items.isEmpty ? null : _cursorFor(_items.first);
    _hasOlder = page.hasMore;
    _notify();
  }

  Future<void> primeAroundSelection() async {
    if (_items.isEmpty) return;
    await Future.wait([
      loadNewer(),
      loadOlder(),
    ]);
  }

  Future<void> refreshNewer() async {
    if (_items.isEmpty || _newerCursor == null) {
      await loadInitial();
      return;
    }
    _hasNewer = true;
    await loadNewer();
  }

  Future<void> loadOlder() async {
    if (_disposed || _loadingOlder || !_hasOlder) return;
    _loadingOlder = true;
    final generation = _generation;
    _notify();
    try {
      final page = await _loadUntilMedia(
        direction: ChatMediaDirection.older,
        cursor: _olderCursor,
      );
      if (_disposed || generation != _generation) return;
      lastError = null;
      _appendUnique(page.items);
      _olderCursor = page.nextCursor ?? _olderCursor;
      _hasOlder = page.hasMore;
    } catch (error) {
      lastError = error;
      debugPrint('Failed to load older conversation media: $error');
    } finally {
      if (!_disposed && generation == _generation) {
        _loadingOlder = false;
        _notify();
      }
    }
  }

  Future<void> loadNewer() async {
    if (_disposed || _loadingNewer || !_hasNewer) return;
    _loadingNewer = true;
    final generation = _generation;
    _notify();
    try {
      final page = await _loadUntilMedia(
        direction: ChatMediaDirection.newer,
        cursor: _newerCursor,
      );
      if (_disposed || generation != _generation) return;
      lastError = null;
      _prependUnique(page.items);
      _newerCursor = page.nextCursor ?? _newerCursor;
      _hasNewer = page.hasMore;
    } catch (error) {
      lastError = error;
      debugPrint('Failed to load newer conversation media: $error');
    } finally {
      if (!_disposed && generation == _generation) {
        _loadingNewer = false;
        _notify();
      }
    }
  }

  Future<ChatMediaPage> _load({
    required ChatMediaDirection direction,
    required ChatMediaCursor? cursor,
  }) {
    final loader = _loader;
    if (loader != null) {
      return loader(direction: direction, cursor: cursor, limit: pageSize);
    }
    return chat.getMediaPageAsync(
      direction: direction,
      cursor: cursor,
      limit: pageSize,
    );
  }

  /// Text-heavy stretches can produce an empty bounded database scan even
  /// though older media still exists. Advance through a few empty scans in
  /// one request so the gallery and fullscreen edge do not appear stuck.
  Future<ChatMediaPage> _loadUntilMedia({
    required ChatMediaDirection direction,
    required ChatMediaCursor? cursor,
  }) async {
    var nextCursor = cursor;
    var page = ChatMediaPage.empty;
    for (var scan = 0; scan < 4; scan++) {
      page = await _load(direction: direction, cursor: nextCursor);
      if (page.items.isNotEmpty || !page.hasMore || page.nextCursor == null) {
        return page;
      }
      nextCursor = page.nextCursor;
    }
    return page;
  }

  List<Attachment> _normalized(Iterable<Attachment> attachments) {
    final result = <Attachment>[];
    final guids = <String>{};
    for (final attachment in attachments) {
      if (attachment.mimeStart != 'image' && attachment.mimeStart != 'video') {
        continue;
      }
      if (result.contains(attachment)) continue;
      final guid = attachment.guid;
      if (guid != null && !guids.add(guid)) continue;
      result.add(attachment);
    }
    return result;
  }

  bool _contains(Attachment attachment) {
    return _items.contains(attachment) ||
        (attachment.guid != null && _items.any((item) => item.guid == attachment.guid));
  }

  void _appendUnique(Iterable<Attachment> attachments) {
    for (final attachment in _normalized(attachments)) {
      if (!_contains(attachment)) _items.add(attachment);
    }
  }

  void _prependUnique(Iterable<Attachment> attachments) {
    final additions = _normalized(attachments).where((attachment) => !_contains(attachment)).toList();
    _items.insertAll(0, additions);
  }

  ChatMediaCursor? _cursorFor(Attachment attachment) {
    final message = attachment.message.target;
    final date = message?.dateCreated;
    final id = message?.id;
    if (date == null || id == null) return null;
    return ChatMediaCursor(
      dateMilliseconds: date.millisecondsSinceEpoch,
      messageId: id,
    );
  }

  int _newestFirst(Attachment left, Attachment right) {
    final leftMessage = left.message.target;
    final rightMessage = right.message.target;
    final dateComparison = (rightMessage?.dateCreated?.millisecondsSinceEpoch ?? -1)
        .compareTo(leftMessage?.dateCreated?.millisecondsSinceEpoch ?? -1);
    if (dateComparison != 0) return dateComparison;
    return (rightMessage?.id ?? -1).compareTo(leftMessage?.id ?? -1);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
