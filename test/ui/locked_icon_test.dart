import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfedit/ui/viewer/viewer_screen.dart';

void main() {
  testWidgets('restricted Edit shows a small neutral lock, not a badge', (
    t,
  ) async {
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          appBar: AppBar(
            actions: [
              IconButton(
                onPressed: () {},
                icon: const LockedIcon(Icons.edit_outlined),
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.byType(Badge), findsNothing);
    final lock = t.getSize(find.byKey(const ValueKey('lock-overlay')));
    expect(lock.width, lessThanOrEqualTo(14));
    final deco =
        t
                .widget<DecoratedBox>(
                  find.byKey(const ValueKey('lock-overlay')),
                )
                .decoration
            as BoxDecoration;
    final scheme = Theme.of(t.element(find.byType(LockedIcon))).colorScheme;
    expect(deco.color, isNot(scheme.error));
    expect(deco.color, isNot(scheme.primary));
  });
}
