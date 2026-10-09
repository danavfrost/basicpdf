import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Asks for a password. [tryPassword] is called for each attempt; a wrong
/// password shakes the dialog and asks again. Returns the accepted password,
/// or null if cancelled.
Future<String?> showPasswordDialog(
  BuildContext context, {
  String title = 'Password required',
  String message = 'This PDF is protected. Enter its password to open it.',
  String action = 'Open',
  required Future<bool> Function(String password) tryPassword,
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PasswordDialog(
      title: title,
      message: message,
      action: action,
      tryPassword: tryPassword,
    ),
  );
}

class PasswordDialog extends StatefulWidget {
  const PasswordDialog({
    super.key,
    required this.title,
    required this.message,
    required this.action,
    required this.tryPassword,
  });
  final String title, message, action;
  final Future<bool> Function(String password) tryPassword;

  @override
  State<PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<PasswordDialog>
    with SingleTickerProviderStateMixin {
  final _ctl = TextEditingController();
  late final _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 400),
  );
  bool _wrong = false;
  bool _busy = false;
  bool _obscure = true;

  @override
  void dispose() {
    _ctl.dispose();
    _shake.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() => _busy = true);
    final pw = _ctl.text;
    final ok = await widget.tryPassword(pw);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(pw);
      return;
    }
    setState(() {
      _busy = false;
      _wrong = true;
    });
    _ctl.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _ctl.text.length,
    );
    _shake.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _shake,
      builder: (context, child) => Transform.translate(
        offset: Offset(
          math.sin(_shake.value * math.pi * 6) * 12 * (1 - _shake.value),
          0,
        ),
        child: child,
      ),
      child: AlertDialog(
        title: Text(widget.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.message),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('password-field'),
              controller: _ctl,
              autofocus: true,
              obscureText: _obscure,
              enableSuggestions: false,
              autocorrect: false,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: 'Password',
                errorText: _wrong ? 'Wrong password. Try again.' : null,
                suffixIcon: IconButton(
                  tooltip: _obscure ? 'Show password' : 'Hide password',
                  icon: Icon(
                    _obscure ? Icons.visibility : Icons.visibility_off,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: Text(widget.action),
          ),
        ],
      ),
    );
  }
}
