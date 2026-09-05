import 'dart:math';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/ui/media/conversation_media_pager.dart';
import 'package:flutter/material.dart';

typedef ConversationMediaTileBuilder =
    Widget Function(BuildContext context, Attachment attachment);

/// The details page is an overview, not an unbounded gallery. In particular,
/// scrolling toward documents must never request another page of photos.
class ConversationMediaPreview extends StatelessWidget {
  const ConversationMediaPreview({
    super.key,
    required this.items,
    required this.hasOlder,
    required this.onSeeAll,
    required this.itemBuilder,
  });

  static const previewLimit = 6;
  final List<Attachment> items;
  final bool hasOlder;
  final VoidCallback onSeeAll;
  final ConversationMediaTileBuilder itemBuilder;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    final theme = Theme.of(context);
    return SliverMainAxisGroup(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.only(
            top: 20,
            bottom: 10,
            left: 15,
            right: 10,
          ),
          sliver: SliverToBoxAdapter(
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'IMAGES & VIDEOS',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ),
                if (items.length > previewLimit || hasOlder)
                  TextButton(onPressed: onSeeAll, child: const Text('See all')),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.all(10),
          sliver: SliverLayoutBuilder(
            builder: (context, constraints) {
              return SliverGrid(
                gridDelegate: _gridDelegate(constraints.crossAxisExtent),
                delegate: SliverChildBuilderDelegate(
                  (context, index) => KeyedSubtree(
                    key: ValueKey(items[index].guid ?? items[index]),
                    child: itemBuilder(context, items[index]),
                  ),
                  childCount: min(items.length, previewLimit),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Borrows the profile's pager so returning keeps its newest-first position.
/// Only this full gallery may load older pages as the user scrolls.
class ConversationMediaGallery extends StatelessWidget {
  const ConversationMediaGallery({
    super.key,
    required this.pager,
    required this.itemBuilder,
    this.actions = const [],
  });

  final ConversationMediaPager pager;
  final ConversationMediaTileBuilder itemBuilder;
  final List<Widget> actions;

  void _loadNearEdge(BuildContext context) {
    if (!pager.hasOlder || pager.loadingOlder || pager.lastError != null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // loadOlder also checks disposal and concurrent requests.
      if (context.mounted && pager.lastError == null) pager.loadOlder();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Images & videos'), actions: actions),
      body: SafeArea(
        top: false,
        child: AnimatedBuilder(
          animation: pager,
          builder: (context, _) {
            final items = pager.items;
            return CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.all(10),
                  sliver: SliverLayoutBuilder(
                    builder: (context, constraints) {
                      return SliverGrid(
                        gridDelegate: _gridDelegate(
                          constraints.crossAxisExtent,
                        ),
                        delegate: SliverChildBuilderDelegate((context, index) {
                          if (index >= items.length - 4) _loadNearEdge(context);
                          return KeyedSubtree(
                            key: ValueKey(items[index].guid ?? items[index]),
                            child: itemBuilder(context, items[index]),
                          );
                        }, childCount: items.length),
                      );
                    },
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Center(
                      child: pager.loadingOlder
                          ? const CircularProgressIndicator()
                          : pager.lastError != null
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text(
                                  'Could not load more photos and videos.',
                                ),
                                TextButton(
                                  onPressed: pager.hasOlder
                                      ? pager.loadOlder
                                      : pager.loadInitial,
                                  child: const Text('Retry'),
                                ),
                              ],
                            )
                          : pager.hasOlder
                          ? TextButton(
                              onPressed: pager.loadOlder,
                              child: const Text('Load more'),
                            )
                          : items.isEmpty
                          ? const Text('No images or videos yet.')
                          : const SizedBox.shrink(),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

SliverGridDelegateWithFixedCrossAxisCount _gridDelegate(double width) {
  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: max(2, width ~/ 200),
    mainAxisSpacing: 10,
    crossAxisSpacing: 10,
  );
}
