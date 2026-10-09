import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfedit/services/doc_session.dart';
import 'package:pdfedit/services/history_store.dart';
import 'package:pdfedit/services/settings_store.dart';
import 'package:pdfedit/ui/dialogs/unsaved_dialog.dart';
import 'package:pdfedit/ui/viewer/viewer_screen.dart';

import 'fakes.dart';

void main() {
  group('confirmLeave', () {
    Future<(bool?, int)> run(
      WidgetTester t, {
      required bool dirty,
      String? tap,
      bool saveResult = true,
    }) async {
      bool? proceed;
      var saves = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                proceed = await confirmLeave(
                  context,
                  dirty: dirty,
                  title: 'form.pdf',
                  save: () async {
                    saves++;
                    return saveResult;
                  },
                );
              },
              child: const Text('go'),
            ),
          ),
        ),
      );
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      if (tap != null) {
        expect(find.text('Save changes?'), findsOneWidget);
        await t.tap(find.text(tap));
        await t.pumpAndSettle();
      }
      return (proceed, saves);
    }

    testWidgets('clean document proceeds without a dialog', (t) async {
      final (ok, saves) = await run(t, dirty: false);
      expect(find.text('Save changes?'), findsNothing);
      expect(ok, isTrue);
      expect(saves, 0);
    });

    testWidgets('Save saves then proceeds', (t) async {
      final (ok, saves) = await run(t, dirty: true, tap: 'Save');
      expect(ok, isTrue);
      expect(saves, 1);
    });

    testWidgets('failed/cancelled save does not proceed', (t) async {
      final (ok, saves) = await run(
        t,
        dirty: true,
        tap: 'Save',
        saveResult: false,
      );
      expect(ok, isFalse);
      expect(saves, 1);
    });

    testWidgets('Discard proceeds without saving', (t) async {
      final (ok, saves) = await run(t, dirty: true, tap: 'Discard');
      expect(ok, isTrue);
      expect(saves, 0);
    });

    testWidgets('Cancel stays', (t) async {
      final (ok, saves) = await run(t, dirty: true, tap: 'Cancel');
      expect(ok, isFalse);
      expect(saves, 0);
    });
  });

  group('ViewerScreen guard (New draft)', () {
    late Directory dir;
    setUp(() async => dir = await tempDir());
    tearDown(() => dir.delete(recursive: true));

    Future<DocSession> pumpViewer(WidgetTester t) async {
      final session = DocSession();
      final history = HistoryStore(() async => dir);
      await t.runAsync(() => history.load());
      await t.pumpWidget(
        MaterialApp(
          home: ViewerScreen(
            session: session,
            history: history,
            files: FakeFileService(),
            settings: SettingsStore(() async => dir),
          ),
        ),
      );
      await t.pumpAndSettle();
      return session;
    }

    /// Home → New, then put text in the draft (as typing would) without
    /// staying in edit mode (✓ needs the PDF core, which isn't used here).
    Future<void> dirtyDraft(WidgetTester t, DocSession s) async {
      await t.tap(find.byKey(const ValueKey('home-new')));
      await t.pumpAndSettle();
      s.draftText = 'Some words';
      await t.pumpAndSettle();
    }

    Future<void> menuNew(WidgetTester t) async {
      await t.tap(find.byKey(const ValueKey('overflow-menu')));
      await t.pumpAndSettle();
      await t.tap(find.text('New'));
      await t.pumpAndSettle();
    }

    testWidgets('typing in a draft shows the dirty dot', (t) async {
      final s = await pumpViewer(t);
      expect(find.byKey(const ValueKey('home-open')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('home-new')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('dirty-dot')), findsNothing);
      await t.tap(find.byKey(const ValueKey('edit-button')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('draft-field')), 'Hello');
      await t.pumpAndSettle();
      expect(s.draftText, 'Hello');
      expect(find.byKey(const ValueKey('dirty-dot')), findsOneWidget);
    });

    testWidgets('New on a dirty draft asks; Cancel keeps it', (t) async {
      final s = await pumpViewer(t);
      await dirtyDraft(t, s);
      await menuNew(t);
      expect(find.text('Save changes?'), findsOneWidget);
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(s.draftText, 'Some words');
    });

    testWidgets('New on a dirty draft; Discard starts fresh', (t) async {
      final s = await pumpViewer(t);
      await dirtyDraft(t, s);
      await menuNew(t);
      await t.tap(find.text('Discard'));
      await t.pumpAndSettle();
      expect(s.isDraft, isTrue);
      expect(s.draftText, isEmpty);
    });

    testWidgets('Open on a clean draft does not ask', (t) async {
      final s = await pumpViewer(t);
      await t.tap(find.byKey(const ValueKey('home-new')));
      await t.pumpAndSettle();
      expect(s.dirty, isFalse);
      await t.tap(find.byKey(const ValueKey('overflow-menu')));
      await t.pumpAndSettle();
      await t.tap(find.text('Open'));
      await t.pumpAndSettle();
      expect(find.text('Save changes?'), findsNothing);
      expect(find.text('Browse'), findsOneWidget); // Open dialog is up
    });

    testWidgets('back from a dirty document asks; Discard returns Home', (
      t,
    ) async {
      final s = await pumpViewer(t);
      await dirtyDraft(t, s);
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.text('Save changes?'), findsOneWidget);
      await t.tap(find.text('Discard'));
      await t.pumpAndSettle();
      expect(s.hasDocument, isFalse);
      expect(find.byKey(const ValueKey('home-new')), findsOneWidget);
    });

    testWidgets('back with Cancel stays on the document', (t) async {
      final s = await pumpViewer(t);
      await dirtyDraft(t, s);
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(s.hasDocument, isTrue);
    });
  });
}
