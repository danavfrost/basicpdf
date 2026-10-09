import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfedit/services/doc_location.dart';
import 'package:pdfedit/services/history_store.dart';
import 'package:pdfedit/ui/open/open_dialog.dart';

import 'fakes.dart';

/// Lets real file IO finish, then rebuilds (no pumpAndSettle: a spinner may run).
Future<void> settleIo(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await t.pump();
  }
}

void main() {
  group('HistoryStore', () {
    test('touch orders newest first, de-duplicates, persists', () async {
      final dir = await tempDir();
      var clock = DateTime(2026, 1, 1);
      final store = HistoryStore(
        () async => dir,
        now: () => clock = clock.add(const Duration(minutes: 1)),
      );
      await store.touch(loc('a.pdf'));
      await store.touch(loc('b.pdf'));
      await store.touch(loc('a.pdf'));
      expect(store.all.map((e) => e.location.name), ['a.pdf', 'b.pdf']);

      final reloaded = HistoryStore(() async => dir);
      await reloaded.load();
      expect(reloaded.all.map((e) => e.location.name), ['a.pdf', 'b.pdf']);
      expect(reloaded.all.first.location.kind, LocationKind.contentUri);
      expect(File('${dir.path}/history.json').existsSync(), isTrue);
      await dir.delete(recursive: true);
    });

    test('recent is capped at 15, history keeps everything', () async {
      final dir = await tempDir();
      final store = HistoryStore(() async => dir);
      for (var i = 0; i < 20; i++) {
        await store.touch(loc('f$i.pdf'));
      }
      expect(store.all, hasLength(20));
      expect(store.recent, hasLength(15));
      expect(store.recent.first.location.name, 'f19.pdf');
      await store.remove(loc('f19.pdf'));
      expect(store.recent.first.location.name, 'f18.pdf');
      await dir.delete(recursive: true);
    });

    test(
      'every change re-reads history.json (another instance wrote it)',
      () async {
        final dir = await tempDir();
        final a = HistoryStore(() async => dir);
        final b = HistoryStore(() async => dir);
        await a.load();
        await b.load();
        await a.touch(loc('from-a.pdf'));
        // b loaded before a wrote; its change must not drop a's entry.
        await b.touch(loc('from-b.pdf'));
        expect(b.all.map((e) => e.location.name), ['from-b.pdf', 'from-a.pdf']);
        await a.remove(loc('from-b.pdf'));
        final c = HistoryStore(() async => dir);
        await c.load();
        expect(c.all.map((e) => e.location.name), ['from-a.pdf']);
        // Written atomically: no temp file left behind.
        expect(File('${dir.path}/history.json.tmp').existsSync(), isFalse);
        await dir.delete(recursive: true);
      },
    );

    test('corrupt file loads as empty', () async {
      final dir = await tempDir();
      File('${dir.path}/history.json').writeAsStringSync('{not json');
      final store = HistoryStore(() async => dir);
      await store.load();
      expect(store.all, isEmpty);
      await dir.delete(recursive: true);
    });
  });

  group('OpenDialog', () {
    late Directory dir;
    late HistoryStore store;

    setUp(() async {
      dir = await tempDir();
      store = HistoryStore(() async => dir);
    });
    tearDown(() => dir.delete(recursive: true));

    Future<OpenRequest?> pumpDialog(
      WidgetTester t,
      FakeFileService files, {
      int tab = 0,
    }) async {
      OpenRequest? result;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await Navigator.of(context).push<OpenRequest>(
                  MaterialPageRoute(
                    builder: (_) => OpenDialog(
                      history: store,
                      files: files,
                      initialTab: tab,
                    ),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      return result;
    }

    testWidgets('has Recent, History and Browse tabs', (t) async {
      await t.runAsync(() => store.load());
      await pumpDialog(t, FakeFileService());
      expect(find.text('Recent'), findsOneWidget);
      expect(find.text('History'), findsOneWidget);
      expect(find.text('Browse'), findsOneWidget);
      expect(find.text('Files you open will appear here.'), findsOneWidget);
    });

    testWidgets('Recent lists entries and opening one pops it', (t) async {
      await t.runAsync(() async {
        await store.touch(loc('old.pdf'));
        await store.touch(loc('new.pdf', folder: 'Documents'));
      });
      OpenRequest? picked;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                picked = await Navigator.of(context).push<OpenRequest>(
                  MaterialPageRoute(
                    builder: (_) =>
                        OpenDialog(history: store, files: FakeFileService()),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      final names = t
          .widgetList<ListTile>(find.byType(ListTile))
          .map((e) => (e.title as Text).data)
          .toList();
      expect(names, ['new.pdf', 'old.pdf']);
      await t.tap(find.text('new.pdf'));
      await t.pumpAndSettle();
      expect(picked?.location.name, 'new.pdf');
    });

    testWidgets('History: search, missing greyed, long-press remove', (
      t,
    ) async {
      await t.runAsync(() async {
        await store.touch(loc('taxes.pdf'));
        await store.touch(loc('gone.pdf'));
        await store.touch(loc('character sheet.pdf'));
      });
      await t.runAsync(() => store.touch(loc('expired.pdf')));
      await pumpDialog(
        t,
        FakeFileService(missing: {'gone.pdf'}, noAccess: {'expired.pdf'}),
        tab: 1,
      );

      expect(find.text('taxes.pdf'), findsOneWidget);
      final gone = t.widget<ListTile>(
        find.ancestor(
          of: find.text('gone.pdf'),
          matching: find.byType(ListTile),
        ),
      );
      expect(gone.onTap, isNull, reason: 'a missing file cannot be opened');
      expect(gone.onLongPress, isNotNull, reason: 'but it can be removed');
      expect(find.textContaining('Missing'), findsOneWidget);
      expect(
        find.textContaining('No access — open it again from Files'),
        findsOneWidget,
      );

      // Missing entries can be removed with a long-press.
      await t.longPress(find.text('gone.pdf'));
      await t.pumpAndSettle();
      await t.tap(find.text('Remove from history'));
      await t.pumpAndSettle();
      expect(find.text('gone.pdf'), findsNothing);
      expect(
        store.all.map((e) => e.location.name),
        isNot(contains('gone.pdf')),
      );

      await t.enterText(find.byType(TextField), 'tax');
      await t.pumpAndSettle();
      expect(find.text('taxes.pdf'), findsOneWidget);
      expect(find.text('character sheet.pdf'), findsNothing);

      await t.longPress(find.text('taxes.pdf'));
      await t.pumpAndSettle();
      expect(find.text('Remove from history'), findsOneWidget);
      await t.tap(find.text('Remove from history'));
      await t.pumpAndSettle();
      expect(find.text('taxes.pdf'), findsNothing);
      expect(
        store.all.map((e) => e.location.name),
        isNot(contains('taxes.pdf')),
      );
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    });

    testWidgets('Browse (Android) launches the system picker', (t) async {
      await t.runAsync(() => store.load());
      final files = FakeFileService(
        picked: PickedDocFixture.make('picked.pdf'),
      );
      OpenRequest? result;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await Navigator.of(context).push<OpenRequest>(
                  MaterialPageRoute(
                    builder: (_) =>
                        OpenDialog(history: store, files: files, initialTab: 2),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.tap(find.text('Browse files…'));
      await t.pumpAndSettle();
      expect(files.pickCalls, 1);
      expect(result?.location.name, 'picked.pdf');
      expect(result?.picked, isNotNull);
    });

    testWidgets('Browse (iOS) lists folders and PDFs only', (t) async {
      await t.runAsync(() async {
        await store.load();
        Directory('${dir.path}/docs/Forms').createSync(recursive: true);
        File('${dir.path}/docs/a.pdf').writeAsStringSync('%PDF');
        File('${dir.path}/docs/notes.txt').writeAsStringSync('x');
        File('${dir.path}/docs/Forms/b.pdf').writeAsStringSync('%PDF');
      });
      final files = FakeFileService(
        hasInAppBrowser: true,
        root: '${dir.path}/docs',
      );
      await t.pumpWidget(
        MaterialApp(
          home: OpenDialog(history: store, files: files, initialTab: 2),
        ),
      );
      await settleIo(t);
      expect(find.text('Forms'), findsOneWidget);
      expect(find.text('a.pdf'), findsOneWidget);
      expect(find.text('notes.txt'), findsNothing);
      expect(find.text('Browse Files…'), findsOneWidget);
      // The breadcrumb has its own line, above the button (not squeezed).
      final crumb = t.getRect(find.byKey(const ValueKey('breadcrumb')));
      final button = t.getRect(find.text('Browse Files…'));
      expect(crumb.bottom, lessThanOrEqualTo(button.top));
      expect(
        t.widget<Text>(find.byKey(const ValueKey('breadcrumb'))).overflow,
        isNot(TextOverflow.ellipsis),
      );

      await t.tap(find.text('Forms'));
      await settleIo(t);
      expect(find.text('b.pdf'), findsOneWidget);
    });
  });
}

class PickedDocFixture {
  static PickedDoc make(String name) =>
      PickedDoc(loc(name), const [37, 80, 68, 70]);
}
