import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'doc_location.dart';

class HistoryEntry {
  final DocLocation location;
  final DateTime lastOpened;
  const HistoryEntry(this.location, this.lastOpened);

  Map<String, dynamic> toJson() => {
    'location': location.toJson(),
    'lastOpened': lastOpened.toIso8601String(),
  };

  static HistoryEntry? fromJson(Object? j) {
    if (j is! Map<String, dynamic>) return null;
    final loc = j['location'];
    final when = DateTime.tryParse('${j['lastOpened']}');
    if (loc is! Map<String, dynamic> || when == null) return null;
    final l = DocLocation.fromJson(loc);
    return l == null ? null : HistoryEntry(l, when);
  }
}

/// Every file ever opened, newest first, persisted as JSON
/// (`history.json` in the app support dir).
class HistoryStore extends ChangeNotifier {
  static const recentCount = 15;

  final Future<Directory> Function() _dir;
  final DateTime Function() _now;
  List<HistoryEntry> _entries = [];
  bool _loaded = false;
  Future<void>? _loading;
  Future<void> _saving = Future.value();

  HistoryStore(this._dir, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  bool get isLoaded => _loaded;

  /// All entries, most recently opened first.
  List<HistoryEntry> get all => List.unmodifiable(_entries);
  List<HistoryEntry> get recent => all.take(recentCount).toList();

  Future<File> get _file async => File('${(await _dir()).path}/history.json');

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final disk = await _readDisk();
    _entries = disk ?? [];
    _loaded = true;
    notifyListeners();
  }

  /// Entries in history.json, or null if it is absent or unreadable.
  Future<List<HistoryEntry>?> _readDisk() async {
    try {
      final f = await _file;
      if (!await f.exists()) return null;
      final data = jsonDecode(await f.readAsString());
      if (data is! List) return null;
      return data.map(HistoryEntry.fromJson).whereType<HistoryEntry>().toList()
        ..sort((a, b) => b.lastOpened.compareTo(a.lastOpened));
    } catch (_) {
      // A corrupt history file is not worth bothering the user about.
      return null;
    }
  }

  /// Records that [location] was opened now (moves it to the top).
  Future<void> touch(DocLocation location) {
    final when = _now();
    return _mutate((list) {
      list.removeWhere((e) => e.location.key == location.key);
      list.insert(0, HistoryEntry(location, when));
    });
  }

  /// Replaces the stored location (e.g. a refreshed bookmark) keeping its date.
  Future<void> update(DocLocation location) => _mutate((list) {
    final i = list.indexWhere((e) => e.location.key == location.key);
    if (i >= 0) list[i] = HistoryEntry(location, list[i].lastOpened);
  });

  Future<void> remove(DocLocation location) => _mutate(
    (list) => list.removeWhere((e) => e.location.key == location.key),
  );

  /// Applies [change] to the in-memory list right away (so the UI updates
  /// at once), then — serialized with other writes — re-reads history.json
  /// (another app instance may have written it since we loaded), applies
  /// [change] to that, and writes the result atomically (temp + rename).
  Future<void> _mutate(void Function(List<HistoryEntry> list) change) async {
    if (!_loaded) await load();
    change(_entries);
    notifyListeners();
    return _saving = _saving.then((_) async {
      try {
        final disk = await _readDisk();
        if (disk != null) {
          change(disk);
          _entries = disk;
          notifyListeners();
        }
        final snapshot = jsonEncode(_entries.map((e) => e.toJson()).toList());
        final f = await _file;
        await f.parent.create(recursive: true);
        final tmp = File('${f.path}.tmp');
        await tmp.writeAsString(snapshot, flush: true);
        await tmp.rename(f.path);
      } catch (_) {}
    });
  }
}
