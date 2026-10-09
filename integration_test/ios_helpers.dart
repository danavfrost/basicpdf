// Shared helpers for the iOS QA integration tests (integration_test/ios_*).
//
// Screenshots: `shot()` drops `<tmp>/shots/<name>.req` in the app container;
// an external watcher (simctl io screenshot) takes the picture and deletes
// the request file. Without a watcher, `shot()` times out after a few
// seconds and the test carries on.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfedit/main.dart';
import 'package:pdfedit/services/doc_session.dart';
import 'package:pdfedit/services/file_service.dart';
import 'package:pdfedit/services/history_store.dart';
import 'package:pdfedit/services/settings_store.dart';

class QaApp {
  late final DocSession session;
  late final HistoryStore history;
  late final SettingsStore settings;
  late final PlatformFileService files;
}

/// Starts the real app (same wiring as main()) and keeps handles to its
/// services so tests can inspect the document bytes.
Future<QaApp> startApp(WidgetTester t) async {
  final qa = QaApp();
  qa.settings = SettingsStore(getApplicationSupportDirectory);
  await qa.settings.load();
  qa.session = DocSession();
  qa.history = HistoryStore(getApplicationSupportDirectory);
  qa.files = PlatformFileService();
  await t.pumpWidget(
    PdfEditApp(
      session: qa.session,
      history: qa.history,
      files: qa.files,
      settings: qa.settings,
    ),
  );
  await wait(t, 1500);
  return qa;
}

Future<void> wait(WidgetTester t, int ms) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// Pumps until [f] finds something (or throws after [timeoutMs]).
Future<void> until(WidgetTester t, Finder f, {int timeoutMs = 15000}) async {
  final end = DateTime.now().add(Duration(milliseconds: timeoutMs));
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 50));
    if (f.evaluate().isNotEmpty) return;
  }
  throw TestFailure('Timed out waiting for $f');
}

Future<void> shot(WidgetTester t, String name, {int settleMs = 600}) async {
  await wait(t, settleMs);
  final dir = Directory('${(await getTemporaryDirectory()).path}/shots');
  await dir.create(recursive: true);
  final req = File('${dir.path}/$name.req');
  await req.writeAsString('1');
  final end = DateTime.now().add(const Duration(seconds: 8));
  while (await req.exists() && DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

File? _logFile;

/// Logs to the console and to Library/Caches/qa_log.txt (readable from the
/// host when the test app is launched standalone via simctl).
void log(String s) {
  debugPrint('[QA] $s');
  try {
    _logFile ??= File(
      '${Directory.systemTemp.parent.path}/Library/Caches/qa_log.txt',
    );
    _logFile!.writeAsStringSync(
      '[QA] ${DateTime.now().toIso8601String().substring(11, 23)} $s\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {}
}

/// testWidgets that logs PASS/FAIL (with the error) to the QA log.
void qaTest(String name, Future<void> Function(WidgetTester t) body) {
  testWidgets(name, (t) async {
    // Optional filter: Library/Caches/qa_only.txt with one substring per line.
    final only = File(
      '${Directory.systemTemp.parent.path}/Library/Caches/qa_only.txt',
    );
    if (only.existsSync()) {
      final keys = only.readAsLinesSync().where((l) => l.trim().isNotEmpty);
      if (keys.isNotEmpty && !keys.any(name.contains)) {
        log('SKIP $name');
        return;
      }
    }
    log('START $name');
    try {
      await body(t);
      log('PASS $name');
    } catch (e, st) {
      log('FAIL $name: $e\n$st');
      rethrow;
    }
  });
}

void qaDone() => tearDownAll(() => log('ALLDONE'));

Future<String> docsDir() async =>
    (await getApplicationDocumentsDirectory()).path;

/// Opens Documents/`path` through Open ▸ Browse.
Future<void> openFromBrowse(WidgetTester t, List<String> path) async {
  final home = find.byKey(const ValueKey('home-open'));
  if (home.evaluate().isNotEmpty) {
    await t.tap(home);
  } else {
    await t.tap(find.byKey(const ValueKey('overflow-menu')));
    await wait(t, 500);
    await t.tap(find.text('Open'));
  }
  await wait(t, 800);
  await t.tap(find.text('Browse'));
  await wait(t, 1200);
  for (final p in path) {
    await until(t, find.byType(ListTile));
    await t.dragUntilVisible(
      find.text(p),
      find.byType(ListView).last,
      const Offset(0, -250),
    );
    await wait(t, 300);
    await t.tap(find.text(p).last);
    await wait(t, 800);
  }
}

Future<void> menu(WidgetTester t, String item) async {
  await t.tap(find.byKey(const ValueKey('overflow-menu')));
  await wait(t, 600);
  await t.tap(find.text(item).last);
  await wait(t, 600);
}

Finder byTypeName(String name) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == name);
