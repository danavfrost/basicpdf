// iOS QA: password flows, New → Save As → reopen → edit → Save, Fields tool,
// unsaved guard / ways back to Home, About, pinch zoom, large PDF.
// Seed (done by the QA runner): Documents/form.pdf, Documents/qa/<fixtures>,
// Documents/qa/big600.pdf (600 pages), Documents/qa/plain3.pdf (no fields).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pdfedit/core/pdf_core.dart';

import 'ios_helpers.dart';

bool isPrefix(Uint8List a, Uint8List b) {
  if (b.length <= a.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Finder dialogField() => find.descendant(
  of: find.byType(AlertDialog),
  matching: find.byType(TextField),
);

Future<void> saveAsDialog(WidgetTester t, String name) async {
  await until(t, find.text('Save As'));
  await t.enterText(dialogField(), name);
  await wait(t, 400);
  await t.tap(find.widgetWithText(FilledButton, 'Save'));
  await wait(t, 1500);
}

Future<void> closeDoc(WidgetTester t) async {
  await t.tap(find.byTooltip('Close'));
  await wait(t, 800);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  qaDone();

  qaTest('user password: wrong, cancel, right; saved copy still locked', (
    t,
  ) async {
    final qa = await startApp(t);
    await openFromBrowse(t, ['qa', 'form_aes256.pdf']);
    await until(t, find.byKey(const ValueKey('password-field')));
    await shot(t, '20_pw_dialog');
    await t.enterText(find.byKey(const ValueKey('password-field')), 'nope');
    await t.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Open'),
      ),
    );
    await wait(t, 1200);
    expect(find.text('Wrong password. Try again.'), findsOneWidget);
    await shot(t, '21_pw_wrong');
    await t.tap(find.widgetWithText(TextButton, 'Cancel'));
    await wait(t, 1000);
    log(
      'after cancel: hasDocument=${qa.session.hasDocument} '
      'homeVisible=${find.byKey(const ValueKey('home-open')).evaluate().isNotEmpty}',
    );
    expect(qa.session.hasDocument, isFalse);
    await shot(t, '22_pw_cancelled');

    await openFromBrowse(t, ['qa', 'form_aes256.pdf']);
    await until(t, find.byKey(const ValueKey('password-field')));
    await t.enterText(find.byKey(const ValueKey('password-field')), 'user');
    await t.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Open'),
      ),
    );
    await until(t, find.byKey(const ValueKey('edit-button')));
    await wait(t, 1500);
    await shot(t, '23_pw_opened');
    await t.tap(find.byKey(const ValueKey('edit-button')));
    await wait(t, 800);
    await t.enterText(find.byType(TextField).first, 'Encrypted edit');
    await t.tap(find.byKey(const ValueKey('done-button')));
    await wait(t, 2500);
    await menu(t, 'Save As');
    await saveAsDialog(t, 'qa_aes_saved');
    final docs = await docsDir();
    final orig = await File('$docs/qa/form_aes256.pdf').readAsBytes();
    final saved = await File('$docs/qa_aes_saved.pdf').readAsBytes();
    log('aes256 saved ${saved.length} prefix=${isPrefix(orig, saved)}');
    expect(isPrefix(orig, saved), isTrue);
    expect(() => PdfEditDoc.open(saved), throwsA(isA<PdfPasswordException>()));
    final re = PdfEditDoc.open(saved, password: 'user');
    expect(
      re.fields.firstWhere((f) => f.fullName == 'name').value,
      'Encrypted edit',
    );
    log('aes256 saved copy needs password: OK; title=${qa.session.title}');
    await closeDoc(t);
  });

  qaTest('owner-only lock → unlock → edit → Save As keeps restriction', (
    t,
  ) async {
    final qa = await startApp(t);
    await openFromBrowse(t, ['qa', 'form_aes128_owneronly.pdf']);
    await until(t, find.byKey(const ValueKey('edit-button')));
    await wait(t, 1500);
    log('locked=${qa.session.isLocked}');
    expect(qa.session.isLocked, isTrue);
    await shot(t, '24_owner_locked');
    await t.tap(find.byKey(const ValueKey('edit-button')));
    await until(t, find.text('Editing is restricted'));
    await shot(t, '25_owner_dialog');
    await t.enterText(find.byKey(const ValueKey('password-field')), 'user');
    await t.tap(find.widgetWithText(FilledButton, 'Unlock'));
    await wait(t, 1000);
    log(
      'wrong owner pw shown: ${find.text('Wrong password. Try again.').evaluate().isNotEmpty}',
    );
    await t.enterText(find.byKey(const ValueKey('password-field')), 'owner');
    await t.tap(find.widgetWithText(FilledButton, 'Unlock'));
    await wait(t, 1200);
    expect(find.byKey(const ValueKey('done-button')), findsOneWidget);
    await t.enterText(find.byType(TextField).first, 'Owner edit');
    await t.tap(find.byKey(const ValueKey('done-button')));
    await wait(t, 2500);
    await shot(t, '26_owner_after_done');
    await menu(t, 'Save As');
    await saveAsDialog(t, 'qa_owner_saved');
    final docs = await docsDir();
    final saved = await File('$docs/qa_owner_saved.pdf').readAsBytes();
    final re = PdfEditDoc.open(saved);
    log(
      'owner saved: encrypted=${re.isEncrypted} canEdit=${re.permissions.canEditFields} '
      'name=${re.fields.firstWhere((f) => f.fullName == 'name').value}',
    );
    expect(re.isEncrypted, isTrue);
    expect(re.permissions.canEditFields, isFalse);
    expect(
      re.fields.firstWhere((f) => f.fullName == 'name').value,
      'Owner edit',
    );
    await closeDoc(t);
    // Reopen the saved copy: still restricted.
    await openFromBrowse(t, ['qa_owner_saved.pdf']);
    await until(t, find.byKey(const ValueKey('edit-button')));
    await wait(t, 1000);
    log('reopened saved copy locked=${qa.session.isLocked}');
    expect(qa.session.isLocked, isTrue);
    await closeDoc(t);
  });

  qaTest('New → multi-page text → ✓ → Save As → reopen → edit → Save', (
    t,
  ) async {
    final qa = await startApp(t);
    await t.tap(find.byKey(const ValueKey('home-new')));
    await wait(t, 800);
    await shot(t, '30_new_draft');
    await t.tap(find.byKey(const ValueKey('edit-button')));
    await wait(t, 1000);
    final sb = StringBuffer();
    for (var i = 1; i <= 120; i++) {
      sb.writeln('Line $i — it’s “smart” text… with a dash – and ‘quotes’.');
    }
    final text = sb.toString().trimRight();
    await t.enterText(find.byKey(const ValueKey('draft-field')), text);
    await wait(t, 800);
    await shot(t, '31_new_typed');
    await t.tap(find.byKey(const ValueKey('done-button')));
    await wait(t, 3000);
    final doc = qa.session.editDoc!;
    log(
      'new doc pages=${doc.pages.length} fields=${doc.fields.map((f) => f.fullName).toList()}',
    );
    expect(doc.pages.length, greaterThan(1));
    await shot(t, '32_new_committed');
    // Edit again before saving: should be fields now.
    await menu(t, 'Save');
    await saveAsDialog(t, 'qa_new');
    final docs = await docsDir();
    final f = File('$docs/qa_new.pdf');
    expect(await f.exists(), isTrue);
    final firstSave = await f.readAsBytes();
    final reDoc = PdfEditDoc.open(firstSave);
    final joined = reDoc.fields.map((f) => f.value).join('\n');
    log(
      'reparsed text equal=${joined.replaceAll('\n', ' ').replaceAll(RegExp(r'\s+'), ' ') == text.replaceAll('\n', ' ').replaceAll(RegExp(r'\s+'), ' ')} '
      'len ${joined.length} vs ${text.length}',
    );
    await closeDoc(t);
    await shot(t, '33_home_recent');
    await until(t, find.text('qa_new.pdf'));
    await t.tap(find.text('qa_new.pdf'));
    await until(t, find.byKey(const ValueKey('edit-button')));
    await wait(t, 1500);
    await t.tap(find.byKey(const ValueKey('edit-button')));
    await wait(t, 1000);
    await shot(t, '34_new_reopened_edit');
    final tf = find.byType(TextField).first;
    await t.enterText(tf, 'Edited first page.\nSecond line.');
    await t.tap(find.byKey(const ValueKey('done-button')));
    await wait(t, 2500);
    await menu(t, 'Save');
    await wait(t, 1000);
    final second = await f.readAsBytes();
    log(
      'new doc resave prefix=${isPrefix(firstSave, second)} ${firstSave.length}->${second.length}',
    );
    expect(isPrefix(firstSave, second), isTrue);
    expect(
      PdfEditDoc.open(second).fields.first.value,
      'Edited first page.\nSecond line.',
    );
    await shot(t, '35_new_resaved');
    await closeDoc(t);
  });

  qaTest('Fields tool: add text/checkbox, move, resize, multiline, delete', (
    t,
  ) async {
    final qa = await startApp(t);
    await openFromBrowse(t, ['qa', 'plain3.pdf']);
    await until(t, find.byKey(const ValueKey('edit-button')));
    await wait(t, 1200);
    await t.tap(find.byKey(const ValueKey('edit-button')));
    await wait(t, 800);
    expect(
      find.text('No fillable fields — tap Fields to add text boxes.'),
      findsOneWidget,
    );
    await shot(t, '40_no_fields_hint');
    await t.tap(find.byKey(const ValueKey('fields-button')));
    await wait(t, 600);
    await t.tap(find.byKey(const ValueKey('add-text')));
    await wait(t, 400);
    final draw = find.byKey(const ValueKey('draw')).first;
    final page = t.getRect(draw);
    log('page1 rect $page');
    final start = page.topLeft + const Offset(40, 120);
    final g = await t.startGesture(start);
    for (var i = 0; i < 15; i++) {
      await g.moveBy(const Offset(10, 3));
      await t.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await wait(t, 600);
    await shot(t, '41_text_added');
    await t.tap(find.byKey(const ValueKey('add-check')));
    await wait(t, 400);
    await t.tapAt(page.topLeft + const Offset(60, 220));
    await wait(t, 600);
    log(
      'tool after placing a checkbox: '
      '${find.text('Tap the page to place it').evaluate().isNotEmpty ? 'still checkbox' : 'back to select'}',
    );
    if (find.text('Tap the page to place it').evaluate().isEmpty) {
      await t.tap(find.byKey(const ValueKey('add-check')));
      await wait(t, 400);
    }
    await t.tapAt(page.topLeft + const Offset(140, 220));
    await wait(t, 600);
    await shot(t, '42_checks_added');
    final boxes = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key as ValueKey<String>).value.startsWith('box:'),
    );
    log(
      'layout boxes: ${boxes.evaluate().map((e) => (e.widget.key as ValueKey).value).toList()} '
      'tool=${find.text('Tap a field to move, resize or delete').evaluate().isNotEmpty ? 'select' : '?'}',
    );
    // Back to select tool if still in checkbox mode.
    if (find.text('Tap the page to place it').evaluate().isNotEmpty) {
      await t.tap(find.byKey(const ValueKey('add-check')));
      await wait(t, 400);
    }
    // Select + delete the second checkbox.
    await t.tapAt(page.topLeft + const Offset(140, 220));
    await wait(t, 500);
    await shot(t, '43_check_selected');
    final del = find.byTooltip('Delete field');
    log('delete button present: ${del.evaluate().isNotEmpty}');
    await t.tap(del);
    await wait(t, 500);
    // Select text box, move it, resize it, make it multi-line.
    final textCenter = start + const Offset(75, 22);
    await t.tapAt(textCenter);
    await wait(t, 500);
    final mv = await t.startGesture(textCenter);
    for (var i = 0; i < 10; i++) {
      await mv.moveBy(const Offset(2, 4));
      await t.pump(const Duration(milliseconds: 16));
    }
    await mv.up();
    await wait(t, 400);
    final br = find.byKey(const ValueKey('handle:br'));
    await t.drag(br, const Offset(30, 40));
    await wait(t, 400);
    final ml = find.byTooltip('Single line (tap for multi-line)');
    log('multiline toggle present: ${ml.evaluate().isNotEmpty}');
    await t.tap(ml);
    await wait(t, 500);
    await shot(t, '44_text_moved_resized_multiline');
    await t.tap(find.byKey(const ValueKey('done-button')));
    await wait(t, 2500);
    final fields = qa.session.editDoc!.fields;
    log(
      'after ✓ fields: ${fields.map((f) => '${f.fullName}:${f.kind}:${f.rect}').toList()}',
    );
    expect(fields.length, 2);
    expect(fields.where((f) => f.kind == PdfFieldKind.multilineText).length, 1);
    expect(fields.where((f) => f.kind == PdfFieldKind.checkbox).length, 1);
    await shot(t, '45_fields_applied');
    await menu(t, 'Save As');
    await saveAsDialog(t, 'qa_fields');
    await closeDoc(t);
    await until(t, find.text('qa_fields.pdf'));
    await t.tap(find.text('qa_fields.pdf'));
    await until(t, find.byKey(const ValueKey('edit-button')));
    await wait(t, 1200);
    log(
      'reopened fields: ${qa.session.editDoc!.fields.map((f) => '${f.fullName}:${f.kind}').toList()}',
    );
    expect(qa.session.editDoc!.fields.length, 2);
    await t.tap(find.byKey(const ValueKey('edit-button')));
    await wait(t, 800);
    await t.enterText(find.byType(TextField).first, 'Typed into\nnew box');
    await t.tap(byTypeName('_CheckBox').first);
    await t.tap(find.byKey(const ValueKey('done-button')));
    await wait(t, 2500);
    await shot(t, '46_new_fields_filled');
    await menu(t, 'Save');
    await wait(t, 1000);
    final saved = PdfEditDoc.open(
      await File('${await docsDir()}/qa_fields.pdf').readAsBytes(),
    );
    log(
      'qa_fields saved values: ${saved.fields.map((f) => '${f.fullName}=${f.value}').toList()}',
    );
    await closeDoc(t);
  });

  qaTest('unsaved guard on New/Open/Close; About; ways back', (t) async {
    final qa = await startApp(t);
    await openFromBrowse(t, ['qa', 'form.pdf']);
    await until(t, find.byKey(const ValueKey('edit-button')));
    await wait(t, 1000);
    await t.tap(find.byKey(const ValueKey('edit-button')));
    await wait(t, 600);
    await t.enterText(find.byType(TextField).first, 'dirty');
    await t.tap(find.byKey(const ValueKey('done-button')));
    await wait(t, 2000);
    expect(qa.session.dirty, isTrue);
    await menu(t, 'New');
    expect(find.text('Save changes?'), findsOneWidget);
    await shot(t, '50_unsaved_new');
    await t.tap(find.widgetWithText(TextButton, 'Cancel'));
    await wait(t, 500);
    expect(qa.session.isDraft, isFalse);
    await menu(t, 'Open');
    expect(find.text('Save changes?'), findsOneWidget);
    await t.tap(find.widgetWithText(TextButton, 'Cancel'));
    await wait(t, 500);
    await closeDoc(t);
    expect(find.text('Save changes?'), findsOneWidget);
    await t.tap(find.widgetWithText(TextButton, 'Discard'));
    await wait(t, 800);
    expect(qa.session.hasDocument, isFalse);
    expect(find.byKey(const ValueKey('home-open')), findsOneWidget);
    // Pending (un-✓'d) edits + New from a draft.
    await t.tap(find.byKey(const ValueKey('home-new')));
    await wait(t, 600);
    await t.tap(find.byKey(const ValueKey('edit-button')));
    await wait(t, 600);
    await t.enterText(find.byKey(const ValueKey('draft-field')), 'draft text');
    await wait(t, 300);
    log(
      'draft editing: close button present=${find.byTooltip('Close').evaluate().isNotEmpty} '
      'menu present=${find.byKey(const ValueKey('overflow-menu')).evaluate().isNotEmpty}',
    );
    await t.tap(find.byKey(const ValueKey('done-button')));
    await wait(t, 2000);
    await closeDoc(t);
    log(
      'draft close → dialog=${find.text('Save changes?').evaluate().isNotEmpty}',
    );
    await t.tap(find.widgetWithText(TextButton, 'Discard'));
    await wait(t, 800);
    // About + licenses + back.
    await menu(t, 'About');
    await shot(t, '51_about');
    await t.tap(find.text('Licenses'));
    await wait(t, 2000);
    await shot(t, '52_licenses');
    final back = find.byType(BackButton);
    log('licenses back button: ${back.evaluate().length}');
    await t.tap(back.first);
    await wait(t, 1000);
    await t.tap(find.text('OK'));
    await wait(t, 600);
    // Open dialog close button.
    await t.tap(find.byKey(const ValueKey('home-open')));
    await wait(t, 800);
    await shot(t, '53_open_recent');
    await t.tap(find.text('History'));
    await wait(t, 800);
    await shot(t, '54_open_history');
    await t.tap(find.text('Browse'));
    await wait(t, 1200);
    await shot(t, '55_open_browse');
    await t.tap(find.byTooltip('Close'));
    await wait(t, 800);
    expect(find.byKey(const ValueKey('home-open')), findsOneWidget);
  });

  qaTest('pinch zoom with overlays', (t) async {
    final qa = await startApp(t);
    await openFromBrowse(t, ['qa', 'form.pdf']);
    await until(t, find.byKey(const ValueKey('edit-button')));
    await wait(t, 1500);
    await t.tap(find.byKey(const ValueKey('edit-button')));
    await wait(t, 800);
    final tf = find.byType(TextField).first;
    final before = t.getRect(tf);
    final pageBox = t.getRect(find.byType(RawImage).first);
    log('before zoom: field $before page $pageBox');
    final a = await t.startGesture(const Offset(150, 300), pointer: 11);
    final b = await t.startGesture(const Offset(230, 380), pointer: 12);
    for (var i = 0; i < 20; i++) {
      await a.moveBy(const Offset(-4, -4));
      await b.moveBy(const Offset(4, 4));
      await t.pump(const Duration(milliseconds: 16));
    }
    await a.up();
    await b.up();
    await wait(t, 1500);
    final after = t.getRect(tf);
    final pageAfter = t.getRect(find.byType(RawImage).first);
    final s = pageAfter.width / pageBox.width;
    final relBefore = (before.topLeft - pageBox.topLeft);
    final relAfter = (after.topLeft - pageAfter.topLeft);
    log(
      'after zoom: scale=$s field $after page $pageAfter '
      'rel ${relBefore * s} vs $relAfter; width ${before.width * s} vs ${after.width}',
    );
    expect((relAfter - relBefore * s).distance, lessThan(2));
    await shot(t, '60_zoom_edit');
    await t.tap(find.byKey(const ValueKey('done-button')));
    await wait(t, 1500);
    await shot(t, '61_zoom_view');
    // Horizontal pan while zoomed.
    await t.drag(find.byType(RawImage).first, const Offset(-150, 0));
    await wait(t, 800);
    await shot(t, '62_zoom_panned');
    qa.session.close();
    await wait(t, 500);
  });

  qaTest('large PDF (600 pages): open time and scrolling', (t) async {
    final qa = await startApp(t);
    final sw = Stopwatch()..start();
    await openFromBrowse(t, ['qa', 'big600.pdf']);
    await until(t, find.byKey(const ValueKey('edit-button')), timeoutMs: 60000);
    final tOpen = sw.elapsedMilliseconds;
    await until(t, find.byType(RawImage), timeoutMs: 30000);
    log(
      'big600: edit-button after ${tOpen}ms (incl. ~2.8s of test waits), first page image after ${sw.elapsedMilliseconds}ms; '
      'editDoc=${qa.session.editDoc != null} pages=${qa.session.viewDoc?.pages.length}',
    );
    await shot(t, '70_big_open');
    final list = find.byType(Scrollable).first;
    final frames = <int>[];
    final sw2 = Stopwatch()..start();
    for (var i = 0; i < 15; i++) {
      final f0 = sw2.elapsedMilliseconds;
      await t.fling(list, const Offset(0, -600), 4000);
      frames.add(sw2.elapsedMilliseconds - f0);
      await wait(t, 200);
    }
    await wait(t, 5000);
    log(
      'bar visible after 5s idle: ${t.getRect(find.byKey(const ValueKey('edit-button'))).top}',
    );
    log('big600: 15 flings, per fling ms $frames');
    await shot(t, '71_big_scrolled');
    // Tap Edit on a 600-page plain file.
    final sw3 = Stopwatch()..start();
    await t.tap(find.byKey(const ValueKey('edit-button')));
    await until(t, find.byKey(const ValueKey('done-button')), timeoutMs: 30000);
    log('big600: edit mode entered in ${sw3.elapsedMilliseconds}ms');
    await shot(t, '72_big_edit');
    await t.tap(find.byKey(const ValueKey('done-button')));
    await wait(t, 500);
    qa.session.close();
    await wait(t, 500);
  });
}
