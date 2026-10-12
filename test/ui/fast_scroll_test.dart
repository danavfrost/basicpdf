import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfedit/ui/viewer/pages_view.dart';

Widget _app({
  int pages = 60,
  double width = 400,
  List<Size>? sizes,
  bool fastScroll = true,
  PagePosition? initial,
  ValueChanged<PagePosition>? onPosition,
  PagesController? controller,
  Brightness brightness = Brightness.light,
}) => MaterialApp(
  theme: ThemeData(brightness: brightness),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
        height: 600,
        child: PagesView(
          pageSizes: sizes ?? List<Size>.filled(pages, const Size(612, 792)),
          fastScroll: fastScroll,
          initialPosition: initial,
          onPositionChanged: onPosition,
          controller: controller,
          pageImageBuilder: (i, px, _) =>
              ColoredBox(key: ValueKey('p$i'), color: Colors.white),
        ),
      ),
    ),
  ),
);

/// (page, fraction) at the top edge of the view.
(int, double) topAnchor(WidgetTester t, {int pages = 60}) {
  for (var i = 0; i < pages; i++) {
    final f = find.byKey(ValueKey('p$i'));
    if (f.evaluate().isEmpty) continue;
    final r = t.getRect(f);
    if (r.top <= 0 && r.bottom > 0) return (i, -r.top / (r.height + 8));
  }
  return (-1, 0);
}

double opacity(WidgetTester t) => t
    .widget<AnimatedOpacity>(find.byKey(const ValueKey('fast-scroll')))
    .opacity;

final _thumb = find.byKey(const ValueKey('fast-scroll-thumb'));
final _bubble = find.byKey(const ValueKey('fast-scroll-bubble'));

ScrollPosition _pos(WidgetTester t) =>
    t.state<ScrollableState>(find.byType(Scrollable).first).position;

void main() {
  group('reading position', () {
    testWidgets('starts at the initial position (fit width)', (t) async {
      await t.pumpWidget(_app(initial: (page: 20, fraction: 0.4)));
      await t.pump();
      final (p, f) = topAnchor(t);
      expect(p, 20);
      expect(f, closeTo(0.4, 0.02));
    });

    testWidgets('initial position past the end lands at the end', (t) async {
      await t.pumpWidget(_app(initial: (page: 59, fraction: 1)));
      await t.pump();
      final pos = _pos(t);
      expect(pos.pixels, closeTo(pos.maxScrollExtent, 1));
      await t.pump(const Duration(seconds: 1));
      expect(pos.pixels, closeTo(pos.maxScrollExtent, 1)); // no spring-back
    });

    testWidgets('reports after scrolling stops, and when going away', (
      t,
    ) async {
      final got = <PagePosition>[];
      await t.pumpWidget(_app(onPosition: got.add));
      await t.drag(find.byType(PagesView), const Offset(0, -2000));
      await t.pumpAndSettle();
      expect(got, isEmpty, reason: 'debounced');
      await t.pump(const Duration(milliseconds: 600));
      expect(got, hasLength(1));
      final (p, f) = topAnchor(t);
      expect(got.last.page, p);
      expect(got.last.fraction, closeTo(f, 0.02));

      _pos(t).jumpTo(_pos(t).pixels + 1234);
      await t.pump();
      await t.pumpWidget(const SizedBox()); // closed before the debounce
      expect(got, hasLength(2));
      expect(got.last.page, greaterThan(p));
    });

    testWidgets('app going to background reports at once', (t) async {
      final got = <PagePosition>[];
      await t.pumpWidget(_app(onPosition: got.add));
      _pos(t).jumpTo(5000);
      await t.pump();
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(got, hasLength(1));
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pump(const Duration(seconds: 1));
    });

    testWidgets('page sizes measured later keep the page in view', (t) async {
      // Progressive loading: pdfrx first reports every page at the first
      // page's size, then the real (here: taller) sizes.
      final guess = List<Size>.filled(60, const Size(612, 792));
      await t.pumpWidget(
        _app(sizes: guess, initial: (page: 30, fraction: 0.5)),
      );
      await t.pump();
      expect(topAnchor(t).$1, 30);
      final real = [
        for (var i = 0; i < 60; i++)
          i.isEven ? const Size(612, 1008) : const Size(612, 792),
      ];
      await t.pumpWidget(_app(sizes: real, initial: (page: 30, fraction: 0.5)));
      await t.pump();
      final (p, f) = topAnchor(t);
      expect(p, 30);
      expect(f, closeTo(0.5, 0.03));
    });
  });

  group('fast-scroll thumb', () {
    testWidgets('appears on scroll, fades ~1.5 s after it stops', (t) async {
      await t.pumpWidget(_app());
      expect(opacity(t), 0);
      final g = await t.startGesture(const Offset(200, 300));
      await g.moveBy(const Offset(0, -150));
      await t.pump();
      expect(opacity(t), 1);
      await g.up();
      await t.pumpAndSettle();
      await t.pump(const Duration(milliseconds: 1000));
      expect(opacity(t), 1);
      await t.pump(const Duration(milliseconds: 700));
      expect(opacity(t), 0);
    });

    testWidgets('hidden thumb does not take touches', (t) async {
      await t.pumpWidget(_app());
      final r = t.getRect(_thumb);
      final before = _pos(t).pixels;
      await t.dragFrom(r.center, const Offset(0, 200));
      await t.pump();
      expect(find.byKey(const ValueKey('fast-scroll-bubble')), findsNothing);
      // The page list got the drag instead (at the top: nothing to do).
      expect(_pos(t).pixels, before);
    });

    testWidgets('dragging maps to the whole document, shows the page', (
      t,
    ) async {
      final got = <PagePosition>[];
      await t.pumpWidget(_app(onPosition: got.add));
      await t.drag(find.byType(PagesView), const Offset(0, -100));
      await t.pump();
      final r = t.getRect(_thumb);
      expect(r.width, greaterThanOrEqualTo(48), reason: 'big touch target');
      expect(r.right, 400);

      final g = await t.startGesture(r.center);
      await t.pump();
      expect(_bubble, findsOneWidget);
      // To the end of the track.
      await g.moveBy(const Offset(0, 1000));
      await t.pump();
      final pos = _pos(t);
      expect(pos.pixels, closeTo(pos.maxScrollExtent, 1));
      expect(find.text('Page 60 / 60'), findsOneWidget);
      // Halfway.
      final end = t.getRect(_thumb).center;
      await g.moveTo(Offset(end.dx, (r.center.dy + end.dy) / 2));
      await t.pump();
      final half = pos.pixels / pos.maxScrollExtent;
      expect(half, closeTo(0.5, 0.02));
      expect(
        find.textContaining(RegExp(r'^Page (2\d|3\d) / 60$')),
        findsOneWidget,
      );
      // The bubble names the page right beside it.
      final by = t.getRect(_bubble).center.dy;
      var beside = -1;
      for (var i = 0; i < 60; i++) {
        final f = find.byKey(ValueKey('p$i'));
        if (f.evaluate().isEmpty) continue;
        final pr = t.getRect(f);
        if (pr.top <= by && pr.bottom + 8 > by) beside = i;
      }
      expect(find.text('Page ${beside + 1} / 60'), findsOneWidget);
      // Back to the top.
      await g.moveBy(const Offset(0, -2000));
      await t.pump();
      expect(pos.pixels, 0);
      expect(find.text('Page 1 / 60'), findsOneWidget);
      await g.moveTo(
        Offset(end.dx, r.center.dy + (end.dy - r.center.dy) * 0.7),
      );
      await t.pump();
      await g.up();
      await t.pump();
      expect(_bubble, findsNothing);
      // Released: stays there, position reported right away.
      final at = pos.pixels;
      await t.pump(const Duration(seconds: 2));
      expect(pos.pixels, at);
      expect(got.last.page, topAnchor(t).$1);
      expect(opacity(t), 0);
    });

    testWidgets('pages wait while flying, render once the finger rests', (
      t,
    ) async {
      PageViewport? vp;
      await t.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 400,
            height: 600,
            child: PagesView(
              pageSizes: List.filled(2000, const Size(612, 792)),
              pageImageBuilder: (i, px, v) {
                vp = v;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      );
      await t.drag(find.byType(PagesView), const Offset(0, -100));
      await t.pump();
      final g = await t.startGesture(t.getRect(_thumb).center);
      await g.moveBy(const Offset(0, 200));
      await t.pump();
      expect(vp!.fast.value, isTrue);
      expect(find.textContaining(' / 2000'), findsOneWidget);
      await t.pump(const Duration(milliseconds: 200)); // finger resting
      expect(vp!.fast.value, isFalse);
      await g.moveBy(const Offset(0, 100));
      await t.pump();
      await g.up();
      await t.pump();
      expect(vp!.fast.value, isFalse);
    });

    testWidgets('not shown for 3 pages or when turned off (edit mode)', (
      t,
    ) async {
      await t.pumpWidget(_app(pages: 3, width: 200));
      expect(find.byKey(const ValueKey('fast-scroll')), findsNothing);
      await t.pumpWidget(_app(fastScroll: false));
      await t.drag(find.byType(PagesView), const Offset(0, -300));
      await t.pump();
      expect(find.byKey(const ValueKey('fast-scroll')), findsNothing);
    });

    testWidgets('zoomed in, the thumb still maps to the vertical position', (
      t,
    ) async {
      final c = PagesController();
      await t.pumpWidget(_app(controller: c));
      c.reveal(0, const Rect.fromLTWH(300, 300, 50, 20), zoom: 3);
      await t.pumpAndSettle();
      expect(c.zoom, closeTo(3, 0.01));
      await t.drag(find.byType(PagesView), const Offset(0, -100));
      await t.pump();
      final g = await t.startGesture(t.getRect(_thumb).center);
      await g.moveBy(const Offset(0, 1000));
      await t.pump();
      final pos = _pos(t);
      expect(pos.pixels, closeTo(pos.maxScrollExtent, 1));
      expect(find.text('Page 60 / 60'), findsOneWidget);
      await g.up();
      await t.pumpAndSettle();
      expect(c.zoom, closeTo(3, 0.01));
    });

    testWidgets('dark theme: bubble follows the theme', (t) async {
      await t.pumpWidget(_app(brightness: Brightness.dark));
      await t.drag(find.byType(PagesView), const Offset(0, -100));
      await t.pump();
      final g = await t.startGesture(t.getRect(_thumb).center);
      await t.pump();
      final m = t.widget<Material>(_bubble);
      final scheme = Theme.of(t.element(_bubble)).colorScheme;
      expect(m.color, scheme.inverseSurface);
      await g.up();
      await t.pump(const Duration(seconds: 2));
    });
  });
}
