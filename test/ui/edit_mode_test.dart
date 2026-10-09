import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfedit/core/pdf_core.dart';
import 'package:pdfedit/services/doc_session.dart';
import 'package:pdfedit/services/history_store.dart';
import 'package:pdfedit/services/settings_store.dart';
import 'package:pdfedit/ui/viewer/viewer_screen.dart';
import 'package:pdfrx/pdfrx.dart' as rx;

import 'fakes.dart';

/// One letter page that renders nothing (page pixels need PDFium).
class _FakePage implements rx.PdfPage {
  @override
  double get width => 612;
  @override
  double get height => 792;
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
  final _pages = [_FakePage()];
  @override
  List<rx.PdfPage> get pages => _pages;
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

final viewed = <String>[];

void main() {
  late Directory dir;
  setUp(() async => dir = await tempDir());
  tearDown(() => dir.delete(recursive: true));

  Future<(DocSession, FakeEditDoc)> pumpOpen(
    WidgetTester t,
    List<PdfField> fields, {
    PdfCoreException? failWith,
  }) async {
    final edit = FakeEditDoc(fields, failWith: failWith);
    viewed.clear();
    final session = DocSession(
      openView: (b, _) async {
        viewed.add(String.fromCharCodes(b));
        return _FakeView();
      },
      openEdit: (_, _) => edit,
    );
    final history = HistoryStore(() async => dir);
    await t.runAsync(history.load);
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
      location: loc('form.pdf'),
      askPassword: (_) async => null,
    );
    await t.pumpAndSettle();
    return (session, edit);
  }

  testWidgets('Edit with no fields shows ✓, Fields and the hint', (t) async {
    await pumpOpen(t, const []);
    expect(find.text('form.pdf'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('edit-button')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('done-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('fields-button')), findsOneWidget);
    expect(find.text('form.pdf'), findsOneWidget);
    expect(find.textContaining('No fillable fields'), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('fields-button')));
    await t.pumpAndSettle();
    expect(find.text('Text box'), findsOneWidget);
    expect(find.text('Checkbox'), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('done-button')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('edit-button')), findsOneWidget);
  });

  const name = PdfField(
    id: '5 0',
    fullName: 'Name',
    kind: PdfFieldKind.text,
    pageIndex: 0,
    rect: PdfRect(72, 72, 200, 20),
    value: 'Old',
  );

  Future<void> typeInField(WidgetTester t) async {
    await t.tap(find.byKey(const ValueKey('edit-button')));
    await t.pumpAndSettle();
    expect(find.textContaining('No fillable fields'), findsNothing);
    await t.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('text:5 0')),
        matching: find.byType(TextField),
      ),
      'New name',
    );
    await t.pumpAndSettle();
  }

  testWidgets('✓ applies field values through the core', (t) async {
    final (session, edit) = await pumpOpen(t, const [name]);
    await typeInField(t);
    expect(find.byKey(const ValueKey('dirty-dot')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('done-button')));
    await t.pumpAndSettle();
    final change = edit.applied.single.single as SetFieldValue;
    expect(change.fieldId, '5 0');
    expect(change.value, 'New name');
    expect(session.dirty, isTrue);
    expect(find.byKey(const ValueKey('edit-button')), findsOneWidget);
    await t.pump(const Duration(seconds: 1)); // old view doc disposal timer
  });

  testWidgets('unsupported characters show the inline note', (t) async {
    await pumpOpen(t, const [name]);
    await t.tap(find.byKey(const ValueKey('edit-button')));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'Ωmega “quoted” €5');
    await t.pumpAndSettle();
    expect(find.textContaining('saved as ?'), findsOneWidget);
    await t.enterText(find.byType(TextField), '“quoted” €5 – ok');
    await t.pumpAndSettle();
    expect(find.textContaining('saved as ?'), findsNothing);
  });

  testWidgets('text that would not fit shows the overflow note', (t) async {
    final (_, edit) = await pumpOpen(t, const [name]);
    edit.overflowing.add('5 0');
    await t.tap(find.byKey(const ValueKey('edit-button')));
    await t.pumpAndSettle();
    expect(find.textContaining("Doesn't fit"), findsNothing);
    await t.enterText(find.byType(TextField), 'much too long');
    await t.pumpAndSettle();
    expect(find.text("Doesn't fit — extra text won't show"), findsOneWidget);
    await t.enterText(find.byType(TextField), 'ok');
    await t.pumpAndSettle();
    expect(find.textContaining("Doesn't fit"), findsNothing);
  });

  testWidgets('tapping the edge of a field box focuses the field', (t) async {
    const tall = PdfField(
      id: '7 0',
      fullName: 'Notes',
      kind: PdfFieldKind.text,
      pageIndex: 0,
      rect: PdfRect(72, 200, 200, 60),
      value: '',
    );
    await pumpOpen(t, const [tall]);
    await t.tap(find.byKey(const ValueKey('edit-button')));
    await t.pumpAndSettle();
    final box = t.getRect(find.byKey(const ValueKey('text:7 0')));
    // Just inside the bottom-right corner: outside the single text line.
    await t.tapAt(box.bottomRight - const Offset(3, 3));
    await t.pumpAndSettle();
    final field = t.widget<TextField>(find.byType(TextField));
    expect(field.focusNode!.hasFocus, isTrue);
    await t.pump(const Duration(seconds: 1));
  });

  testWidgets('core errors show inline in the bar; edit mode stays', (t) async {
    await pumpOpen(t, const [
      name,
    ], failWith: const PdfCoreException('Field not found'));
    await typeInField(t);
    await t.tap(find.byKey(const ValueKey('done-button')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('edit-error')), findsOneWidget);
    expect(find.text('Field not found'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byKey(const ValueKey('done-button')), findsOneWidget);
  });

  testWidgets('viewer shows displayBytes; opening is not dirty', (t) async {
    final (session, edit) = await pumpOpen(t, const [name]);
    expect(viewed.last, '%PDF-1.7 display');
    expect(session.bytes, isNot(edit.displayBytes));
    expect(session.dirty, isFalse);
    expect(find.byKey(const ValueKey('dirty-dot')), findsNothing);
    await t.pump(const Duration(seconds: 1));
  });

  testWidgets('rotated fields get a rotated fill control', (t) async {
    const side = PdfField(
      id: '9 0',
      fullName: 'Side',
      kind: PdfFieldKind.text,
      pageIndex: 0,
      rect: PdfRect(40, 100, 20, 160),
      value: 'sideways',
      rotation: 90,
    );
    await pumpOpen(t, const [side]);
    await t.tap(find.byKey(const ValueKey('edit-button')));
    await t.pumpAndSettle();
    final box = t.widget<RotatedBox>(
      find.ancestor(
        of: find.byKey(const ValueKey('text:9 0')),
        matching: find.byType(RotatedBox),
      ),
    );
    expect(box.quarterTurns, 1);
    // Laid out along the text direction: long side horizontal before turning.
    final size = t.getSize(find.byKey(const ValueKey('text:9 0')));
    expect(size.width, greaterThan(size.height));
    await t.pump(const Duration(seconds: 1));
  });
}
