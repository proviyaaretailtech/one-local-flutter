import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/orders/order_widgets.dart';
import 'package:vinii_pos/ui/ol_guide.dart';
import 'package:vinii_pos/ui/ol_mascot.dart';
import 'package:vinii_pos/ui/theme.dart';

Future<void> bar(WidgetTester t) async {
  t.view.physicalSize = const Size(780, 1600);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: Scaffold(body: const SizedBox.expand(), bottomNavigationBar: PosBottomNav(onTap: (_) {}))));
}

void main() {
  testWidgets('Ol sits in the bottom bar\'s empty circle and says hello once; closing it is remembered', (t) async {
    SharedPreferences.setMockInitialValues({});
    olGreets = true;
    addTearDown(() => olGreets = false);
    await bar(t);
    expect(find.byType(OlMascot), findsOneWidget);
    await t.pump(const Duration(seconds: 1));
    expect(find.byKey(const ValueKey('ol-hello')), findsOneWidget);
    expect(find.textContaining("Hi, I'm Ol!"), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('ol-hello-close')));
    await t.pump();
    expect(find.byKey(const ValueKey('ol-hello')), findsNothing);
    expect((await SharedPreferences.getInstance()).getBool('ol_hello_seen'), isTrue);
    // another page's bar: no second hello
    await t.pumpWidget(const SizedBox());
    await bar(t);
    await t.pump(const Duration(seconds: 2));
    expect(find.byKey(const ValueKey('ol-hello')), findsNothing);
  });

  testWidgets('tapping Ol opens the helper: common jobs, and what you type finds the screen for it', (t) async {
    await bar(t);
    await t.tap(find.byKey(const ValueKey('ol-mascot')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('ol-sheet')), findsOneWidget);
    expect(find.byKey(const ValueKey('ol-job-Receive goods')), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('ol-ask')), 'zzzz nothing');
    await t.pump();
    expect(find.textContaining("I can't do that yet"), findsOneWidget);
    // what Ol finds, Ol opens
    final opened = <String>[];
    HomeNav.stock = (_) => opened.add('stock');
    addTearDown(HomeNav.reset);
    await t.enterText(find.byKey(const ValueKey('ol-ask')), 'stock');
    await t.pump();
    // the walkthrough is offered first, then the screens Ol knows
    expect(find.byKey(const ValueKey('ol-tour-Check stock')), findsOneWidget);
    final hit = find.byWidgetPredicate((w) => w is ListTile && '${w.key}'.contains('ol-hit-'));
    expect(hit, findsWidgets);
    await t.tap(hit.first);
    await t.pumpAndSettle();
    expect(opened, isNotEmpty);
    expect(find.byKey(const ValueKey('ol-sheet')), findsNothing);
  });

  test('Ol keeps still under flutter test, so screens settle', () => expect(olAnimates, isFalse));

  group('Ol shows the way', () {
    // a two-page app: Go on the first page opens the second, which has Save
    Widget app() => MaterialApp(
          theme: posTheme(),
          home: Builder(
            builder: (c) => Scaffold(
              body: Center(
                child: TextButton(
                  key: const ValueKey('go'),
                  onPressed: () => Navigator.of(c).push(MaterialPageRoute(
                    builder: (_) => Scaffold(body: Center(child: ElevatedButton(key: const ValueKey('save'), onPressed: () {}, child: const Text('Save')))),
                  )),
                  child: const Text('Go'),
                ),
              ),
            ),
          ),
        );
    const tour = OlTour('Test job', [
      OlStep('Tap Go.', target: OlTarget.key('go')),
      OlStep('This is Save.', target: OlTarget.text('Save'), next: true),
      OlStep('All done.'),
    ]);
    OverlayState overlayOf(WidgetTester t) => t.state<OverlayState>(find.byType(Overlay).first);

    testWidgets('lights up the target, lets only it be tapped, follows to the next screen, then Next and Done', (t) async {
      t.view.physicalSize = const Size(780, 1600);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      addTearDown(() => OlGuide.current?.stop());
      await t.pumpWidget(app());
      OlGuide.start(overlayOf(t), tour);
      await t.pump(const Duration(milliseconds: 200));
      expect(find.text('Tap Go.'), findsOneWidget);
      expect(find.textContaining('Step 1 of 3'), findsOneWidget);
      // outside the light, a tap is stopped
      await t.tapAt(const Offset(20, 20));
      await t.pump(const Duration(milliseconds: 600));
      expect(OlGuide.current!.step, 0);
      // on the light, the tap goes through: the next page opens and Ol moves on
      await t.tap(find.byKey(const ValueKey('go')), warnIfMissed: false);
      await t.pump(const Duration(milliseconds: 500));
      await t.pump(const Duration(milliseconds: 500));
      await t.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const ValueKey('save')), findsOneWidget);
      expect(OlGuide.current!.step, 1);
      expect(find.text('This is Save.'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('ol-guide-next')));
      await t.pump(const Duration(milliseconds: 200));
      expect(find.text('All done.'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('ol-guide-next'))); // Done
      await t.pump();
      expect(OlGuide.current, isNull);
      expect(find.byKey(const ValueKey('ol-guide-bubble')), findsNothing);
    });

    testWidgets('Skip ends it; a target that is not on this screen says so and offers Next', (t) async {
      t.view.physicalSize = const Size(780, 1600);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      addTearDown(() => OlGuide.current?.stop());
      final misses = OlGuide.missesBeforeLost;
      OlGuide.missesBeforeLost = 2;
      addTearDown(() => OlGuide.missesBeforeLost = misses);
      await t.pumpWidget(app());
      OlGuide.start(overlayOf(t), const OlTour('Lost', [OlStep('Tap Nowhere.', target: OlTarget.key('nowhere')), OlStep('End.')]));
      await t.pump(const Duration(milliseconds: 200));
      await t.pump(const Duration(milliseconds: 200));
      await t.pump(const Duration(milliseconds: 200));
      expect(find.textContaining("I can't see it on this screen"), findsOneWidget);
      expect(find.byKey(const ValueKey('ol-guide-next')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('ol-guide-skip')));
      await t.pump();
      expect(OlGuide.current, isNull);
    });

    testWidgets('a job in Ol starts its walkthrough', (t) async {
      addTearDown(() => OlGuide.current?.stop());
      await bar(t);
      await t.tap(find.byKey(const ValueKey('ol-mascot')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('ol-job-Make a bill')));
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 200));
      }
      expect(find.byKey(const ValueKey('ol-sheet')), findsNothing);
      expect(OlGuide.current, isNotNull);
      expect(find.textContaining('Make a bill'), findsWidgets);
      expect(find.text('Tap Bill at the bottom. It opens the till.'), findsOneWidget);
      OlGuide.current!.stop(); // its timer must not outlive the test
      await t.pump();
    });
  });
}
