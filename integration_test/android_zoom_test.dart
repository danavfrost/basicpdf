// Android QA: pinch zoom, pan, sharp re-render and edit overlay alignment.
//
// Run: flutter test integration_test/android_zoom_test.dart -d emulator-5554
// Screenshots: logs "[QA] SHOT <name>"; a host-side logcat watcher takes
// `adb exec-out screencap` when it sees that line (test pauses ~1.5 s).
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfedit/main.dart';
import 'package:pdfedit/services/doc_session.dart';
import 'package:pdfedit/services/file_service.dart';
import 'package:pdfedit/services/history_store.dart';
import 'package:pdfedit/services/settings_store.dart';
import 'package:pdfedit/ui/edit/fill_overlay.dart';
import 'package:pdfedit/ui/viewer/pages_view.dart';

import 'android_fixtures.dart';

void log(String s) => debugPrint('[QA] $s');

Future<void> wait(WidgetTester t, int ms) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> shot(WidgetTester t, String name, {int settle = 800}) async {
  await wait(t, settle);
  log('SHOT $name');
  await wait(t, 1500);
}

Future<DocSession> startWith(WidgetTester t, String b64, String name) async {
  final settings = SettingsStore(getApplicationSupportDirectory);
  await settings.load();
  final session = DocSession();
  final history = HistoryStore(getApplicationSupportDirectory);
  final files = PlatformFileService();
  await t.pumpWidget(
    PdfEditApp(
      session: session,
      history: history,
      files: files,
      settings: settings,
    ),
  );
  await wait(t, 1000);
  final dir = await getApplicationDocumentsDirectory();
  final f = File('${dir.path}/$name');
  final bytes = base64Decode(b64);
  await f.writeAsBytes(bytes);
  final ok = await session.open(
    bytes,
    location: FileService.pathLocation(f.path),
    askPassword: (_) async => null,
  );
  expect(ok, isTrue);
  await wait(t, 2000);
  return session;
}

Future<void> pinch(
  WidgetTester t,
  Offset center,
  double from,
  double to, {
  int steps = 20,
  bool release = true,
}) async {
  final a = await t.startGesture(center - Offset(from / 2, 0), pointer: 11);
  final b = await t.startGesture(center + Offset(from / 2, 0), pointer: 12);
  await t.pump(const Duration(milliseconds: 30));
  for (var i = 1; i <= steps; i++) {
    final d = (to - from) / steps / 2;
    await a.moveBy(Offset(-d, 0));
    await b.moveBy(Offset(d, 0));
    await t.pump(const Duration(milliseconds: 16));
  }
  if (release) {
    await a.up();
    await b.up();
  }
  await t.pump(const Duration(milliseconds: 50));
}

Rect globalRect(WidgetTester t, Finder f) {
  final box = t.renderObject(f) as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// Logs page image resolution vs on-screen size (sharpness check).
void logSharpness(WidgetTester t, String tag) {
  final dpr = t.view.devicePixelRatio;
  final imgs = find.byType(RawImage);
  for (var i = 0; i < math.min(2, imgs.evaluate().length); i++) {
    final w = t.widget<RawImage>(imgs.at(i));
    final r = globalRect(t, imgs.at(i));
    log(
      '$tag img[$i] bitmap=${w.image?.width}x${w.image?.height} '
      'screen=${(r.width * dpr).round()}x${(r.height * dpr).round()} '
      'ratio=${((w.image?.width ?? 0) / (r.width * dpr)).toStringAsFixed(2)}',
    );
  }
}

/// Compares each visible text overlay with where its field should be.
void checkAlignment(WidgetTester t, DocSession s, String tag) {
  final doc = s.editDoc!;
  final pageRects = <int, Rect>{};
  final images = find.byType(PdfPageImage);
  for (final e in images.evaluate()) {
    final w = e.widget as PdfPageImage;
    final box = e.renderObject as RenderBox;
    pageRects[w.page.pageNumber - 1] =
        box.localToGlobal(Offset.zero) & box.size;
  }
  var worst = 0.0;
  for (final f in doc.fields) {
    final pr = pageRects[f.pageIndex];
    if (pr == null) continue;
    final finder = find.byKey(ValueKey('text:${f.id}'));
    if (finder.evaluate().isEmpty) continue;
    final k = pr.width / doc.pages[f.pageIndex].width;
    final want = Rect.fromLTWH(
      pr.left + f.rect.left * k,
      pr.top + f.rect.top * k,
      f.rect.width * k,
      f.rect.height * k,
    );
    final got = globalRect(t, finder);
    final err = [
      (want.left - got.left).abs(),
      (want.top - got.top).abs(),
      (want.width - got.width).abs(),
      (want.height - got.height).abs(),
    ].reduce(math.max);
    worst = math.max(worst, err);
    log(
      '$tag ${f.fullName}: want=$want got=$got err=${err.toStringAsFixed(2)}',
    );
  }
  log('$tag worst alignment error ${worst.toStringAsFixed(2)} px');
  expect(worst, lessThan(1.5));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('pinch zoom, pan, sharp render, aligned overlays', (t) async {
    final s = await startWith(t, qaFormB64, 'qa_form_zoom.pdf');
    final size = t.view.physicalSize / t.view.devicePixelRatio;
    final center = Offset(size.width / 2, size.height * 0.35);
    await shot(t, 'z0_start');
    logSharpness(t, 'z0');

    // Pinch out ~3x but keep fingers down: mid-gesture picture.
    await pinch(t, center, 100, 300, release: false);
    await shot(t, 'z1_pinching', settle: 300);
    // Release the two pointers started inside pinch().
    await t.sendEventToBinding(const PointerUpEvent(pointer: 11));
    await t.sendEventToBinding(const PointerUpEvent(pointer: 12));
    await wait(t, 1500);
    await shot(t, 'z2_zoomed_released');
    logSharpness(t, 'z2');

    // Pan with one finger (diagonal): both axes must follow the finger.
    final page0 = find.byType(PdfPageImage).first;
    final beforePan = globalRect(t, page0);
    final g = await t.startGesture(center);
    for (var i = 0; i < 20; i++) {
      await g.moveBy(const Offset(-10, -6));
      await t.pump(const Duration(milliseconds: 16));
    }
    await t.pump(const Duration(milliseconds: 200)); // stop: no fling
    await g.up();
    await wait(t, 1000);
    final afterPan = globalRect(t, page0);
    final dx = beforePan.left - afterPan.left,
        dy = beforePan.top - afterPan.top;
    log(
      'diagonal pan moved page by dx=${dx.toStringAsFixed(1)} dy=${dy.toStringAsFixed(1)}',
    );
    expect(dx, greaterThan(150));
    expect(dy, greaterThan(90));
    await shot(t, 'z3_panned');

    // Enter edit mode while zoomed.
    await t.tap(find.byKey(const ValueKey('edit-button')));
    await wait(t, 1500);
    await shot(t, 'z4_edit_zoomed');
    checkAlignment(t, s, 'z4');

    // Zoom further in edit mode, around a field.
    await pinch(t, center, 200, 320);
    await wait(t, 1500);
    await shot(t, 'z5_edit_zoomed_more');
    checkAlignment(t, s, 'z5');
    logSharpness(t, 'z5');

    // Type into a field while zoomed.
    final nameField = find.byKey(
      ValueKey(
        'text:${s.editDoc!.fields.firstWhere((f) => f.fullName == 'name').id}',
      ),
    );
    if (nameField.evaluate().isNotEmpty) {
      await t.enterText(
        find.descendant(of: nameField, matching: find.byType(TextField)),
        'Zoomed Typist',
      );
      await wait(t, 800);
      await shot(t, 'z6_typed_zoomed');
    } else {
      log('name field not on screen after zoom');
    }

    // Pinch back to 1x.
    await pinch(t, center, 400, 60, steps: 30);
    await wait(t, 1500);
    await shot(t, 'z7_back_to_1x');
    checkAlignment(t, s, 'z7');
    logSharpness(t, 'z7');

    // Apply while at 1x and look at the rendered value.
    FocusManager.instance.primaryFocus?.unfocus();
    await t.tap(find.byKey(const ValueKey('done-button')));
    await wait(t, 2500);
    await shot(t, 'z8_applied');
    log('done; dirty=${s.dirty}');
    expect(find.byType(FieldTextBox), findsNothing);
  });
}
