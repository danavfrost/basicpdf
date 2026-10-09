import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfedit/ui/viewer/pages_view.dart';

final _sizes = List<Size>.filled(60, const Size(612, 792));

Widget _app(
  double width, {
  PageOverlayBuilder? overlay,
  PagesController? controller,
}) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
        height: 600,
        child: PagesView(
          pageSizes: _sizes,
          overlayBuilder: overlay,
          controller: controller,
          pageImageBuilder: (i, px, _) =>
              ColoredBox(key: ValueKey('p$i'), color: Colors.white),
        ),
      ),
    ),
  ),
);

/// (page, fraction) at the top edge of the view.
(int, double) topAnchor(WidgetTester t) {
  for (var i = 0; i < _sizes.length; i++) {
    final f = find.byKey(ValueKey('p$i'));
    if (f.evaluate().isEmpty) continue;
    final r = t.getRect(f);
    if (r.top <= 0 && r.bottom > 0) return (i, -r.top / r.height);
  }
  return (-1, 0);
}

Future<void> pinch(WidgetTester t, Offset c, double from, double to) async {
  final a = await t.startGesture(c - Offset(from / 2, 0), pointer: 21);
  final b = await t.startGesture(c + Offset(from / 2, 0), pointer: 22);
  await t.pump();
  for (var i = 1; i <= 10; i++) {
    final d = (to - from) / 10 / 2;
    await a.moveBy(Offset(-d, 0));
    await b.moveBy(Offset(d, 0));
    await t.pump(const Duration(milliseconds: 16));
  }
  await a.up();
  await b.up();
  await t.pumpAndSettle();
}

void main() {
  testWidgets('rotation keeps the reading position', (t) async {
    await t.pumpWidget(_app(400));
    final list = t.state<ScrollableState>(find.byType(Scrollable).first);
    // Into page 20, a bit past its middle.
    final h = t.getSize(find.byKey(const ValueKey("p0"))).height + 8;
    list.position.jumpTo(8 + 20 * h + h * 0.6);
    await t.pump();
    final (p0, f0) = topAnchor(t);
    expect(p0, 20);

    await t.pumpWidget(_app(760)); // "landscape"
    await t.pump();
    await t.pump();
    final (p1, f1) = topAnchor(t);
    expect(p1, p0);
    expect(f1, closeTo(f0, 0.02));

    await t.pumpWidget(_app(400)); // and back
    await t.pump();
    await t.pump();
    final (p2, f2) = topAnchor(t);
    expect(p2, p0);
    expect(f2, closeTo(f0, 0.02));
    await t.pumpAndSettle();
  });

  testWidgets('zoomed in, one drag pans diagonally (no axis lock)', (t) async {
    await t.pumpWidget(_app(400));
    await pinch(t, const Offset(200, 300), 80, 240); // ~3x
    final before = t.getRect(find.byKey(const ValueKey('p0')));
    expect(before.width, greaterThan(800));

    final g = await t.startGesture(const Offset(200, 300));
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(-12, -9));
      await t.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await t.pump();
    final after = t.getRect(find.byKey(const ValueKey('p0')));
    // Both axes followed the finger (fling may add a little more).
    expect(before.left - after.left, greaterThanOrEqualTo(100));
    expect(before.top - after.top, greaterThanOrEqualTo(75));
    await t.pumpAndSettle();
  });

  testWidgets('pinching back to 1x restores normal scrolling', (t) async {
    await t.pumpWidget(_app(400));
    await pinch(t, const Offset(200, 300), 80, 200);
    await pinch(t, const Offset(200, 300), 300, 40);
    final r = t.getRect(find.byKey(const ValueKey('p0')));
    expect(r.width, closeTo(400 - 16, 0.5));
    expect(r.left, closeTo(8, 0.5));
    await t.drag(find.byType(PagesView), const Offset(0, -300));
    await t.pumpAndSettle();
    expect(t.getRect(find.byKey(const ValueKey('p0'))).top, lessThan(-250));
  });

  testWidgets('a focused field off-screen after a resize is brought back', (
    t,
  ) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    Widget app(double w) => _app(
      w,
      overlay: (context, page, size, scale) => page != 3
          ? const SizedBox.shrink()
          : Stack(
              children: [
                Positioned(
                  left: 10,
                  top: size.height * 0.5,
                  width: 100,
                  height: 30,
                  child: TextField(focusNode: focus),
                ),
              ],
            ),
    );
    await t.pumpWidget(app(400));
    final list = t.state<ScrollableState>(find.byType(Scrollable).first);
    final h = t.getSize(find.byKey(const ValueKey('p0'))).height + 8;
    list.position.jumpTo(3 * h + h * 0.3);
    await t.pump();
    focus.requestFocus();
    await t.pump();
    // Now push it just above the view (still built) and resize.
    final fieldTop = 8 + 3 * h + 0.5 * (h - 8);
    list.position.jumpTo(fieldTop + 30 + 100);
    await t.pump();
    expect(t.getRect(find.byType(TextField)).bottom, lessThan(0));
    await t.pump();
    await t.pumpWidget(app(380));
    await t.pump(const Duration(milliseconds: 10));
    await t.pump(const Duration(milliseconds: 400));
    await t.pump();
    final r = t.getRect(find.byType(TextField));
    expect(r.top, greaterThanOrEqualTo(0));
    expect(r.bottom, lessThanOrEqualTo(600));
  });

  testWidgets('double tap zooms in around the tap, double tap again fits '
      'the width', (t) async {
    await t.pumpWidget(_app(400));
    final p0 = find.byKey(const ValueKey('p0'));
    const at = Offset(300, 200);
    // The page point under the finger.
    Offset pagePoint() {
      final r = t.getRect(p0);
      return Offset((at.dx - r.left) / r.width, (at.dy - r.top) / r.height);
    }

    final before = pagePoint();
    await t.tapAt(at);
    await t.pump(const Duration(milliseconds: 50));
    await t.tapAt(at);
    // Animated: part way there after a few frames.
    await t.pump(const Duration(milliseconds: 16));
    await t.pump(const Duration(milliseconds: 100));
    final mid = t.getRect(p0).width;
    expect(mid, greaterThan(384 + 10));
    expect(mid, lessThan(384 * PagesView.doubleTapZoom - 10));
    await t.pumpAndSettle();
    expect(t.getRect(p0).width, closeTo(384 * PagesView.doubleTapZoom, 0.5));
    expect(pagePoint().dx, closeTo(before.dx, 0.002));
    expect(pagePoint().dy, closeTo(before.dy, 0.002));

    await t.tapAt(at);
    await t.pump(const Duration(milliseconds: 50));
    await t.tapAt(at);
    await t.pumpAndSettle();
    expect(t.getRect(p0).width, closeTo(384, 0.5));
    expect(t.getRect(p0).left, closeTo(8, 0.5));
    // Normal scrolling again.
    await t.drag(find.byType(PagesView), const Offset(0, -300));
    await t.pumpAndSettle();
    expect(t.getRect(p0).top, lessThan(-250));
  });

  testWidgets('two slow taps do not zoom', (t) async {
    await t.pumpWidget(_app(400));
    final g1 = await t.startGesture(
      const Offset(200, 200),
      pointer: 31,
      kind: PointerDeviceKind.touch,
    );
    await g1.up(timeStamp: const Duration(milliseconds: 60));
    final g2 = await t.createGesture(pointer: 32);
    await g2.down(
      const Offset(200, 200),
      timeStamp: const Duration(milliseconds: 900),
    );
    await g2.up(timeStamp: const Duration(milliseconds: 960));
    await t.pumpAndSettle();
    expect(
      t.getRect(find.byKey(const ValueKey('p0'))).width,
      closeTo(384, 0.5),
    );
  });

  testWidgets('double tap on a control that claims taps does not zoom', (
    t,
  ) async {
    var taps = 0;
    await t.pumpWidget(
      _app(
        400,
        overlay: (context, page, size, scale) => Stack(
          children: [
            Positioned(
              left: 100,
              top: 100,
              width: 50,
              height: 50,
              child: MetaData(
                metaData: const TapClaim(),
                behavior: HitTestBehavior.opaque,
                child: GestureDetector(onTap: () => taps++),
              ),
            ),
          ],
        ),
      ),
    );
    // Page 0 starts at (8, 8).
    await t.tapAt(const Offset(130, 130));
    await t.pump(const Duration(milliseconds: 50));
    await t.tapAt(const Offset(130, 130));
    await t.pumpAndSettle();
    expect(taps, 2);
    expect(
      t.getRect(find.byKey(const ValueKey('p0'))).width,
      closeTo(384, 0.5),
    );
  });

  testWidgets('reveal zooms to a rect and puts it in the upper part of the '
      'view; with the zoom kept it only pans when needed', (t) async {
    final c = PagesController();
    await t.pumpWidget(_app(400, controller: c));
    expect(c.isAttached, isTrue);
    expect(c.basePointScale(0), closeTo(384 / 612, 1e-9));
    // A small box low on page 2.
    const box = Rect.fromLTWH(400, 600, 20, 10);
    Rect onScreen(int page) {
      final r = t.getRect(find.byKey(ValueKey('p$page')));
      final k = r.width / 612;
      return Rect.fromLTWH(
        r.left + box.left * k,
        r.top + box.top * k,
        box.width * k,
        box.height * k,
      );
    }

    final done = c.reveal(2, box, zoom: 3);
    await t.pumpAndSettle();
    await done;
    expect(c.zoom, closeTo(3, 1e-9));
    final r = onScreen(2);
    expect(r.center.dx, closeTo(200, 1));
    expect(r.center.dy, closeTo(12 + (600 - 24) * 0.4, 1));
    // Already visible: nothing moves.
    c.reveal(2, box);
    await t.pumpAndSettle();
    expect(onScreen(2).center, offsetMoreOrLessEquals(r.center, epsilon: 0.5));
    // A box on another page: pans there at the same zoom.
    c.reveal(4, const Rect.fromLTWH(50, 100, 20, 10));
    await t.pumpAndSettle();
    expect(c.zoom, closeTo(3, 1e-9));
    final p4 = t.getRect(find.byKey(const ValueKey('p4')));
    final k = p4.width / 612;
    final cy = p4.top + 105 * k;
    expect(cy, greaterThan(0));
    expect(cy, lessThan(600));
  });

  testWidgets('a tap during a zoom animation does not stop it; a drag does', (
    t,
  ) async {
    final c = PagesController();
    await t.pumpWidget(_app(400, controller: c));
    c.reveal(0, const Rect.fromLTWH(300, 300, 20, 10), zoom: 3);
    await t.pump(const Duration(milliseconds: 16));
    await t.pump(const Duration(milliseconds: 60));
    await t.tapAt(const Offset(50, 500));
    await t.pumpAndSettle();
    expect(c.zoom, closeTo(3, 1e-9));
    c.reveal(0, const Rect.fromLTWH(30, 30, 20, 10), zoom: 3.5);
    await t.pump(const Duration(milliseconds: 16));
    await t.pump(const Duration(milliseconds: 60));
    final g = await t.startGesture(const Offset(200, 300));
    await g.moveBy(const Offset(0, 40));
    await t.pump(const Duration(milliseconds: 16));
    await g.up();
    await t.pumpAndSettle();
    expect(c.zoom, lessThan(3.5 - 0.01));
  });
}
