import 'dart:async';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:flutter/material.dart';
// iCloud Keychain code management for the Profile iCloud Sync section.
// The code protects iCloud data and may be needed when signing in on a new
// device or recovering access. It is not the phone unlock code, the Apple
// Account password, or a temporary verification code.
// Behavior reuse: readiness uses the existing clique check and changing uses
// the existing escrow password call with the same formats. Nothing here
// joins, resets, or regenerates credentials automatically and no secret
// value is ever displayed or logged.
class CloudSyncKeychainCard extends StatefulWidget {
  const CloudSyncKeychainCard({super.key, this.checkReadiness, this.hasDefaultCode, this.changeCode});
  final Future<bool?> Function()? checkReadiness;
  final bool Function()? hasDefaultCode;
  final Future<void> Function(String code)? changeCode;
  @override
  State<CloudSyncKeychainCard> createState() => _CloudSyncKeychainCardState();
}
class _CloudSyncKeychainCardState extends State<CloudSyncKeychainCard> {
  bool? _ready;
  bool _checking = true;
  Future<void> refreshReadiness() async {
    setState(() { _checking = true; });
    bool? ready;
    try {
      ready = await (widget.checkReadiness ?? _defaultCheckReadiness)();
    } catch (_) {
      ready = null;
    }
    if (!mounted) return;
    setState(() { _ready = ready; _checking = false; });
  }
  static Future<bool?> _defaultCheckReadiness() async {
    try {
      return await pushService.checkClique();
    } catch (_) {
      return null;
    }
  }
  static bool _defaultHasDefault() => ss.settings.keychainDefaultPassword.value != null;
  static Future<void> _defaultChange(String code) async {
    await api.changeEscrowPassword(keychain: pushService.state!.icloudServices!.keychain!, devicePassword: code);
    ss.settings.keychainDefaultPassword.value = null;
    await ss.saveSettings();
  }
  @override
  void initState() {
    super.initState();
    unawaited(refreshReadiness());
  }
  Future<void> _openChange() async {
    final changed = await showDialog<bool>(context: context, builder: (_) => CloudSyncCodeDialog(submit: widget.changeCode ?? _defaultChange));
    if (changed == true && mounted) await refreshReadiness();
  }
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = _ready;
    final checking = _checking;
    final hasDefault = (widget.hasDefaultCode ?? _defaultHasDefault)();
    final String statusLabel;
    final String statusText;
    if (checking) { statusLabel = 'Keychain status: Checking'; statusText = 'Checking encryption status…'; }
    else if (ready == true) { statusLabel = 'Keychain status: Ready'; statusText = 'Ready for iCloud encryption.'; }
    else if (ready == false) { statusLabel = 'Keychain status: Not ready'; statusText = 'Not ready. Finish sign-in and recovery first. Nothing was changed automatically.'; }
    else { statusLabel = 'Keychain status: Unknown'; statusText = 'Status unknown. Try checking again.'; }
    return Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('iCloud Keychain code', style: theme.textTheme.titleLarge),
      const SizedBox(height: 8),
      const Text('Protects your iCloud data. You may need it when signing in on a new device or recovering access. This is not your phone unlock code, Apple Account password, or temporary verification code.'),
      const SizedBox(height: 12),
      Semantics(label: statusLabel, child: ExcludeSemantics(child: Text(statusText))),
      const SizedBox(height: 8),
      Text(hasDefault ? 'Using the default code set up on this device.' : 'A custom code is set.'),
      const SizedBox(height: 8),
      Row(children: [
        if (!checking && ready == null) TextButton(onPressed: refreshReadiness, child: const Text('Check again')),
      TextButton(onPressed: _openChange, child: const Text('Change code')),
    ])));
  }
}
class CloudSyncCodeDialog extends StatefulWidget {
  const CloudSyncCodeDialog({super.key, required this.submit, this.passcodeDefault = true});
  final Future<void> Function(String code) submit;
  final bool passcodeDefault;
  @override
  State<CloudSyncCodeDialog> createState() => _CloudSyncCodeDialogState();
}
class _CloudSyncCodeDialogState extends State<CloudSyncCodeDialog> {
  final TextEditingController _code = TextEditingController();
  late bool _passcode;
  bool _loading = false;
  bool _obscure = true;
  String? _error;
  @override
  void initState() { super.initState(); _passcode = widget.passcodeDefault; }
  @override
  void dispose() { _code.dispose(); super.dispose(); }
  Future<void> _submit() async {
    if (_loading) return;
    setState(() { _loading = true; _error = null; });
    try {
      await widget.submit(_code.text);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() { _loading = false; _error = 'Could not change the code. Check the entry and try again.'; });
    }
  }
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entered = _code.text.length;
    return AlertDialog(
      title: const Text('Change iCloud Keychain code'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_passcode ? 'Enter a new six-digit passcode.' : 'Enter a new password.'),
        const SizedBox(height: 12),
        if (_passcode) Semantics(label: 'New passcode, $entered digits entered', child: ExcludeSemantics(child: Row(children: List.generate(6, (index) {
          final digit = index < entered ? _code.text[index] : '';
          final active = index == entered;
          return Expanded(child: Container(constraints: const BoxConstraints(minHeight: 50), margin: const EdgeInsets.all(3), decoration: BoxDecoration(border: Border.all(color: active ? theme.colorScheme.primary : theme.colorScheme.outline, width: active ? 2 : 1), borderRadius: BorderRadius.circular(10)), child: Center(child: FittedBox(fit: BoxFit.scaleDown, child: Text(digit, style: theme.textTheme.titleLarge)))));
        })))),
        if (_passcode) Opacity(opacity: 0, child: TextField(controller: _code, decoration: const InputDecoration(labelText: 'New passcode'), keyboardType: TextInputType.number, textInputAction: TextInputAction.done, autofocus: true, onChanged: (_) => setState(() {}), onSubmitted: (_) => _submit())),
        if (!_passcode) TextField(controller: _code, decoration: const InputDecoration(labelText: 'New password'), obscureText: _obscure, autofocus: true, textInputAction: TextInputAction.done, onSubmitted: (_) => _submit(), suffixIcon: IconButton(tooltip: _obscure ? 'Show password' : 'Hide password', icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility), onPressed: () => setState(() => _obscure = !_obscure))),
        if (_error != null) ...[const SizedBox(height: 8), Semantics(label: 'Keychain change error', child: ExcludeSemantics(child: Text(_error!, style: TextStyle(color: theme.colorScheme.error))))],
        if (_loading) ...[const SizedBox(height: 8), const LinearProgressIndicator()],
      ])),
      actions: [
        TextButton(onPressed: _loading ? null : () => setState(() => _passcode = !_passcode), child: Text(_passcode ? 'Use password' : 'Use passcode')),
        TextButton(onPressed: _loading ? null : () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        TextButton(onPressed: _loading ? null : _submit, child: const Text('OK')),
      ],
    );
  }
}
