import 'package:flutter/material.dart';

import '../../services/doc_location.dart';
import '../../services/file_service.dart';

/// Ensures a sensible ".pdf" filename.
String normalizePdfName(String raw) {
  var name = raw.trim().replaceAll(RegExp(r'[/\\:*?"<>|]'), '_');
  if (name.isEmpty) name = 'Untitled';
  if (!name.toLowerCase().endsWith('.pdf')) name = '$name.pdf';
  return name;
}

/// iOS Save As: filename + folder (app Documents by default, or a folder
/// chosen with the system picker). Returns null if cancelled.
Future<(String, FolderTarget)?> showSaveAsDialog(
  BuildContext context, {
  required FileService files,
  required String initialName,
}) async {
  final folder = await files.defaultFolder();
  if (!context.mounted) return null;
  return showDialog<(String, FolderTarget)>(
    context: context,
    builder: (_) => SaveAsDialog(
      files: files,
      initialName: initialName,
      initialFolder: folder,
    ),
  );
}

class SaveAsDialog extends StatefulWidget {
  const SaveAsDialog({
    super.key,
    required this.files,
    required this.initialName,
    required this.initialFolder,
  });
  final FileService files;
  final String initialName;
  final FolderTarget initialFolder;

  @override
  State<SaveAsDialog> createState() => _SaveAsDialogState();
}

class _SaveAsDialogState extends State<SaveAsDialog> {
  late final _ctl = TextEditingController(text: widget.initialName);
  late FolderTarget _folder = widget.initialFolder;
  bool _exists = false;

  @override
  void initState() {
    super.initState();
    final dot = widget.initialName.toLowerCase().lastIndexOf('.pdf');
    _ctl.selection = TextSelection(
      baseOffset: 0,
      extentOffset: dot > 0 ? dot : widget.initialName.length,
    );
    _checkExists();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _checkExists() async {
    final e = await widget.files.existsInFolder(
      _folder,
      normalizePdfName(_ctl.text),
    );
    if (mounted && e != _exists) setState(() => _exists = e);
  }

  Future<void> _chooseFolder() async {
    final f = await widget.files.pickFolder();
    if (f == null || !mounted) return;
    setState(() => _folder = f);
    _checkExists();
  }

  void _save() =>
      Navigator.of(context).pop((normalizePdfName(_ctl.text), _folder));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Save As'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _ctl,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'File name',
              helperText: _exists
                  ? 'A file with this name will be replaced.'
                  : null,
              helperStyle: TextStyle(color: scheme.error),
            ),
            onChanged: (_) => _checkExists(),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Icon(Icons.folder_outlined, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _folder.displayName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _chooseFolder,
              child: const Text('Choose folder…'),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
