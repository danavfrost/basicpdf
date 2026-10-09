import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfedit/ui/viewer/auto_hide.dart';

void main() {
  late AutoHideController controller;

  Widget app() => MaterialApp(
    home: Scaffold(
      body: AutoHideScaffold(
        controller: controller,
        bar: AppBar(title: const Text('Doc')),
        child: GestureDetector(
          onTap: controller.show,
          child: ListView.builder(
            key: const ValueKey('list'),
            itemCount: 200,
            itemBuilder: (_, i) => SizedBox(height: 80, child: Text('Item $i')),
          ),
        ),
      ),
    ),
  );

  Offset barOffset(WidgetTester t) => t
      .widget<AnimatedSlide>(find.byKey(const ValueKey('auto-hide-bar')))
      .offset;

  setUp(() => controller = AutoHideController());
  tearDown(() => controller.dispose());

  testWidgets('starts visible', (t) async {
    await t.pumpWidget(app());
    expect(controller.visible, isTrue);
    expect(barOffset(t), Offset.zero);
  });

  testWidgets('hides while scrolling down, returns after ~350 ms idle', (
    t,
  ) async {
    await t.pumpWidget(app());
    final g = await t.startGesture(
      t.getCenter(find.byKey(const ValueKey('list'))),
    );
    for (var i = 0; i < 5; i++) {
      await g.moveBy(const Offset(0, -40));
      await t.pump(const Duration(milliseconds: 16));
    }
    expect(controller.visible, isFalse);
    expect(barOffset(t), const Offset(0, -1));

    // Still hidden shortly after the last movement (finger still down).
    await t.pump(const Duration(milliseconds: 200));
    expect(controller.visible, isFalse);

    await g.up();
    await t.pump(const Duration(milliseconds: 100));
    expect(controller.visible, isFalse);
    await t.pump(const Duration(milliseconds: 400));
    expect(controller.visible, isTrue);
    expect(barOffset(t), Offset.zero);
  });

  testWidgets('reappears immediately on scroll up', (t) async {
    await t.pumpWidget(app());
    final g = await t.startGesture(
      t.getCenter(find.byKey(const ValueKey('list'))),
    );
    for (var i = 0; i < 5; i++) {
      await g.moveBy(const Offset(0, -40));
      await t.pump(const Duration(milliseconds: 16));
    }
    expect(controller.visible, isFalse);
    await g.moveBy(const Offset(0, 30));
    await t.pump(const Duration(milliseconds: 16));
    expect(controller.visible, isTrue);
    await g.up();
    await t.pump(const Duration(milliseconds: 500));
    await t.pumpAndSettle();
  });

  testWidgets('tap shows the bar', (t) async {
    await t.pumpWidget(app());
    controller.onScroll(10);
    await t.pump();
    expect(controller.visible, isFalse);
    await t.tap(find.text('Item 3'));
    await t.pump();
    expect(controller.visible, isTrue);
    await t.pumpAndSettle(const Duration(milliseconds: 500));
  });

  testWidgets('pinned bar never hides', (t) async {
    await t.pumpWidget(app());
    controller.pinned = true;
    controller.onScroll(50);
    await t.pump();
    expect(controller.visible, isTrue);
  });
}
