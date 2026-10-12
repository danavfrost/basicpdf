// QA for reading position (SPEC §1.1) and the fast-scroll thumb, on
// Android (tool/qa/android_run.sh) and the iOS simulator (tool/qa/ios_run.sh
// + tool/qa/ios_shooter.sh).
//
// Needs Documents/qa/big500.pdf and big2000.pdf (500 and 2000 pages, any
// content) and Documents/qa/form.pdf in the app's container.
//
// Two runs: the first opens the files from Recent, reads, flies the thumb
// (screenshots light/dark) and leaves the 2000-page file open; kill the
// app (force-stop) and run again: the second reopens both from Recent and
// checks they come back where they were, then rotates.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pdfedit/ui/viewer/pages_view.dart';

import 'ios_helpers.dart' as h;

Future<void> shot(WidgetTester t, String name) async {
  if (Platform.isAndroid) {
    await h.wait(t, 500);
    h.log('SHOT $name');
    await h.wait(t, 1500);
  } else {
    await h.shot(t, name, settleMs: 500);
  }
}

/// 1-based page number crossing the reading line (just under the bar).
int topPage(WidgetTester t) {
  final mq = MediaQuery.of(t.element(find.byType(PagesView)));
  final line = mq.padding.top + kToolbarHeight + 12;
  for (final e in find.byType(PdfPageImage).evaluate()) {
    final w = e.widget as PdfPageImage;
    final box = e.renderObject as RenderBox;
    final r = box.localToGlobal(Offset.zero) & box.size;
    if (r.top <= line && r.bottom + 8 > line) return w.page.pageNumber;
  }
  return -1;
}

Future<void> openRecent(WidgetTester t, String name) async {
  await h.until(t, find.text(name));
  final sw = Stopwatch()..start();
  await t.tap(find.text(name).first);
  await h.until(t, find.byType(PdfPageImage));
  h.log('open $name: first page laid out in ${sw.elapsedMilliseconds} ms');
  await h.wait(t, 1200);
}

Future<void> backHome(WidgetTester t, h.QaApp qa) async {
  qa.session.close();
  await h.wait(t, 1000);
}

/// Drags the thumb from where it is to [frac] of its track; [hold] keeps
/// the finger down at the end (returns the gesture).
Future<TestGesture> dragThumb(
  WidgetTester t,
  double frac, {
  int steps = 12,
}) async {
  await showThumb(t); // it fades 1.5 s after scrolling stops
  final thumb = find.byKey(const ValueKey('fast-scroll-thumb'));
  final r = t.getRect(thumb);
  final mq = MediaQuery.of(t.element(find.byType(PagesView)));
  final top = mq.padding.top + kToolbarHeight + 8 + 44 / 2;
  final bottom =
      mq.size.height -
      (mq.padding.bottom + 8 < 12 ? 12 : mq.padding.bottom + 8) -
      44 / 2;
  final target = top + frac * (bottom - top);
  final g = await t.startGesture(r.center);
  await t.pump(const Duration(milliseconds: 16));
  final dy = (target - r.center.dy) / steps;
  for (var i = 0; i < steps; i++) {
    await g.moveBy(Offset(0, dy));
    await t.pump(const Duration(milliseconds: 16));
  }
  return g;
}

Future<void> showThumb(WidgetTester t) async {
  final c = t.getCenter(find.byType(PagesView));
  final g = await t.startGesture(c);
  for (var i = 0; i < 6; i++) {
    await g.moveBy(const Offset(0, -25));
    await t.pump(const Duration(milliseconds: 16));
  }
  await g.up();
  await h.wait(t, 300);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  h.qaTest('reading position and fast-scroll thumb', (t) async {
    final docs = await h.docsDir();
    final marker = File('$docs/qa/reading_phase1.txt');
    final qa = await h.startApp(t);
    // As the in-app browser records them (iOS: relative to Documents, so
    // they survive the container moving on reinstall).
    await qa.files.browseRoot();
    final big500 = qa.files.locationForPath('$docs/qa/big500.pdf');
    final big2000 = qa.files.locationForPath('$docs/qa/big2000.pdf');
    final form = qa.files.locationForPath('$docs/qa/form.pdf');

    if (!marker.existsSync()) {
      h.log('PHASE 1');
      await qa.settings.setDark(false);
      await qa.history.touch(form);
      await qa.history.touch(big500);
      await qa.history.touch(big2000);
      await h.wait(t, 800);

      // A normal form: no thumb (1 page).
      await openRecent(t, 'form.pdf');
      await showThumb(t);
      expect(find.byKey(const ValueKey('fast-scroll')), findsNothing);
      await backHome(t, qa);

      // 500 pages: read to about page 123 with the thumb, then leave.
      await openRecent(t, 'big500.pdf');
      await showThumb(t);
      var g = await dragThumb(t, 0.245);
      await g.up();
      await h.wait(t, 1500);
      final p500 = topPage(t);
      h.log('big500 left at page $p500');
      await shot(t, 'r1_500_left');
      await backHome(t, qa);

      // 2000 pages: thumb idle / visible / dragging, light then dark.
      await openRecent(t, 'big2000.pdf');
      await shot(t, 't1_2000_idle_light');
      await showThumb(t);
      await shot(t, 't2_2000_visible_light');
      g = await dragThumb(t, 0.6, steps: 4); // fast fling
      await h.wait(t, 50);
      h.log('thumb fling: page ${topPage(t)}');
      await g.moveBy(const Offset(0, -20));
      await t.pump(const Duration(milliseconds: 16));
      await shot(t, 't3_2000_dragging_light');
      expect(find.byKey(const ValueKey('fast-scroll-bubble')), findsOneWidget);
      await g.up();
      await h.wait(t, 2500);
      await shot(t, 't4_2000_released_faded_light');

      await qa.settings.setDark(true);
      await h.wait(t, 600);
      await showThumb(t);
      await shot(t, 't5_2000_visible_dark');
      g = await dragThumb(t, 0.37);
      await shot(t, 't6_2000_dragging_dark');
      // Baseline: what a pump costs here without moving anything.
      final base = Stopwatch()..start();
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 16));
      }
      h.log('20 idle pumps in ${base.elapsedMilliseconds} ms');
      // Fly to the end and back, quickly: pages wait (blank) meanwhile.
      final timings = <FrameTiming>[];
      void onTimings(List<FrameTiming> l) => timings.addAll(l);
      SchedulerBinding.instance.addTimingsCallback(onTimings);
      final sw = Stopwatch()..start();
      for (final f in [0.9, 0.1, 0.99, 0.5]) {
        final r = t.getRect(find.byKey(const ValueKey('fast-scroll-thumb')));
        final mq = MediaQuery.of(t.element(find.byType(PagesView)));
        final dy = (f * mq.size.height) - r.center.dy;
        for (var i = 0; i < 5; i++) {
          await g.moveBy(Offset(0, dy / 5));
          await t.pump(const Duration(milliseconds: 16));
        }
      }
      h.log('fling 4 sweeps in ${sw.elapsedMilliseconds} ms');
      await h.wait(t, 300);
      SchedulerBinding.instance.removeTimingsCallback(onTimings);
      if (timings.isNotEmpty) {
        int ms(Duration d) => d.inMicroseconds ~/ 1000;
        final b = timings.map((f) => ms(f.buildDuration)).toList()..sort();
        final r = timings.map((f) => ms(f.rasterDuration)).toList()..sort();
        h.log(
          'fling frames ${timings.length}: build median ${b[b.length ~/ 2]} '
          'max ${b.last} ms, raster median ${r[r.length ~/ 2]} max ${r.last} ms',
        );
      }
      await shot(t, 't7_2000_flying_dark');
      await g.moveBy(const Offset(0, 8));
      await t.pump(const Duration(milliseconds: 16));
      await g.up();
      await h.wait(t, 2500);
      await shot(t, 't8_2000_released_dark');
      final p2000 = topPage(t);
      h.log('big2000 left at page $p2000 (app will be killed now)');
      await qa.settings.setDark(false);
      await h.wait(t, 1500);
      await marker.writeAsString('$p500 $p2000');
      // The app stays on big2000: the runner force-stops it.
    } else {
      h.log('PHASE 2');
      final want = marker.readAsStringSync().split(' ').map(int.parse).toList();
      marker.deleteSync();
      await shot(t, 'r2_home_after_kill');
      await openRecent(t, 'big2000.pdf');
      final got2000 = topPage(t);
      h.log('big2000 restored at page $got2000 (left at ${want[1]})');
      await shot(t, 'r3_2000_restored');
      expect(got2000, want[1]);

      // Rotation keeps the place (simulated: swap the window size).
      final size = t.view.physicalSize;
      t.view.physicalSize = Size(size.height, size.width);
      await h.wait(t, 1500);
      final rotated = topPage(t);
      h.log('rotated: page $rotated');
      await shot(t, 'r4_2000_rotated');
      await showThumb(t);
      final g = await dragThumb(t, 0.5);
      await shot(t, 'r5_2000_rotated_dragging');
      await g.up();
      await h.wait(t, 1500);
      t.view.resetPhysicalSize();
      await h.wait(t, 1500);
      expect(rotated, want[1]);

      await backHome(t, qa);
      await openRecent(t, 'big500.pdf');
      final got500 = topPage(t);
      h.log('big500 restored at page $got500 (left at ${want[0]})');
      await shot(t, 'r6_500_restored');
      expect(got500, want[0]);
      await backHome(t, qa);
    }
  });

  h.qaDone();
}
