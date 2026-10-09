import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'services/doc_session.dart';
import 'services/file_service.dart';
import 'services/history_store.dart';
import 'services/settings_store.dart';
import 'ui/viewer/viewer_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Bundled field fonts (SIL Open Font License) show under About ▸ Licenses.
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Liberation Fonts',
    ], await rootBundle.loadString('assets/fonts/LICENSE-Liberation.txt'));
  });
  final settings = SettingsStore(getApplicationSupportDirectory);
  // Tiny local JSON read so the first frame already has the right theme.
  await settings.load();
  // Recent list: loaded in parallel with the first frame, not before it.
  final history = HistoryStore(getApplicationSupportDirectory)..load();
  runApp(
    PdfEditApp(
      session: DocSession(),
      history: history,
      files: PlatformFileService(),
      settings: settings,
    ),
  );
}

class PdfEditApp extends StatelessWidget {
  const PdfEditApp({
    super.key,
    required this.session,
    required this.history,
    required this.files,
    required this.settings,
  });

  final DocSession session;
  final HistoryStore history;
  final FileService files;
  final SettingsStore settings;

  static const _seed = Color(0xFFC62828);

  static ThemeData theme(Brightness b) => ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: _seed, brightness: b),
  );

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: settings,
      builder: (context, mode, _) => MaterialApp(
        title: 'Basic PDF',
        debugShowCheckedModeBanner: false,
        theme: theme(Brightness.light),
        darkTheme: theme(Brightness.dark),
        themeMode: mode,
        home: ViewerScreen(
          session: session,
          history: history,
          files: files,
          settings: settings,
        ),
      ),
    );
  }
}
