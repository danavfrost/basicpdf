import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfedit/core/pdf_core.dart';
import 'package:pdfedit/services/doc_session.dart';
import 'package:pdfedit/services/history_store.dart';
import 'package:pdfedit/services/reading_positions.dart';
import 'package:pdfedit/services/settings_store.dart';
import 'package:pdfedit/ui/viewer/pages_view.dart';
import 'package:pdfedit/ui/viewer/viewer_screen.dart';
import 'package:pdfrx/pdfrx.dart' as rx;

import 'fakes.dart';

class _FakePage implements rx.PdfPage {
  @override
  double get width => 612;
  @override
  double get height => 792;
  @override
  bool get isLoaded => true;
  @override
  Future<rx.PdfImage?> render({
    int x = 0,
    int y = 0,
    int? width,
    int? height,
    double? fullWidth,
    double? fullHeight,
    int? backgroundColor,
    rx.PdfPageRotation? rotationOverride,
    rx.PdfAnnotationRenderingMode annotationRenderingMode =
        rx.PdfAnnotationRenderingMode.annotationAndForms,
    int flags = rx.PdfPageRenderFlags.none,
    rx.PdfPageRenderCancellationToken? cancellationToken,
  }) async => null;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeView implements rx.PdfDocument {
  _FakeView(int n) : _pages = List.generate(n, (_) => _FakePage());
  final List<rx.PdfPage> _pages;
  @override
  List<rx.PdfPage> get pages => _pages;
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Lets real file IO started from the widget test finish.
Future<void> flushIo(WidgetTester t) async {
  for (var i = 0; i < 40; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump();
  }
}

void main() {
  group('ReadingPositions', () {
    late Directory dir;
    setUp(() async => dir = await tempDir());
    tearDown(() => dir.delete(recursive: true));

    test('persists per key; page count must match', () async {
      final a = ReadingPositions(() async => dir);
      await a.set('k1', const ReadingPosition(12, 0.25, 40));
      await a.set('k2', const ReadingPosition(3, 0.9, 5));
      final b = ReadingPositions(() async => dir);
      await b.load();
      expect(b.get('k1', 40), const ReadingPosition(12, 0.25, 40));
      expect(b.get('k2', 5)?.page, 3);
      // A different document now lives at that location.
      expect(b.get('k1', 39), isNull);
      expect(b.get('nope', 40), isNull);
      expect(File('${dir.path}/positions.json.tmp').existsSync(), isFalse);
    });

    test('out-of-range or corrupt positions are ignored', () async {
      File('${dir.path}/positions.json').writeAsStringSync(
        '{"a":{"page":50,"fraction":0.1,"pages":40,"at":"2026-01-01"},'
        '"b":{"page":"x"},"c":{"page":1,"fraction":0.5,"pages":4,'
        '"at":"2026-01-01"}}',
      );
      final s = ReadingPositions(() async => dir);
      await s.load();
      expect(s.get('a', 40), isNull);
      expect(s.get('b', 40), isNull);
      expect(s.get('c', 4)?.fraction, 0.5);

      File('${dir.path}/positions.json').writeAsStringSync('{not json');
      final s2 = ReadingPositions(() async => dir);
      await s2.load();
      expect(s2.get('c', 4), isNull);
      await s2.set('d', const ReadingPosition(0, 0, 1));
      expect(s2.get('d', 1), isNotNull);
    });

    test('merges with another instance and keeps the newest entries', () async {
      var clock = DateTime(2026);
      DateTime now() => clock = clock.add(const Duration(seconds: 1));
      final a = ReadingPositions(() async => dir, now: now);
      final b = ReadingPositions(() async => dir, now: now);
      await a.load();
      await b.load();
      await a.set('from-a', const ReadingPosition(1, 0, 9));
      await b.set('from-b', const ReadingPosition(2, 0, 9));
      final c = ReadingPositions(() async => dir);
      await c.load();
      expect(c.get('from-a', 9), isNotNull);
      expect(c.get('from-b', 9), isNotNull);

      for (var i = 0; i < ReadingPositions.maxEntries + 5; i++) {
        await a.set('k$i', ReadingPosition(i % 3, 0, 3));
      }
      final d = ReadingPositions(() async => dir);
      await d.load();
      expect(d.get('k0', 3), isNull, reason: 'oldest dropped');
      expect(d.get('k${ReadingPositions.maxEntries + 4}', 3), isNotNull);
    });

    test('removing a file from History forgets its position', () async {
      final positions = ReadingPositions(() async => dir);
      final history = HistoryStore(() async => dir, positions: positions);
      final f = loc('a.pdf');
      await history.touch(f);
      await positions.set(f.key, const ReadingPosition(7, 0.5, 10));
      await history.remove(f);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final again = ReadingPositions(() async => dir);
      await again.load();
      expect(again.get(f.key, 10), isNull);
    });
  });

  group('Viewer', () {
    late Directory dir;
    setUp(() async => dir = await tempDir());
    tearDown(() => dir.delete(recursive: true));

    Future<(DocSession, ReadingPositions, _FakeView)> pumpViewer(
      WidgetTester t, {
      ReadingPosition? saved,
      int pages = 40,
    }) async {
      final view = _FakeView(pages);
      final session = DocSession(
        openView: (_, _) async => view,
        openEdit: (_, _) => throw const PdfCoreException('no core'),
      );
      final positions = ReadingPositions(() async => dir);
      final history = HistoryStore(() async => dir, positions: positions);
      await t.runAsync(() async {
        await history.load();
        if (saved != null) await positions.set(loc('long.pdf').key, saved);
      });
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
      await session.open(
        Uint8List(4),
        location: loc('long.pdf'),
        askPassword: (_) async => null,
      );
      await t.pumpAndSettle();
      return (session, positions, view);
    }

    /// Index of the page crossing the line [y] (global).
    int pageAt(WidgetTester t, _FakeView view, double y) {
      for (final e in find.byType(PdfPageImage).evaluate()) {
        final w = e.widget as PdfPageImage;
        final r = t.getRect(find.byWidget(w));
        if (r.top <= y && r.bottom > y) return view.pages.indexOf(w.page);
      }
      return -1;
    }

    /// Bottom of the top bar's space (where the reading line is), whether
    /// or not the bar is slid away right now.
    double barBottom(WidgetTester t) =>
        t.getSize(find.byKey(const ValueKey('auto-hide-bar'))).height;

    testWidgets('reopening a file comes back at the saved spot', (t) async {
      final (session, positions, view) = await pumpViewer(
        t,
        saved: const ReadingPosition(25, 0.5, 40),
      );
      final line = barBottom(t) + 1;
      expect(pageAt(t, view, line), 25);
      final r = t.getRect(
        find.byWidgetPredicate(
          (w) => w is PdfPageImage && identical(w.page, view.pages[25]),
        ),
      );
      expect((line - r.top) / (r.height + 8), closeTo(0.5, 0.03));

      // Read on, then close: the new spot is remembered.
      await t.drag(find.byType(PagesView), const Offset(0, -900));
      await t.pumpAndSettle();
      final now = pageAt(t, view, barBottom(t) + 1);
      expect(now, greaterThan(25));
      session.close();
      await t.pumpAndSettle();
      expect(positions.get(loc('long.pdf').key, 40)?.page, now);
      await flushIo(t);
      final again = ReadingPositions(() async => dir);
      await t.runAsync(again.load);
      expect(again.get(loc('long.pdf').key, 40)?.page, now);
      await t.pump(const Duration(seconds: 1)); // old document disposed
    });

    testWidgets('a position saved for a different page count is ignored', (
      t,
    ) async {
      final (_, _, view) = await pumpViewer(
        t,
        saved: const ReadingPosition(25, 0.5, 41),
      );
      expect(pageAt(t, view, barBottom(t) + 9), 0);
    });

    testWidgets('scroll idle saves the position (app may be killed)', (
      t,
    ) async {
      final (_, positions, view) = await pumpViewer(t);
      await t.drag(find.byType(PagesView), const Offset(0, -1500));
      await t.pumpAndSettle();
      await t.pump(const Duration(milliseconds: 600));
      await flushIo(t);
      final page = pageAt(t, view, barBottom(t) + 1);
      expect(positions.get(loc('long.pdf').key, 40)?.page, page);
      final disk = ReadingPositions(() async => dir);
      await t.runAsync(disk.load);
      expect(disk.get(loc('long.pdf').key, 40)?.page, page);
    });
  });
}
