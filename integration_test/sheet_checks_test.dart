// QA (Android + iOS): the character sheet's proficiency dots while
// editing — they must look like the sheet's own circles and dots (no
// boxes, no check marks), toggle on and off, at 1x and zoomed, light and
// dark; text fields keep a faint look while idle.
//
// Android: tool/qa/android_run.sh integration_test/sheet_checks_test.dart <log>
// iOS:     tool/qa/ios_run.sh integration_test/sheet_checks_test.dart
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pdfedit/core/pdf_core.dart';
import 'package:pdfedit/services/file_service.dart';
import 'package:pdfedit/ui/edit/fill_overlay.dart';

import 'ios_helpers.dart' show log, wait, qaTest, qaDone, startApp, menu, until;
import 'sheet_fill_test.dart' show snap, doubleTap;
import 'sheet_qa_test.dart' show sheetFile, pageRects, fieldOnScreen;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  qaDone();

  qaTest('character sheet: proficiency dots look like the sheet', (t) async {
    final file = await sheetFile();
    final qa = await startApp(t);
    final s = qa.session;
    if (Theme.of(t.element(find.byType(Scaffold).first)).brightness ==
        Brightness.dark) {
      await menu(t, 'Dark mode');
    }
    await qa.history.touch(FileService.pathLocation(file.path));
    await wait(t, 400);
    await t.tap(find.text('Character Sheet.pdf').first);
    await until(t, find.byKey(const ValueKey('edit-button')));
    await wait(t, 1500);
    final doc = s.editDoc!;
    PdfField named(String n) => doc.fields.firstWhere((f) => f.fullName == n);
    Offset pagePoint(double x, double y) {
      final r = pageRects(t)[0]!;
      final k = r.width / doc.pages[0].width;
      return r.topLeft + Offset(x * k, y * k);
    }

    await t.tap(find.byKey(const ValueKey('edit-button')));
    await wait(t, 1500);
    await snap(t, 'c01_edit_1x');
    final session = t
        .widget<FillOverlay>(find.byType(FillOverlay).first)
        .session;
    final dots = [
      'Check Box 11',
      'Check Box 26',
      'Check Box 34',
      'Check Box 39',
    ];
    final rnd = math.Random(3);
    for (final n in dots) {
      final r = fieldOnScreen(t, doc, named(n))!;
      await t.tapAt(
        r.center + Offset(rnd.nextDouble() * 6 - 3, rnd.nextDouble() * 6 - 3),
      );
      await wait(t, 200);
    }
    log(
      'dots on at 1x: ${dots.where((n) => session.isChecked(named(n))).length}/${dots.length}',
    );
    await snap(t, 'c02_edit_1x_dots_on');
    // Zoom on the skills (double tap on the skill labels, not a field).
    await doubleTap(t, pagePoint(175, 430));
    await wait(t, 900);
    await snap(t, 'c03_zoomed_dots_on');
    // Tap Athletics' dot again: off, nothing left behind.
    await t.tapAt(fieldOnScreen(t, doc, named('Check Box 26'))!.center);
    await wait(t, 400);
    log(
      'Athletics dot after 2nd tap: ${session.isChecked(named('Check Box 26'))}',
    );
    await snap(t, 'c04_zoomed_athletics_off');
    // A value in a skill box and a focused one.
    session.focusField(named('Athletics'));
    await wait(t, 700);
    await t.enterText(
      find.descendant(
        of: find.byKey(ValueKey('text:${named('Athletics').id}')),
        matching: find.byType(TextField),
      ),
      '+6',
    );
    session.focusField(named('Perception '));
    await wait(t, 700);
    await t.enterText(
      find.descendant(
        of: find.byKey(ValueKey('text:${named('Perception ').id}')),
        matching: find.byType(TextField),
      ),
      '+4',
    );
    await wait(t, 400);
    await snap(t, 'c05_zoomed_text_focus');
    FocusManager.instance.primaryFocus?.unfocus();
    await wait(t, 500);
    // ✓ and the view.
    await t.tap(find.byKey(const ValueKey('done-button')));
    await wait(t, 2000);
    await snap(t, 'c06_applied_zoomed');
    // Edit again: the saved dots are drawn by the overlay over a page
    // drawn with them off; turn one off.
    await t.tap(find.byKey(const ValueKey('edit-button')));
    await wait(t, 1500);
    await snap(t, 'c07_reedit_zoomed');
    final s2 = t.widget<FillOverlay>(find.byType(FillOverlay).first).session;
    final d2 = s.editDoc!;
    final cb34 = d2.fields.firstWhere((f) => f.fullName == 'Check Box 34');
    await t.tapAt(fieldOnScreen(t, d2, cb34)!.center);
    await wait(t, 500);
    log('Perception dot after tap in re-edit: ${s2.isChecked(cb34)}');
    await snap(t, 'c08_reedit_perception_off');
    // Dark mode, editing again.
    await t.tap(find.byKey(const ValueKey('done-button')));
    await wait(t, 1500);
    await menu(t, 'Dark mode');
    await wait(t, 800);
    await t.tap(find.byKey(const ValueKey('edit-button')));
    await wait(t, 1500);
    await snap(t, 'c09_dark_edit_zoomed');
    await doubleTap(t, pagePoint(175, 430));
    await wait(t, 900);
    await snap(t, 'c10_dark_edit_1x');
    await t.tap(find.byKey(const ValueKey('done-button')));
    await wait(t, 1500);
    await snap(t, 'c11_dark_applied_1x');
    await menu(t, 'Dark mode');
    await wait(t, 500);
    final fin = s.editDoc!;
    final states = {
      for (final n in dots)
        n: fin.fields.firstWhere((f) => f.fullName == n).value,
    };
    log('final dot states: $states');
    expect(states['Check Box 26'], 'Off');
    expect(states['Check Box 34'], 'Off');
    expect(states['Check Box 11'], 'Yes');
  });
}
