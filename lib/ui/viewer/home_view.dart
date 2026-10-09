import 'package:flutter/material.dart';

import '../../services/doc_location.dart';
import '../../services/file_service.dart';
import '../../services/history_store.dart';
import '../open/open_dialog.dart';

/// Shown when no document is open: Recent list plus New / Open.
class HomeView extends StatefulWidget {
  const HomeView({
    super.key,
    required this.history,
    required this.files,
    required this.onNew,
    required this.onOpen,
    required this.onOpenRecent,
    this.topPadding = 0,
  });

  final HistoryStore history;
  final FileService files;
  final VoidCallback onNew;
  final VoidCallback onOpen;
  final ValueChanged<DocLocation> onOpenRecent;
  final double topPadding;

  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> {
  // One status check per entry while Home is shown, not one per rebuild.
  final _statusCache = <String, Future<FileStatus>>{};
  Future<FileStatus> _status(DocLocation l) =>
      _statusCache.putIfAbsent(l.key, () => widget.files.status(l));

  @override
  Widget build(BuildContext context) {
    final history = widget.history;
    final topPadding = widget.topPadding;
    final onNew = widget.onNew, onOpen = widget.onOpen;
    final onOpenRecent = widget.onOpenRecent;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: history,
      builder: (context, _) {
        final recent = history.recent;
        return ListView(
          padding: EdgeInsets.fromLTRB(0, topPadding + 8, 0, 24),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      key: const ValueKey('home-new'),
                      onPressed: onNew,
                      icon: const Icon(Icons.note_add_outlined),
                      label: const Text('New'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      key: const ValueKey('home-open'),
                      onPressed: onOpen,
                      icon: const Icon(Icons.folder_open_outlined),
                      label: const Text('Open'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
              child: Text(
                'Recent',
                style: text.titleSmall?.copyWith(color: scheme.primary),
              ),
            ),
            if (history.isLoaded && recent.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'PDFs you open will show up here.',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
            for (final e in recent)
              HistoryTile(
                entry: e,
                status: _status(e.location),
                onOpen: () => onOpenRecent(e.location),
                onRemove: () => history.remove(e.location),
              ),
          ],
        );
      },
    );
  }
}
