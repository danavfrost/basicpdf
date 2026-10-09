// iOS QA: dark mode toggle, fill every field kind, keyboard avoidance,
// ✓ rendering, Save in place (incremental update) in the app Documents.
// Expects Documents/form.pdf and Documents/qa/form.pdf (identical copies of
// test/fixtures/form.pdf).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfedit/core/pdf_core.dart';

import 'ios_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  qaDone();

  qaTest('dark mode toggle persists to settings.json', (t) async {
    final qa = await startApp(t);
    final ctx = t.element(find.byKey(const ValueKey('home-open')));
    log(
      'initial brightness ${Theme.of(ctx).brightness} mode ${qa.settings.value}',
    );
    await t.tap(find.byKey(const ValueKey('overflow-menu')));
    await wait(t, 600);
    await shot(t, '02_menu_home');
    await t.tap(find.byKey(const ValueKey('dark-mode')));
    await wait(t, 800);
    final ctx2 = t.element(find.byKey(const ValueKey('home-open')));
    expect(Theme.of(ctx2).brightness, Brightness.dark);
    await shot(t, '03_home_dark');
    final f = File(
      '${(await getApplicationSupportDirectory()).path}/settings.json',
    );
    log('settings.json: ${await f.readAsString()}');
    expect(await f.readAsString(), contains('"dark":true'));
  });

  qaTest('fill all kinds, keyboard, ✓, Save in place', (t) async {
    final qa = await startApp(t);
    await openFromBrowse(t, ['form.pdf']);
    await until(t, find.byKey(const ValueKey('edit-button')));
    await wait(t, 1500);
    await shot(t, '04_form_view');
    await t.tap(find.byKey(const ValueKey('edit-button')));
    await wait(t, 1000);
    await shot(t, '05_form_edit');

    final fields = qa.session.editDoc!.fields;
    for (final f in fields) {
      log(
        'field ${f.fullName} ${f.kind} p${f.pageIndex} ${f.rect} v=${f.value} ro=${f.readOnly}',
      );
    }

    // Text (single line): tap -> keyboard -> type.
    final tf = find.byType(TextField);
    log('TextFields on screen: ${tf.evaluate().length}');
    await t.tap(tf.at(0));
    await wait(t, 1500);
    log(
      'viewInsets after focusing name: ${t.view.viewInsets} '
      'size ${t.view.physicalSize}',
    );
    await shot(t, '06_keyboard_name');
    await t.enterText(tf.at(0), 'Bob Builder');
    await wait(t, 300);

    // Multiline with iOS smart punctuation characters.
    await t.tap(tf.at(1));
    await wait(t, 600);
    await t.enterText(tf.at(1), 'First line\nIt’s “quoted” — ok – fine');
    await wait(t, 300);

    // Checkbox + radio.
    final boxes = byTypeName('_CheckBox');
    log('check/radio widgets: ${boxes.evaluate().length}');
    FocusManager.instance.primaryFocus?.unfocus();
    await wait(t, 800);
    await t.tap(boxes.at(0)); // agree
    await wait(t, 300);
    await t.tap(boxes.at(3)); // color = blue
    await wait(t, 300);

    // Combo box.
    await t.tap(find.text('California'));
    await wait(t, 800);
    await shot(t, '07_combo_menu');
    await t.tap(find.text('New York').last);
    await wait(t, 600);
    // List box.
    await t.tap(find.text('Pear'));
    await wait(t, 800);
    await t.tap(find.text('Plum').last);
    await wait(t, 600);
    await shot(t, '08_filled_before_done');

    // Keyboard avoidance: scroll so the "name" field sits near the bottom,
    // then focus it and see whether it ends up above the keyboard.
    final screenH = t.view.physicalSize.height / t.view.devicePixelRatio;
    final all = tf.evaluate().length;
    var low = 0;
    for (var i = 0; i < all; i++) {
      if (t.getRect(tf.at(i)).top > t.getRect(tf.at(low)).top) low = i;
    }
    final r0 = t.getRect(tf.at(low));
    log('lowest TextField #$low at $r0 screenH $screenH');
    final g = await t.startGesture(const Offset(200, 600));
    final dy = (screenH - 60) - r0.bottom;
    for (var i = 0; i < 20; i++) {
      await g.moveBy(Offset(0, dy / 20));
      await t.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await wait(t, 1500);
    log('lowest field before focus: ${t.getRect(tf.at(low))}');
    await t.tap(tf.at(low), warnIfMissed: false);
    await wait(t, 2000);
    final insets = t.view.viewInsets.bottom / t.view.devicePixelRatio;
    final r = t.getRect(tf.at(low));
    log('KEYBOARD: insets=$insets field=$r visibleBottom=${screenH - insets}');
    await shot(t, '09_keyboard_bottom_field');
    if (insets > 0 && r.bottom > screenH - insets) {
      log('BUG? focused field is under the keyboard');
    }
    FocusManager.instance.primaryFocus?.unfocus();
    await wait(t, 1000);

    await t.tap(find.byKey(const ValueKey('done-button')));
    await wait(t, 3000);
    await shot(t, '10_after_done');
    expect(qa.session.dirty, isTrue);
    expect(find.byKey(const ValueKey('dirty-dot')), findsOneWidget);

    PdfField by(String n) =>
        qa.session.editDoc!.fields.firstWhere((f) => f.fullName == n);
    log(
      'after ✓: name=${by('name').value} notes=${by('notes').value} '
      'agree=${by('agree').value} color=${by('color').value} '
      'state=${by('state').value} fruit=${by('fruit').value}',
    );
    expect(by('name').value, 'Bob Builder');
    expect(by('notes').value, 'First line\nIt’s “quoted” — ok – fine');
    expect(by('agree').value, isNot('Off'));
    expect(by('color').value, 'blue');
    expect(by('state').value, 'NY');
    expect(by('fruit').value, 'Plum');

    await menu(t, 'Save');
    await wait(t, 1500);
    await shot(t, '11_saved');
    expect(qa.session.dirty, isFalse);

    final docs = await docsDir();
    final orig = await File('$docs/qa/form.pdf').readAsBytes();
    final saved = await File('$docs/form.pdf').readAsBytes();
    var prefix = saved.length > orig.length;
    for (var i = 0; prefix && i < orig.length; i++) {
      if (orig[i] != saved[i]) prefix = false;
    }
    log(
      'SAVE IN PLACE: orig ${orig.length} saved ${saved.length} prefix=$prefix',
    );
    expect(prefix, isTrue);
    final re = PdfEditDoc.open(saved);
    expect(
      re.fields.firstWhere((f) => f.fullName == 'name').value,
      'Bob Builder',
    );
    final tmp = Directory(docs).listSync().map((e) => e.path).toList();
    log('Documents after save: $tmp');
  });

  qaTest('text field tap target covers the whole field box', (t) async {
    await startApp(t);
    await openFromBrowse(t, ['qa', 'form.pdf']);
    await until(t, find.byKey(const ValueKey('edit-button')));
    await wait(t, 1200);
    await t.tap(find.byKey(const ValueKey('edit-button')));
    await wait(t, 800);
    final tf = find.byType(TextField).first;
    final box = t.getRect(
      find.ancestor(of: tf, matching: find.byType(Container)).first,
    );
    final inner = t.getRect(tf);
    log('name box $box textfield $inner');
    bool focused() =>
        FocusManager.instance.primaryFocus?.context
                ?.findAncestorWidgetOfExactType<TextField>() !=
            null ||
        FocusManager.instance.primaryFocus?.context?.widget is EditableText;
    await t.tapAt(Offset(box.center.dx, box.top + 1.5));
    await wait(t, 800);
    final topEdge = focused();
    FocusManager.instance.primaryFocus?.unfocus();
    await wait(t, 600);
    await t.tapAt(box.center);
    await wait(t, 800);
    final center = focused();
    log('TAP TARGET: focus from box top edge=$topEdge, from center=$center');
    FocusManager.instance.primaryFocus?.unfocus();
    await wait(t, 500);
  });
}
