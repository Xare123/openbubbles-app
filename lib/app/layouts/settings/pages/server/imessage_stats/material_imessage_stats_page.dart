import 'package:bluebubbles/app/layouts/settings/pages/server/imessage_stats/imessage_stats_helpers.dart';
import 'package:bluebubbles/app/layouts/settings/pages/server/server_management_panel.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/settings_widgets.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class MaterialIMessageStatsPage extends CustomStateful<ServerManagementPanelController> {
  const MaterialIMessageStatsPage({super.key, required super.parentController});

  @override
  State<StatefulWidget> createState() => _MaterialIMessageStatsPageState();
}

class _MaterialIMessageStatsPageState
    extends CustomState<MaterialIMessageStatsPage, void, ServerManagementPanelController>
    with IMessageStatsHelpersMixin {
  @override
  void initState() {
    super.initState();
    forceDelete = false;
  }

  Widget _buildLoadingState() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 60),
      child: Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(context.theme.colorScheme.primary),
        ),
      ),
    );
  }

  Widget _buildStatCard(StatItemConfig item, dynamic rawValue) {
    final count = formatCount(rawValue);
    return Card(
      elevation: 2,
      margin: const EdgeInsets.all(6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: tileColor,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: item.containerColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(item.materialIcon, color: Colors.white, size: 22),
            ),
            const SizedBox(height: 12),
            Text(
              count,
              style: context.theme.textTheme.headlineSmall!.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              item.label,
              style: context.theme.textTheme.bodySmall!.copyWith(
                color: context.theme.colorScheme.onSurface.withValues(alpha: 0.65),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMediaRow(StatItemConfig item, dynamic rawValue) {
    final count = formatCount(rawValue);
    return Card(
      elevation: 1,
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: tileColor,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: item.containerColor,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(item.materialIcon, color: Colors.white, size: 22),
        ),
        title: Text(item.label, style: context.theme.textTheme.bodyLarge),
        trailing: Text(
          count,
          style: context.theme.textTheme.titleMedium!.copyWith(
            color: context.theme.colorScheme.outline.withValues(alpha: 0.85),
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    final hasStats = controller.stats.isNotEmpty;
    final isLoading = controller.hasCheckedStats.value == false;

    if (isLoading && !hasStats) return _buildLoadingState();

    final gridItems = IMessageStatsHelpersMixin.kStatItems.where((e) => !e.isFullWidth).toList();
    final mediaItems = IMessageStatsHelpersMixin.kStatItems.where((e) => e.isFullWidth).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(15, 16, 15, 4),
          child: Text(
            "Totals",
            style: materialSubtitle,
          ),
        ),
        Center(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final itemWidth = (constraints.maxWidth - 12) / 2;
              return Wrap(
                spacing: 0,
                runSpacing: 0,
                children: gridItems.map((item) {
                  return SizedBox(
                    width: itemWidth,
                    child: _buildStatCard(item, controller.stats[item.key]),
                  );
                }).toList(),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(15, 12, 15, 4),
          child: Text(
            "Media",
            style: materialSubtitle,
          ),
        ),
        ...mediaItems.map((item) => _buildMediaRow(item, controller.stats[item.key])),
        const SizedBox(height: 8),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: "iMessage Stats",
      initialHeader: null,
      iosSubtitle: iosSubtitle,
      materialSubtitle: materialSubtitle,
      tileColor: tileColor,
      headerColor: headerColor,
      actions: [
        Obx(() {
          final isLoading = controller.hasCheckedStats.value == false && controller.stats.isEmpty;
          return IconButton(
            icon: isLoading
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(context.theme.colorScheme.primary),
                    ),
                  )
                : Icon(Icons.refresh, color: context.theme.colorScheme.onSurface),
            onPressed: isLoading ? null : () => controller.getServerStats(),
          );
        }),
      ],
      bodySlivers: [
        SliverToBoxAdapter(
          child: Obx(() => _buildBody()),
        ),
      ],
    );
  }
}
