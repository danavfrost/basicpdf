// Device smoke test: Home → Open → Browse → open sample.pdf → scroll.
// Expects sample.pdf in the in-app browser root (iOS app Documents).
// Pauses between steps so screenshots can be taken from outside.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pdfedit/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> wait(WidgetTester t, int ms) async {
    final end = DateTime.now().add(Duration(milliseconds: ms));
    while (DateTime.now().isBefore(end)) {
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('open and scroll a PDF', (t) async {
    await app.main();
    await wait(t, 4000); // shot: home
    await t.tap(find.byKey(const ValueKey('home-open')));
    await wait(t, 800);
    await t.tap(find.text('Browse'));
    await wait(t, 4000); // shot: browse
    await t.tap(find.text('sample.pdf'));
    await wait(t, 4000); // shot: document
    final g = await t.startGesture(const Offset(200, 600));
    for (var i = 0; i < 60; i++) {
      await g.moveBy(const Offset(0, -8));
      await t.pump(const Duration(milliseconds: 50));
    }
    await wait(t, 0); // shot taken during the drag above (bar hidden)
    await g.up();
    await wait(t, 4000); // shot: bar back
  });
}
