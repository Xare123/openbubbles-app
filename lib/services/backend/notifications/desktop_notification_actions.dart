List<String> resolveDesktopNotificationActions({
  required List<String> actionList,
  required Iterable<int> selectedIndices,
  required bool privateApiEnabled,
  required bool sourceIsReaction,
  required bool sourceIsGroupEvent,
  required Map<String, String> reactionEmojis,
}) {
  final selected = selectedIndices.toSet();
  final actions = <String>[];

  for (var index = 0; index < actionList.length; index++) {
    if (!selected.contains(index)) continue;

    final action = actionList[index];
    if (action == 'Mark Read') {
      actions.add(action);
      continue;
    }

    if (!privateApiEnabled || sourceIsReaction || sourceIsGroupEvent) continue;
    final emoji = reactionEmojis[action];
    if (emoji != null) actions.add(emoji);
  }

  return actions;
}
