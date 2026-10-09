// Small fields on a phone: generous tap targets, zoom-to-field policy,
// keyboard "Next" in reading order.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfedit/core/pdf_core.dart';
import 'package:pdfedit/ui/edit/edit_session.dart';
import 'package:pdfedit/ui/edit/fill_overlay.dart';

import 'fakes.dart';

PdfField text(
  String id,
  double l,
  double t,
  double w,
  double h, {
  int page = 0,
  PdfFieldKind kind = PdfFieldKind.text,
}) => PdfField(
  id: id,
  fullName: id,
  kind: kind,
  pageIndex: page,
  rect: PdfRect(l, t, w, h),
);

PdfField check(String id, double l, double t, [double size = 6]) => PdfField(
  id: id,
  fullName: id,
  kind: PdfFieldKind.checkbox,
  pageIndex: 0,
  rect: PdfRect(l, t, size, size),
  value: 'Off',
  onValue: 'Yes',
);

List<String> ids(List<PdfField> l) => [for (final f in l) f.id];

void main() {
  group('readingOrder', () {
    test('a grid form reads row by row', () {
      final fields = [
        text('last', 300, 100, 200, 20),
        text('city', 300, 140, 200, 20),
        text('first', 50, 100, 200, 20),
        text('street', 50, 140, 200, 20),
        text('zip', 50, 180, 200, 20),
        text('phone', 300, 180, 200, 20),
      ];
      expect(ids(readingOrder(fields)), [
        'first',
        'last',
        'street',
        'city',
        'zip',
        'phone',
      ]);
    });

    test('independent columns read one column at a time, header first', () {
      final fields = [
        // header row
        text('name', 40, 40, 200, 20),
        text('class', 300, 40, 200, 20),
        // left column: boxes every 30 pt; right column offset by 13 pt
        for (var i = 0; i < 6; i++) text('L$i', 40, 120.0 + i * 30, 120, 12),
        for (var i = 0; i < 6; i++) text('R$i', 300, 133.0 + i * 30, 120, 12),
      ];
      expect(ids(readingOrder(fields)), [
        'name',
        'class',
        for (var i = 0; i < 6; i++) 'L$i',
        for (var i = 0; i < 6; i++) 'R$i',
      ]);
    });

    test('pages in order; rows tolerate small misalignment', () {
      final fields = [
        text('p1', 50, 50, 100, 20, page: 1),
        text('b', 200, 52, 100, 18),
        text('a', 50, 50, 100, 20),
      ];
      expect(ids(readingOrder(fields)), ['a', 'b', 'p1']);
    });
  });

  group('fieldTargetAt', () {
    // Two proficiency dots 13 pt apart at 0.65 px/pt: their 32 px targets
    // overlap; the nearer one wins. A text box beside them too.
    final a = check('a', 100, 100);
    final b = check('b', 100, 113);
    final box = text('box', 112, 99, 14, 8.6);
    const k = 0.65;
    Offset at(double x, double y) => Offset(x * k, y * k);

    test('a tap a little off a tiny dot still hits it', () {
      expect(fieldTargetAt([a, b], at(97, 103), k)?.id, 'a');
      expect(fieldTargetAt([a, b], at(103, 121), k)?.id, 'b');
    });

    test('between two dots, the nearer one wins', () {
      expect(fieldTargetAt([a, b], at(103, 108.4), k)?.id, 'a');
      expect(fieldTargetAt([a, b], at(103, 110.6), k)?.id, 'b');
    });

    test("a field's own box beats a neighbour's grown target", () {
      expect(fieldTargetAt([a, b, box], at(113, 103), k)?.id, 'box');
    });

    test('far from every field: nothing', () {
      expect(fieldTargetAt([a, b, box], at(200, 300), k), isNull);
    });
  });

  group('comfortableZoom', () {
    test('tiny text zooms in, capped', () {
      final z = comfortableZoom(
        fontPt: 6.4,
        fieldWidthPt: 14.4,
        basePointScale: 0.645,
        currentZoom: 1,
        viewWidth: 411,
      )!;
      expect(z * 0.645 * 6.4, closeTo(comfortableTextHeight, 0.01));
      expect(
        comfortableZoom(
          fontPt: 4,
          fieldWidthPt: 14,
          basePointScale: 0.645,
          currentZoom: 1,
          viewWidth: 411,
        ),
        maxFieldZoom,
      );
    });

    test('already comfortable: keep the zoom', () {
      expect(
        comfortableZoom(
          fontPt: 6.4,
          fieldWidthPt: 14.4,
          basePointScale: 0.645,
          currentZoom: 3,
          viewWidth: 411,
        ),
        isNull,
      );
      expect(
        comfortableZoom(
          fontPt: 12,
          fieldWidthPt: 100,
          basePointScale: 1.5,
          currentZoom: 1,
          viewWidth: 900,
        ),
        isNull,
      );
    });

    test('a wide field stays within the view width', () {
      final z = comfortableZoom(
        fontPt: 12,
        fieldWidthPt: 468,
        basePointScale: 0.645,
        currentZoom: 1,
        viewWidth: 411,
      )!;
      expect(468 * 0.645 * z, lessThanOrEqualTo(411 - 24 + 1e-6));
    });
  });

  group('overlay', () {
    Future<EditSession> pump(
      WidgetTester t,
      List<PdfField> fields, {
      double scale = 0.65,
    }) async {
      final s = EditSession(FakeEditDoc(fields));
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 612 * scale,
                height: 792 * scale,
                child: FillOverlay(session: s, pageIndex: 0, scale: scale),
              ),
            ),
          ),
        ),
      );
      return s;
    }

    testWidgets('a checkbox looks like its PDF: nothing drawn when off, the '
        "PDF's mark when on", (t) async {
      const dot = PdfField(
        id: 'dot',
        fullName: 'dot',
        kind: PdfFieldKind.checkbox,
        pageIndex: 0,
        rect: PdfRect(100, 100, 9.3, 12.2),
        value: 'Off',
        onValue: 'Yes',
        checkMark: PdfCheckMark(glyph: 'l', size: 6.6, x: 2, y: 8.3),
      );
      final s = await pump(t, [dot], scale: 2);
      Iterable<CheckMarkPainter> marks() => t
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((c) => c.painter)
          .whereType<CheckMarkPainter>();
      // No box, border or fill of our own over the printed circle.
      final boxes = t
          .widgetList<Container>(find.byType(Container))
          .where((c) => c.decoration != null || c.color != null);
      expect(boxes, isEmpty);
      expect(marks(), isEmpty);
      await t.tapAt(const Offset(104.6 * 2, 106 * 2));
      await t.pump();
      expect(s.isChecked(dot), isTrue);
      expect(marks().single.mark.glyph, 'l');
      await t.tapAt(const Offset(104.6 * 2, 106 * 2));
      await t.pump();
      expect(s.isChecked(dot), isFalse);
      expect(marks(), isEmpty);
    });

    testWidgets('tapping beside a tiny checkbox toggles it', (t) async {
      final dot = check('dot', 100, 100);
      final s = await pump(t, [dot]);
      await t.tapAt(const Offset(98 * 0.65 - 8, 103 * 0.65 + 6));
      await t.pump();
      expect(s.isChecked(dot), isTrue);
    });

    testWidgets('tapping beside a small text box focuses it; bare paper '
        'unfocuses', (t) async {
      final box = text('box', 100, 100, 14.4, 8.6);
      final s = await pump(t, [box]);
      PdfField? shown;
      s.onShowField = (f, _) => shown = f;
      await t.tapAt(const Offset(107 * 0.65, 100 * 0.65 - 8));
      await t.pump();
      final field = t.widget<TextField>(find.byType(TextField));
      expect(field.focusNode!.hasFocus, isTrue);
      expect(shown?.id, 'box');
      await t.tapAt(const Offset(400 * 0.65, 600 * 0.65));
      await t.pump();
      expect(field.focusNode!.hasFocus, isFalse);
    });

    testWidgets('keyboard Next moves through fields in reading order; the '
        'last one says Done', (t) async {
      final fields = [
        text('b', 300, 100, 150, 20),
        text('a', 50, 100, 150, 20),
        text('c', 50, 140, 150, 20),
        text('notes', 50, 180, 400, 80, kind: PdfFieldKind.multilineText),
      ];
      final s = await pump(t, fields, scale: 1);
      final shown = <String>[];
      s.onShowField = (f, _) => shown.add(f.id);
      TextField tf(String id) => t.widget<TextField>(
        find.descendant(
          of: find.byKey(ValueKey('text:$id')),
          matching: find.byType(TextField),
        ),
      );
      expect(tf('a').textInputAction, TextInputAction.next);
      expect(tf('notes').textInputAction, TextInputAction.newline);
      await t.tap(find.byKey(const ValueKey('text:a')));
      await t.pump();
      expect(tf('a').focusNode!.hasFocus, isTrue);
      await t.testTextInput.receiveAction(TextInputAction.next);
      await t.pump();
      expect(tf('b').focusNode!.hasFocus, isTrue);
      await t.testTextInput.receiveAction(TextInputAction.next);
      await t.pump();
      expect(tf('c').focusNode!.hasFocus, isTrue);
      await t.testTextInput.receiveAction(TextInputAction.next);
      await t.pump();
      expect(tf('notes').focusNode!.hasFocus, isTrue);
      expect(shown, ['a', 'b', 'c', 'notes']);
    });

    testWidgets('Next to a field not built yet asks to show it, then '
        'focuses it once built', (t) async {
      final a = text('a', 50, 100, 150, 20);
      final far = text('far', 50, 100, 150, 20, page: 1);
      final s = await pump(t, [a, far], scale: 1);
      final shown = <String>[];
      s.onShowField = (f, _) => shown.add(f.id);
      final tfa = t.widget<TextField>(find.byType(TextField));
      expect(tfa.textInputAction, TextInputAction.next);
      s.focusField(far);
      expect(shown, ['far']);
      // Page 1's overlay appears (scrolled into view).
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 612,
              height: 792,
              child: FillOverlay(session: s, pageIndex: 1, scale: 1),
            ),
          ),
        ),
      );
      await t.pump();
      final tff = t.widget<TextField>(find.byType(TextField));
      expect(tff.focusNode!.hasFocus, isTrue);
      expect(tff.textInputAction, TextInputAction.done);
    });
  });
}
