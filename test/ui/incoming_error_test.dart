import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfedit/main.dart';
import 'package:pdfedit/services/doc_session.dart';
import 'package:pdfedit/services/history_store.dart';
import 'package:pdfedit/services/settings_store.dart';

import 'fakes.dart';

void main() {
  testWidgets('a PDF shared without access shows a message, not a crash', (
    t,
  ) async {
    final dir = await t.runAsync(tempDir);
    final settings = SettingsStore(() async => dir!);
    final history = HistoryStore(() async => dir!);
    await t.runAsync(() async {
      await settings.load();
      await history.load();
    });
    final files = FakeFileService()
      ..initialError = PlatformException(code: 'io', message: 'no access');
    await t.pumpWidget(
      PdfEditApp(
        session: DocSession(),
        history: history,
        files: files,
        settings: settings,
      ),
    );
    await t.pumpAndSettle();
    expect(find.text("Couldn't open that file."), findsOneWidget);
    expect(find.byKey(const ValueKey('home-new')), findsOneWidget);
    await t.runAsync(() => dir!.delete(recursive: true));
  });
}
