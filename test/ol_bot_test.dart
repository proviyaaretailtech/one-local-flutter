import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/assistant/ol_bot.dart';
import 'package:vinii_pos/home/app_shell.dart';
import 'package:vinii_pos/home/home_nav.dart';

import 'helpers.dart';

Widget? _roots(String kind, String label) => Scaffold(body: Center(child: Text('root $kind $label')));

Future<void> _shell(WidgetTester t, String kind) async {
  await show(t, Builder(builder: (c) => TextButton(onPressed: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => AppShell(rootFor: _roots, initialKind: kind))), child: const Text('enter'))));
  await t.tap(find.text('enter'));
  await t.pumpAndSettle();
}

void main() {
  tearDown(HomeNav.reset);

  group('Ol on the bar', () {
    testWidgets('the restaurant bar ends with Ol; the store bar does not have it', (t) async {
      await _shell(t, 'restaurant');
      expect(find.byKey(const ValueKey('ol-bot')), findsOneWidget);
      final bar = t.getRect(find.byKey(const ValueKey('tab-Orders')));
      expect(t.getRect(find.byKey(const ValueKey('ol-bot'))).left, greaterThan(bar.right - 1), reason: 'after the last tab');
      await t.pumpWidget(const SizedBox());
      await _shell(t, 'store');
      expect(find.byKey(const ValueKey('ol-bot')), findsNothing);
    });

    testWidgets('Ol says a tip for the tab on screen, once per tab; ✕ closes it', (t) async {
      await _shell(t, 'restaurant');
      expect(find.byKey(const ValueKey('ol-bubble')), findsOneWidget);
      expect(find.textContaining("Today's sales and orders"), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('ol-bubble-close')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('ol-bubble')), findsNothing);
      await t.tap(find.byKey(const ValueKey('tab-Bill')));
      await t.pumpAndSettle();
      expect(find.textContaining('Choose a table, then tap dishes'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('tab-Home')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('ol-bubble')), findsNothing, reason: 'Home already had its tip');
    });

    testWidgets('tap Ol: Ask Ol greets, offers quick actions for this tab, answers with steps and takes you there', (t) async {
      await _shell(t, 'restaurant');
      await t.tap(find.byKey(const ValueKey('ol-bot')));
      await t.pumpAndSettle();
      expect(find.text('Ask Ol'), findsOneWidget);
      expect(find.textContaining("I'm Ol"), findsWidgets);
      expect(find.text('Split a bill'), findsOneWidget, reason: 'a Home quick action');
      await t.tap(find.text('Split a bill'));
      await t.pumpAndSettle();
      expect(find.textContaining('Split the bill'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('ol-go-Bill')));
      await t.pumpAndSettle();
      expect(find.text('Ask Ol'), findsNothing);
      expect(find.text('root restaurant Bill'), findsOneWidget);
    });

    testWidgets('a typed question gets an answer; one Ol does not know says what it can help with', (t) async {
      await _shell(t, 'restaurant');
      await t.tap(find.byKey(const ValueKey('ol-bot')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('ol-ask')), 'where do I see food cost of my recipes?');
      await t.tap(find.byKey(const ValueKey('ol-send')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('ol-go-Menu')), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('ol-ask')), 'what is the weather');
      await t.tap(find.byKey(const ValueKey('ol-send')));
      await t.pumpAndSettle();
      expect(find.textContaining("I'm not sure about that one yet"), findsOneWidget);
    });
  });

  group('OlGuide', () {
    const g = OlGuide();
    test('questions find the right place', () {
      final want = {
        'Take an order': 'Bill',
        'how do I send to kitchen': 'Bill',
        'Takeaway on a table': 'Bill',
        'split a bill by cash and upi': 'Bill',
        'Ready to serve': 'Bill',
        'Add a table': 'Bill',
        'Add a dish': 'Menu',
        'AI picture': 'Menu',
        'Recipe costs': 'Menu',
        'Mark out of stock': 'Menu',
        'Track an order': 'Orders',
        "Today's sales": 'Home',
        'change outlet hours in settings': 'Home',
      };
      for (final e in want.entries) {
        expect(g.answer(e.key).tab, e.value, reason: e.key);
      }
      expect(g.answer('Takeaway on a table').text, contains('same bill'));
      expect(g.answer('blah').tab, isNull);
    });

    test('every tab has a tip and quick actions, and every quick action has an answer', () {
      for (final tab in ['Home', 'Menu', 'Bill', 'Orders']) {
        expect(g.tipFor(tab), isNotNull, reason: tab);
        for (final q in g.quickFor(tab)) {
          expect(g.answer(q).tab, isNotNull, reason: '$tab · $q');
        }
      }
    });

    test('the greeting follows the time of day', () {
      expect(g.greeting('Bill', DateTime(2026, 10, 27, 9)), startsWith('Good morning'));
      expect(g.greeting('Bill', DateTime(2026, 10, 27, 14)), startsWith('Good afternoon'));
      expect(g.greeting('Bill', DateTime(2026, 10, 27, 20)), contains('on Bill'));
    });
  });
}
