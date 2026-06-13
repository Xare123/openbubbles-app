import 'dart:ui';

import 'package:bluebubbles/app/wrappers/bb_scaffold.dart';
import 'package:bluebubbles/app/wrappers/scrollbar_wrapper.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:get/get.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

class LoggingPanel extends StatefulWidget {
  const LoggingPanel({super.key});

  @override
  State<StatefulWidget> createState() => _LoggingPanel();
}

class _LoggingPanel extends State<LoggingPanel> {
  final RxList<String> _logs = <String>[].obs;
  final RxList<int> _errorIndices = <int>[].obs;
  final RxBool _showErrorFab = false.obs;
  final RxBool _errorNavigationActive = false.obs;
  final RxBool showInfo = true.obs;
  final RxBool showDebug = true.obs;
  final RxBool showWarn = true.obs;
  final RxBool showError = true.obs;

  final AutoScrollController _scrollController = AutoScrollController();
  int _nextErrorOffset = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    loadLogs();
  }

  void loadLogs() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Logger.getLogs(maxLines: 500).then((value) {
        _logs.clear();

        final filtered = value.where((entry) {
          if (entry.contains('[INFO]')) return showInfo.value;
          if (entry.contains('[DEBUG]')) return showDebug.value;
          if (entry.contains('[WARN]') || entry.contains('[WARNING]')) return showWarn.value;
          if (entry.contains('[ERROR]')) return showError.value;
          return true;
        }).toList();

        _logs.addAll(filtered);
        _rebuildErrorState();
        _scrollToBottom();
      });
    });
  }

  void _rebuildErrorState() {
    _errorIndices.assignAll(
      _logs
          .asMap()
          .entries
          .where((entry) => entry.value.contains('[ERROR]'))
          .map((entry) => entry.key)
          .toList()
          .reversed,
    );
    _nextErrorOffset = 0;
    _errorNavigationActive.value = false;
    _updateFabVisibility();
  }

  void _onScroll() {
    _updateFabVisibility();
  }

  void _updateFabVisibility() {
    if (!_scrollController.hasClients || _logs.isEmpty || _errorIndices.isEmpty) {
      _showErrorFab.value = false;
      return;
    }

    const double showThresholdPx = 50;
    final double fromBottom = _scrollController.position.maxScrollExtent - _scrollController.position.pixels;
    _showErrorFab.value = fromBottom > showThresholdPx || _errorNavigationActive.value;
  }

  Future<void> _goToNextError() async {
    if (_errorIndices.isEmpty || !_scrollController.hasClients) return;

    _errorNavigationActive.value = true;
    if (_nextErrorOffset >= _errorIndices.length) {
      _nextErrorOffset = 0;
    }

    final int targetIndex = _errorIndices[_nextErrorOffset];
    _nextErrorOffset = (_nextErrorOffset + 1) % _errorIndices.length;
    final int scrollIndex = (targetIndex - 2).clamp(0, _logs.length - 1);

    await _scrollController.scrollToIndex(
      scrollIndex,
      preferPosition: AutoScrollPosition.begin,
      duration: const Duration(milliseconds: 250),
    );

    _updateFabVisibility();
  }

  Future<void> _scrollToBottom([int attempt = 0]) async {
    if (_logs.isEmpty) return;

    if (!_scrollController.hasClients) {
      if (attempt >= 8) return;
      await Future.delayed(const Duration(milliseconds: 50));
      return _scrollToBottom(attempt + 1);
    }

    await _scrollController.scrollToIndex(
      _logs.length - 1,
      preferPosition: AutoScrollPosition.end,
      duration: const Duration(milliseconds: 250),
    );
  }

  void _handleFilterAction(_LogFilterAction action) {
    switch (action) {
      case _LogFilterAction.info:
        showInfo.toggle();
        break;
      case _LogFilterAction.debug:
        showDebug.toggle();
        break;
      case _LogFilterAction.warn:
        showWarn.toggle();
        break;
      case _LogFilterAction.error:
        showError.toggle();
        break;
      case _LogFilterAction.refresh:
        break;
    }

    loadLogs();
  }

  void _setExclusiveFilter(_LogFilterAction action) {
    showInfo.value = action == _LogFilterAction.info;
    showDebug.value = action == _LogFilterAction.debug;
    showWarn.value = action == _LogFilterAction.warn;
    showError.value = action == _LogFilterAction.error;
    loadLogs();
  }

  PopupMenuItem<_LogFilterAction> _buildLevelFilterItem({
    required BuildContext context,
    required _LogFilterAction action,
    required String label,
  }) {
    return PopupMenuItem<_LogFilterAction>(
      enabled: false,
      padding: EdgeInsets.zero,
      child: Obx(
        () {
          final bool checked = switch (action) {
            _LogFilterAction.info => showInfo.value,
            _LogFilterAction.debug => showDebug.value,
            _LogFilterAction.warn => showWarn.value,
            _LogFilterAction.error => showError.value,
            _LogFilterAction.refresh => false,
          };

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _handleFilterAction(action),
            onLongPress: () => _setExclusiveFilter(action),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    checked ? Icons.check_box : Icons.check_box_outline_blank,
                    size: 20,
                    color: checked ? context.theme.colorScheme.primary : context.theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    label,
                    style: context.theme.textTheme.bodyMedium!.copyWith(
                      color: checked ? context.theme.colorScheme.primary : context.theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => BBScaffold(
        appBar: PreferredSize(
          preferredSize: Size(NavigationSvc.width(context), 80),
          child: ClipRRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
              child: AppBar(
                systemOverlayStyle:
                    ThemeData.estimateBrightnessForColor(context.theme.colorScheme.surface) == Brightness.dark
                        ? SystemUiOverlayStyle.light
                        : SystemUiOverlayStyle.dark,
                toolbarHeight: kIsDesktop ? 80 : 50,
                elevation: 0,
                scrolledUnderElevation: 3,
                surfaceTintColor: context.theme.colorScheme.primary,
                leading: buildBackButton(context),
                backgroundColor: SettingsSvc.settings.windowEffect.value != WindowEffect.disabled
                    ? Colors.transparent
                    : context.theme.colorScheme.surface,
                centerTitle: SettingsSvc.settings.skin.value == Skins.iOS,
                title: Text(
                  'Logs',
                  style: context.theme.textTheme.titleLarge,
                ),
                actions: [
                  PopupMenuButton<_LogFilterAction>(
                    icon: const Icon(Icons.more_vert),
                    onSelected: _handleFilterAction,
                    itemBuilder: (context) => [
                      _buildLevelFilterItem(
                        context: context,
                        action: _LogFilterAction.info,
                        label: 'INFO',
                      ),
                      _buildLevelFilterItem(
                        context: context,
                        action: _LogFilterAction.debug,
                        label: 'DEBUG',
                      ),
                      _buildLevelFilterItem(
                        context: context,
                        action: _LogFilterAction.warn,
                        label: 'WARN',
                      ),
                      _buildLevelFilterItem(
                        context: context,
                        action: _LogFilterAction.error,
                        label: 'ERROR',
                      ),
                      const PopupMenuDivider(),
                      const PopupMenuItem<_LogFilterAction>(
                        value: _LogFilterAction.refresh,
                        child: ListTile(
                          leading: Icon(Icons.refresh),
                          title: Text('Refresh'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        floatingActionButton: (_showErrorFab.value && _errorIndices.isNotEmpty)
            ? FloatingActionButton.extended(
                onPressed: _goToNextError,
                icon: const Icon(Icons.error_outline),
                label: const Text('Go to Next Error'),
              )
            : null,
        body: ScrollbarWrapper(
          showScrollbar: true,
          controller: _scrollController,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 5.0),
            child: (_logs.isEmpty)
                ? const Center(
                    child: Text(
                      'No logs to display',
                      style: TextStyle(fontSize: 16.0),
                    ),
                  )
                : ListView.separated(
                    itemCount: _logs.length,
                    shrinkWrap: true,
                    controller: _scrollController,
                    separatorBuilder: (context, index) =>
                        Divider(thickness: 0.25, color: context.theme.colorScheme.onSurface),
                    itemBuilder: (context, index) {
                      String log = _logs[index].trim();

                      // Remove date
                      log = log.split(' ').sublist(1).join(' ');

                      Color textColor = context.theme.colorScheme.primary;
                      if (log.contains('[ERROR]')) {
                        textColor = Colors.red;
                      } else if (log.contains('[WARNING]')) {
                        textColor = Colors.orange;
                      } else if (log.contains('[TRACE]')) {
                        textColor = context.theme.colorScheme.primary;
                      } else if (log.contains('[FATAL]')) {
                        textColor = Colors.red;
                      } else if (log.contains('[DEBUG]')) {
                        textColor = context.theme.colorScheme.secondary;
                      }

                      return AutoScrollTag(
                        key: ValueKey(index),
                        controller: _scrollController,
                        index: index,
                        child: Text(
                          log,
                          style: TextStyle(fontSize: 12.0, color: textColor),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ),
    );
  }
}

enum _LogFilterAction {
  info,
  debug,
  warn,
  error,
  refresh,
}
