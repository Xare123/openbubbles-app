bool shouldDismissKeyboardFromTranscript({
  required bool hasActiveMessageEdit,
  required bool keyboardOpen,
  required bool composerHasFocus,
  required bool subjectHasFocus,
}) {
  if (hasActiveMessageEdit) return false;
  return keyboardOpen || composerHasFocus || subjectHasFocus;
}
