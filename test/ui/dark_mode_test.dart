import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfedit/main.dart';
import 'package:pdfedit/services/doc_session.dart';
import 'package:pdfedit/services/history_store.dart';
import 'package:pdfedit/services/settings_store.dart';

import 'fakes.dart';

Future<void> settleIo(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump();
  }
}

void main() {
  late Directory dir;
  setUp(() async => dir = await tempDir());
  tearDown(() => dir.delete(recursive: true));

  Future<SettingsStore> pumpApp(WidgetTester t, Brightness system) async {
    t.platformDispatcher.platformBrightnessTestValue = system;
    addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
    final settings = SettingsStore(() async => dir);
    final history = HistoryStore(() async => dir);
    await t.runAsync(() async {
      await settings.load();
      await history.load();
    });
    await t.pumpWidget(
      PdfEditApp(
        session: DocSession(),
        history: history,
        files: FakeFileService(),
        settings: settings,
      ),
    );
    await t.pumpAndSettle();
    return settings;
  }

  Brightness brightness(WidgetTester t) =>
      Theme.of(t.element(find.byKey(const ValueKey('home-new')))).brightness;

  Future<void> toggle(WidgetTester t) async {
    await t.tap(find.byKey(const ValueKey('overflow-menu')));
    await t.pumpAndSettle();
    await t.tap(find.text('Dark mode'));
    await t.pumpAndSettle();
  }

  testWidgets('first launch follows the system', (t) async {
    await pumpApp(t, Brightness.dark);
    expect(brightness(t), Brightness.dark);
  });

  testWidgets('menu order and checked state', (t) async {
    await pumpApp(t, Brightness.light);
    await t.tap(find.byKey(const ValueKey('overflow-menu')));
    await t.pumpAndSettle();
    final labels = ['New', 'Open', 'Save', 'Save As', 'Dark mode', 'About'];
    final ys = [
      for (final l in labels)
        t
            .getCenter(
              find.descendant(
                of: find.byWidgetPredicate((w) => w is PopupMenuEntry),
                matching: find.text(l),
              ),
            )
            .dy,
    ];
    expect(ys, [...ys]..sort());
    expect(
      t.widget<Switch>(find.byKey(const ValueKey('dark-mode-switch'))).value,
      isFalse,
    );
  });

  testWidgets('toggle switches immediately and persists', (t) async {
    final settings = await pumpApp(t, Brightness.light);
    expect(brightness(t), Brightness.light);

    await toggle(t);
    expect(brightness(t), Brightness.dark);
    expect(settings.themeMode, ThemeMode.dark);
    expect(find.byType(AlertDialog), findsNothing);

    // Let the JSON write finish, then a fresh store reads it back.
    await settleIo(t);
    final reloaded = SettingsStore(() async => dir);
    await t.runAsync(reloaded.load);
    expect(reloaded.themeMode, ThemeMode.dark);

    await toggle(t);
    expect(brightness(t), Brightness.light);
    await settleIo(t);
    final again = SettingsStore(() async => dir);
    await t.runAsync(again.load);
    expect(again.themeMode, ThemeMode.light);
  });

  testWidgets('saved choice overrides the system on next launch', (t) async {
    File('${dir.path}/settings.json').writeAsStringSync('{"dark":false}');
    await pumpApp(t, Brightness.dark);
    expect(brightness(t), Brightness.light);
  });
}
