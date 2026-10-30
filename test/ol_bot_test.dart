// Ol, the restaurant app's helper (lib/assistant): in the bar, the hello once, a tip per tab once, Ask Ol (answers, Take me there,
// quick chips, not sure), and the walkthroughs (light the target, a tap inside moves on, a tap outside does nothing, Skip, can't see it).
// Animation is off in tests (test/flutter_test_config.dart), so nothing keeps the clock busy.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vinii_pos/assistant/ol_ask.dart';
import 'package:vinii_pos/assistant/ol_bot.dart';
import 'package:vinii_pos/assistant/ol_tour.dart';
import 'package:vinii_pos/home/app_shell.dart';
import 'package:vinii_pos/home/home_nav.dart';

import 'helpers.dart';

Widget? _roots(String kind, String label) => Scaffold(body: Center(child: Text('root $kind $label')));

Future<void> _shell(WidgetTester t, String kind) async {
  await show(t, Builder(builder: (c) => TextButton(onPressed: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => AppShell(rootFor: _roots, initialKind: kind))), child: const Text('enter'))));
  await t.tap(find.text('enter'));
  await t.pumpAndSettle();
}

const _hello = "Hi, I'm Ol! Tell me what you want to do, and I'll help you get it done.";

Future<void> _ask(WidgetTester t, String q) async {
  await t.enterText(find.byKey(const ValueKey('ol-ask')), q);
  await t.tap(find.byKey(const ValueKey('ol-send')));
  await t.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    HomeNav.reset();
    OlWalk.current?.stop();
  });

  group('Ol on the bar', () {
    testWidgets('the restaurant bar ends with Ol; tapping it opens Ask Ol; the store bar does not have this Ol', (t) async {
      await _shell(t, 'restaurant');
      expect(find.byKey(const ValueKey('ol-bot')), findsOneWidget);
      final last = t.getRect(find.byKey(const ValueKey('tab-Orders')));
      expect(t.getRect(find.byKey(const ValueKey('ol-bot'))).left, greaterThan(last.right - 1), reason: 'after the last tab');
      expect(find.bySemanticsLabel('Ol, your helper. Ask Ol.'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('ol-bot')));
      await t.pumpAndSettle();
      expect(find.text('Ask Ol'), findsOneWidget);
      expect(find.text('Your helper · finds anything in the app'), findsOneWidget);
      expect(find.textContaining("You're on Home. What do you need?"), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await _shell(t, 'store');
      expect(find.byKey(const ValueKey('ol-bot')), findsNothing);
    });

    testWidgets('the hello: said on the very first open, with ✕ to close it', (t) async {
      await _shell(t, 'restaurant');
      expect(find.text(_hello), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('ol-bubble-close')));
      await t.pumpAndSettle();
      expect(find.text(_hello), findsNothing);
    });

    testWidgets('the hello is not said again once it is stored on the device', (t) async {
      SharedPreferences.setMockInitialValues({'ol_hello_seen': true});
      await _shell(t, 'restaurant');
      expect(find.text(_hello), findsNothing);
    });

    testWidgets('a tab\'s tip on its first visit only; switching tab hides the old one at once', (t) async {
      SharedPreferences.setMockInitialValues({'ol_hello_seen': true});
      await _shell(t, 'restaurant');
      expect(find.textContaining("Today's sales, bills and kitchen are here"), findsOneWidget, reason: 'Home, first visit');
      await t.tap(find.byKey(const ValueKey('tab-Menu')));
      await t.pumpAndSettle();
      expect(find.textContaining("Today's sales, bills and kitchen are here"), findsNothing, reason: 'the old tab\'s tip goes');
      expect(find.textContaining('Quick add a dish here'), findsOneWidget, reason: 'Menu, first visit');
      await t.tap(find.byKey(const ValueKey('tab-Home')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('ol-bubble')), findsNothing, reason: 'Home already had its tip');
    });

    testWidgets('a tip already stored is never said again', (t) async {
      SharedPreferences.setMockInitialValues({'ol_hello_seen': true, 'ol_tips_said': ['Home']});
      await _shell(t, 'restaurant');
      expect(find.byKey(const ValueKey('ol-bubble')), findsNothing);
    });
  });

  group('Ask Ol', () {
    Future<void> open(WidgetTester t) async {
      SharedPreferences.setMockInitialValues({'ol_hello_seen': true, 'ol_tips_said': ['Home', 'Menu', 'Bill', 'Orders']});
      await _shell(t, 'restaurant');
      await t.tap(find.byKey(const ValueKey('ol-bot')));
      await t.pumpAndSettle();
    }

    testWidgets('"how do I split a bills" gets the split-a-bill steps, and Take me there switches to Bill', (t) async {
      await open(t);
      await _ask(t, 'how do I split a bills');
      expect(find.text('To split one bill across Cash, Card and UPI:'), findsOneWidget);
      expect(find.text('3. On Checkout tap Split Pay'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('ol-go-Bill')));
      await t.pumpAndSettle();
      expect(find.text('Ask Ol'), findsNothing, reason: 'the sheet closes');
      expect(find.text('root restaurant Bill'), findsOneWidget);
    });

    testWidgets('a quick chip asks its question', (t) async {
      await open(t);
      await t.tap(find.byKey(const ValueKey('ol-quick-add-a-dish')));
      await t.pumpAndSettle();
      expect(find.text('Add a dish'), findsWidgets);
      expect(find.text('To add a dish:'), findsOneWidget);
      expect(find.byKey(const ValueKey('ol-go-Menu')), findsOneWidget);
    });

    testWidgets('a question Ol does not know says what it can help with', (t) async {
      await open(t);
      await _ask(t, 'what is the weather like');
      expect(find.text(OlGuide.notSure), findsOneWidget);
    });

    testWidgets('"Show me how" chips before typing; typed words show the matching walkthrough; picking one starts it', (t) async {
      await open(t);
      for (final tour in olTours) {
        expect(find.byKey(ValueKey('ol-tour-${tour.name}')), findsOneWidget, reason: tour.name);
      }
      await t.enterText(find.byKey(const ValueKey('ol-ask')), 'split');
      await t.pump();
      expect(find.text('Show me how: Split a bill'), findsOneWidget);
      expect(find.text('5 steps, on your screen'), findsOneWidget);
      await t.tap(find.text('Show me how: Split a bill'));
      await t.pumpAndSettle();
      expect(find.text('Ask Ol'), findsNothing);
      expect(OlWalk.current?.tour.name, 'Split a bill');
      expect(find.text('Split a bill · Step 1 of 5'), findsOneWidget, reason: 'the Bill tab is lit');
      OlWalk.current!.stop();
    });
  });

  group('Show me how', () {
    late List<String> tapped;
    Future<OverlayState> screen(WidgetTester t) async {
      tapped = [];
      await show(t, Scaffold(
        body: Column(children: [
          const SizedBox(height: 100),
          ElevatedButton(key: const ValueKey('step-a'), onPressed: () => tapped.add('a'), child: const Text('First')),
          const SizedBox(height: 200),
          ElevatedButton(key: const ValueKey('step-b'), onPressed: () => tapped.add('b'), child: const Text('Second')),
        ]),
      ));
      return t.state<OverlayState>(find.byType(Overlay).first);
    }

    const tour = OlTour('Test job', [
      OlStep('Tap First.', target: OlTarget.key('step-a')),
      OlStep('Now tap Second.', target: OlTarget.text('Second')),
      OlStep('All done.'),
    ]);

    testWidgets('lights the first target; a tap outside does nothing; a tap inside goes through and moves to step 2', (t) async {
      final w = OlWalk.start(await screen(t), tour);
      await t.pump(const Duration(milliseconds: 200));
      expect(find.text('Test job · Step 1 of 3'), findsOneWidget);
      expect(find.text('Tap First.'), findsOneWidget);
      await t.tapAt(t.getCenter(find.byKey(const ValueKey('step-b'))));
      await t.pump(const Duration(milliseconds: 600));
      expect(tapped, isEmpty, reason: 'outside the hole nothing happens');
      expect(w.step, 0);
      await t.tapAt(t.getCenter(find.byKey(const ValueKey('step-a'))));
      await t.pump(const Duration(milliseconds: 500));
      expect(tapped, ['a'], reason: 'the tap reached the real button');
      await t.pump(const Duration(milliseconds: 200));
      expect(w.step, 1);
      expect(find.text('Now tap Second.'), findsOneWidget);
      w.stop();
    });

    testWidgets('Skip ends it', (t) async {
      OlWalk.start(await screen(t), tour);
      await t.pump(const Duration(milliseconds: 200));
      await t.tap(find.byKey(const ValueKey('ol-tour-skip')));
      await t.pump();
      expect(OlWalk.current, isNull);
      expect(find.byKey(const ValueKey('ol-tour-bubble')), findsNothing);
    });

    testWidgets('a target that never appears: "I can\'t see it" and Next after the wait', (t) async {
      final before = (OlWalk.pollEvery, OlWalk.missesBeforeLost);
      OlWalk.pollEvery = const Duration(milliseconds: 20);
      OlWalk.missesBeforeLost = 3;
      addTearDown(() {
        OlWalk.pollEvery = before.$1;
        OlWalk.missesBeforeLost = before.$2;
      });
      OlWalk.start(await screen(t), const OlTour('Lost job', [OlStep('Tap the missing thing.', target: OlTarget.key('not-here')), OlStep('Last.')]));
      await t.pump(const Duration(milliseconds: 10));
      expect(find.byKey(const ValueKey('ol-tour-bubble')), findsNothing, reason: 'no bubble while Ol is still looking');
      await t.pump(const Duration(milliseconds: 100));
      expect(find.textContaining("I can't see it on this screen. Go to the right screen, or tap Next."), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('ol-tour-next')));
      await t.pump();
      expect(find.text('Last.'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget, reason: 'the last step');
      await t.tap(find.byKey(const ValueKey('ol-tour-next')));
      await t.pump();
      expect(OlWalk.current, isNull);
    });
  });

  group('the guide', () {
    const g = OlGuide();
    test('words: lowercase, no punctuation or apostrophes, no one-letter words, "bills" → "bill"', () {
      expect(OlGuide.words("Where's my BILLS? a glass"), {'where', 'my', 'bill', 'glass'});
    });
    test('the best-matching topic wins', () {
      expect(g.answer('mark the paneer out of stock').tab, 'Menu');
      expect(g.answer('show me today sales report').tab, 'Home');
      expect(g.answer('takeaway parcel for table 4').text, contains('Takeaway'));
    });
    test('every tab has a tip and 3–4 quick questions; every walkthrough has steps', () {
      for (final tab in ['Home', 'Menu', 'Bill', 'Orders']) {
        expect(g.tipFor(tab), isNotNull, reason: tab);
        expect(g.quickFor(tab).length, inInclusiveRange(3, 4), reason: tab);
      }
      for (final tour in olTours) {
        expect(tour.steps, isNotEmpty);
      }
    });
  });
}
