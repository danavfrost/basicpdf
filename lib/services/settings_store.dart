import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

/// Tiny app settings (currently only the theme choice), persisted as JSON
/// in `settings.json` next to the history in the app support dir.
///
/// Until the user toggles Dark mode the app follows the system setting.
class SettingsStore extends ValueNotifier<ThemeMode> {
  SettingsStore(this._dir) : super(ThemeMode.system);

  final Future<Directory> Function() _dir;
  Future<void> _saving = Future.value();

  Future<File> get _file async => File('${(await _dir()).path}/settings.json');

  ThemeMode get themeMode => value;

  Future<void> load() async {
    try {
      final f = await _file;
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString());
      if (j is Map && j['dark'] is bool) {
        value = j['dark'] == true ? ThemeMode.dark : ThemeMode.light;
      }
    } catch (_) {
      // Unreadable settings: keep following the system.
    }
  }

  /// Sets an explicit light/dark choice and persists it.
  Future<void> setDark(bool dark) {
    value = dark ? ThemeMode.dark : ThemeMode.light;
    final snapshot = jsonEncode({'dark': dark});
    return _saving = _saving.then((_) async {
      try {
        final f = await _file;
        await f.parent.create(recursive: true);
        final tmp = File('${f.path}.tmp');
        await tmp.writeAsString(snapshot, flush: true);
        await tmp.rename(f.path);
      } catch (_) {}
    });
  }
}
