// Android QA: New → long text (5+ pages) → ✓ → Save As (system picker,
// tapped from the host) → reopen from Recent → edit page 3 → overflow.
//
// Run with the host helper that reacts to "[QA] SHOT <name>" (screenshot)
// and "[QA] TAP <x> <y>" (adb input tap, physical pixels):
//   flutter test integration_test/android_newdoc_test.dart -d emulator-5554
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfedit/core/pdf_core.dart';
import 'package:pdfedit/main.dart';
import 'package:pdfedit/services/doc_session.dart';
import 'package:pdfedit/services/file_service.dart';
import 'package:pdfedit/services/history_store.dart';
import 'package:pdfedit/services/settings_store.dart';

void log(String s) => debugPrint('[QA] $s');

Future<void> wait(WidgetTester t, int ms) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// Waits without pumping frames (the app may be paused behind a picker).
Future<void> idle(WidgetTester t, int ms) =>
    t.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));

Future<void> shot(WidgetTester t, String name, {int settle = 800}) async {
  await wait(t, settle);
  log('SHOT $name');
  await wait(t, 1500);
}

String longText() {
  final b = StringBuffer();
  for (var p = 1; p <= 60; p++) {
    b.writeln(
      'Paragraph $p. Lorem ipsum dolor sit amet, consectetur '
      'adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore '
      'magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation.',
    );
    if (p % 5 == 0) b.writeln();
  }
  return b.toString().trimRight();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('long New doc, save as, reopen, overflow page 3', (t) async {
    final settings = SettingsStore(getApplicationSupportDirectory);
    await settings.load();
    final session = DocSession();
    final history = HistoryStore(getApplicationSupportDirectory);
    await t.pumpWidget(
      PdfEditApp(
        session: session,
        history: history,
        files: PlatformFileService(),
        settings: settings,
      ),
    );
    await wait(t, 1500);

    await t.tap(find.byKey(const ValueKey('home-new')));
    await wait(t, 800);
    await t.tap(find.byKey(const ValueKey('edit-button')));
    await wait(t, 800);
    final text = longText();
    await t.enterText(find.byKey(const ValueKey('draft-field')), text);
    await wait(t, 800);
    await shot(t, 'n1_draft');
    await t.tap(find.byKey(const ValueKey('done-button')));
    await wait(t, 3000);
    final doc = session.editDoc!;
    log(
      'pages=${doc.pages.length} fields=${doc.fields.map((f) => f.fullName).join(",")}',
    );
    final joined = doc.fields.map((f) => f.value).join('');
    log('chars in=${text.length} sum(field values)=${joined.length}');
    // Text lost at page boundaries (whitespace/newlines) is fine; words are not.
    final wordsIn = text.split(RegExp(r'\s+')).length;
    final wordsOut = doc.fields
        .map((f) => f.value.trim())
        .join(' ')
        .split(RegExp(r'\s+'))
        .length;
    log('words in=$wordsIn out=$wordsOut');
    expect(doc.pages.length, greaterThanOrEqualTo(5));
    await shot(t, 'n2_committed');

    // Save As → system create-document screen; host taps SAVE.
    await t.tap(find.byKey(const ValueKey('overflow-menu')));
    await wait(t, 800);
    await t.tap(find.text('Save As'));
    await t.pump();
    await idle(t, 3500);
    log('TAP 927 2274');
    await idle(t, 3500);
    await wait(t, 1500);
    log(
      'after save: title=${session.title} loc=${session.location?.ref} dirty=${session.dirty}',
    );
    expect(session.dirty, isFalse);
    final savedName = session.title;

    // Back to Home, reopen from Recent.
    await t.binding.handlePopRoute();
    await wait(t, 1500);
    await t.tap(find.text(savedName).first);
    await wait(t, 3000);
    log(
      'reopened: pages=${session.editDoc?.pages.length} encrypted=${session.editDoc?.isEncrypted}',
    );
    await t.tap(find.byKey(const ValueKey('edit-button')));
    await wait(t, 1000);

    final body3 = session.editDoc!.fields.firstWhere(
      (f) => f.fullName == 'Body3',
    );
    final before = body3.value;
    // Scroll page 3 into view then edit its text: prepend a marker and append
    // a lot more so it no longer fits the page field.
    final box = find.byKey(ValueKey('text:${body3.id}'));
    await t.scrollUntilVisible(
      box,
      400,
      scrollable: find.byType(Scrollable).last,
    );
    await wait(t, 800);
    final extra = List.filled(
      40,
      'OVERFLOW line added after reopening.',
    ).join('\n');
    await t.enterText(
      find.descendant(of: box, matching: find.byType(TextField)),
      'EDITED-P3 $before\n$extra',
    );
    await wait(t, 800);
    await shot(t, 'n3_p3_editing');
    FocusManager.instance.primaryFocus?.unfocus();
    await t.tap(find.byKey(const ValueKey('done-button')));
    await wait(t, 3000);
    final after = session.editDoc!.fields
        .firstWhere((f) => f.fullName == 'Body3')
        .value;
    log(
      'Body3 len before=${before.length} after=${after.length} '
      'startsWith marker=${after.startsWith('EDITED-P3')} '
      'endsWith extra=${after.endsWith('reopening.')}',
    );
    log(
      'Body4 starts: ${session.editDoc!.fields.firstWhere((f) => f.fullName == 'Body4').value.substring(0, 40)}',
    );
    log('pages after=${session.editDoc!.pages.length}');
    await shot(t, 'n4_p3_applied');
    // Scroll a bit to show the bottom of page 3 and top of page 4.
    await t.drag(find.byType(Scrollable).last, const Offset(0, -500));
    await wait(t, 800);
    await shot(t, 'n5_p3_bottom');

    // Save in place.
    await t.tap(find.byKey(const ValueKey('overflow-menu')));
    await wait(t, 800);
    await t.tap(find.text('Save'));
    await wait(t, 2500);
    log('final save: dirty=${session.dirty} loc=${session.location?.ref}');
    expect(session.dirty, isFalse);
    // Report the bytes so the host can compare with the file on disk.
    log('final bytes=${session.bytes!.length}');
    expect(
      PdfEditDoc.open(session.bytes!).fields.length,
      session.editDoc!.fields.length,
    );
  });
}
