import 'package:flutter/material.dart';

enum UnsavedChoice { save, discard, cancel }

/// "Save changes?" — Save / Discard / Cancel. Dismissing counts as Cancel.
Future<UnsavedChoice> showUnsavedDialog(
  BuildContext context,
  String title,
) async {
  final r = await showDialog<UnsavedChoice>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Save changes?'),
      content: Text('“$title” has unsaved changes.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(UnsavedChoice.cancel),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(UnsavedChoice.discard),
          child: const Text('Discard'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(UnsavedChoice.save),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  return r ?? UnsavedChoice.cancel;
}

/// Runs the unsaved-changes guard. Returns true when it's OK to proceed
/// (nothing to save, saved successfully, or discarded).
Future<bool> confirmLeave(
  BuildContext context, {
  required bool dirty,
  required String title,
  required Future<bool> Function() save,
}) async {
  if (!dirty) return true;
  switch (await showUnsavedDialog(context, title)) {
    case UnsavedChoice.save:
      return save();
    case UnsavedChoice.discard:
      return true;
    case UnsavedChoice.cancel:
      return false;
  }
}
