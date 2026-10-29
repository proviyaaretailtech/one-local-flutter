import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/ui/motion.dart';
import 'package:vinii_pos/ui/theme.dart';

// The app's motion (founder's reference video, 29 Oct 2026): sections build in one after another, dialogs blur the page behind them,
// toasts are a dark pill that can carry Undo, and all of it is still when the phone asks for less motion.

Future<void> show(WidgetTester t, Widget w, {bool calm = false}) => t.pumpWidget(MaterialApp(
      theme: posTheme(),
      home: MediaQuery(data: MediaQueryData(disableAnimations: calm), child: Scaffold(body: w)),
    ));

double opacityOf(WidgetTester t, String text) =>
    t.widget<Opacity>(find.ancestor(of: find.text(text), matching: find.byType(Opacity)).first).opacity;

void main() {
  testWidgets('sections build in one after another and settle fully shown', (t) async {
    await show(t, Column(children: staggered([const Text('first'), const Text('second'), const Text('third')])));
    await t.pump(const Duration(milliseconds: 120));
    expect(opacityOf(t, 'first'), greaterThan(opacityOf(t, 'third'))); // the later one starts later
    await t.pumpAndSettle();
    for (final s in ['first', 'second', 'third']) {
      expect(opacityOf(t, s), 1);
    }
  });

  testWidgets('with reduce motion on, sections are shown at once', (t) async {
    await show(t, Column(children: staggered([const Text('first'), const Text('second')])), calm: true);
    await t.pump();
    expect(opacityOf(t, 'second'), 1);
  });

  testWidgets('a dialog blurs the page behind it and closes on a tap outside', (t) async {
    await show(t, Builder(builder: (c) => TextButton(onPressed: () => showOlDialog<void>(context: c, builder: (_) => const AlertDialog(content: Text('Sure?'))), child: const Text('open'))));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.text('Sure?'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsOneWidget);
    await t.tapAt(const Offset(10, 10));
    await t.pumpAndSettle();
    expect(find.text('Sure?'), findsNothing);
  });

  testWidgets('a toast can carry Undo', (t) async {
    var undone = false;
    await show(t, Builder(builder: (c) => TextButton(onPressed: () => showToast(c, 'Paneer removed', actionLabel: 'Undo', onAction: () => undone = true), child: const Text('remove'))));
    await t.tap(find.text('remove'));
    await t.pumpAndSettle();
    expect(find.text('Paneer removed'), findsOneWidget);
    await t.tap(find.text('Undo'));
    await t.pumpAndSettle();
    expect(undone, isTrue);
  });
}
