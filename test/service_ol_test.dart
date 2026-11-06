import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vinii_pos/assistant/ol_tour.dart';
import 'package:vinii_pos/service/manage_screen.dart';
import 'package:vinii_pos/service/service_money.dart';
import 'package:vinii_pos/service/service_ol.dart';

// Ol in the Service POS (founder, 3 Nov 2026): the store's character in the last slot of the service bar, a guide that takes you anywhere.

class _Host extends StatefulWidget {
  const _Host({required this.opened});
  final List<(String, Widget?)> opened;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  String tab = 'Home';
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Column(children: [
          for (final t in ['Home', 'Catalogue', 'Bill', 'Bookings']) TextButton(key: ValueKey('go-$t'), onPressed: () => setState(() => tab = t), child: Text('to $t')),
        ]),
        bottomNavigationBar: SizedBox(
          height: 80,
          child: Row(children: [
            const Spacer(flex: 4),
            Expanded(child: ServiceOl(current: tab, open: (t, page) => widget.opened.add((t, page?.call())))),
          ]),
        ),
      );
}

Future<List<(String, Widget?)>> _show(WidgetTester t) async {
  t.view.physicalSize = const Size(420, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final opened = <(String, Widget?)>[];
  await t.pumpWidget(MaterialApp(home: _Host(opened: opened)));
  await t.pumpAndSettle();
  return opened;
}

Future<void> _openOl(WidgetTester t) async {
  if (find.byKey(const ValueKey('ol-bubble-close')).evaluate().isNotEmpty) {
    await t.tap(find.byKey(const ValueKey('ol-bubble-close')));
    await t.pumpAndSettle();
  }
  await t.tap(find.byKey(const ValueKey('service-ol')));
  await t.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ServiceOl.reset();
  });
  tearDown(() => OlWalk.current?.stop());

  testWidgets('says hello the first time, then one tip the first time each tab opens, once', (t) async {
    await _show(t);
    expect(find.textContaining("Hi, I'm Ol!"), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('ol-bubble-close')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('go-Bill')));
    await t.pumpAndSettle();
    expect(find.textContaining('check people in here'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('ol-bubble-close')));
    await t.tap(find.byKey(const ValueKey('go-Home')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('go-Bill')));
    await t.pumpAndSettle();
    expect(find.textContaining('check people in here'), findsNothing, reason: 'a tip is said once');
  });

  testWidgets("no tip over a walkthrough; the tab's tip waits for the next time it opens", (t) async {
    await _show(t);
    await t.tap(find.byKey(const ValueKey('ol-bubble-close')));
    await t.pumpAndSettle();
    OlWalk.start(t.state<OverlayState>(find.byType(Overlay).first), const OlTour('Try', [
      OlStep('Tap to Bill.', target: OlTarget.key('go-Bill')),
      OlStep('Done.', next: true),
    ]));
    await t.pump(const Duration(milliseconds: 200));
    await t.tap(find.byKey(const ValueKey('go-Bill')));
    await t.pump(const Duration(milliseconds: 600));
    await t.pump();
    expect(find.text('Done.'), findsOneWidget, reason: 'the walkthrough moved on');
    expect(find.textContaining('check people in here'), findsNothing);
    OlWalk.current?.stop();
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('go-Home')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('go-Bill')));
    await t.pumpAndSettle();
    expect(find.textContaining('check people in here'), findsOneWidget);
  });

  testWidgets('tapped: "Where do you want to go?" with places, walkthroughs and this tab\'s questions; a place opens in its tab', (t) async {
    final opened = await _show(t);
    await _openOl(t);
    for (final s in ['Where do you want to go?', 'Take me to', 'Bookings', 'Bills', 'Services', 'Costing', 'Service management', 'Free slots', 'Money',
      'Show me how', 'Book a visit', 'Lend out a tool', 'Change opening hours', 'Ask me', 'Who is free now?']) {
      expect(find.text(s), findsWidgets, reason: s);
    }
    await t.tap(find.byKey(const ValueKey('service-ol-place-Money')));
    await t.pumpAndSettle();
    expect(opened.single.$1, 'Home');
    expect(opened.single.$2, isA<ServiceMoneyScreen>());
    await _openOl(t);
    await t.tap(find.byKey(const ValueKey('service-ol-place-Bookings')));
    await t.pumpAndSettle();
    expect(opened.last, ('Bookings', null), reason: 'a tab opens on its own');
  });

  testWidgets('typing narrows the places and walkthroughs; asking gives steps and Take me there', (t) async {
    final opened = await _show(t);
    await _openOl(t);
    await t.enterText(find.byKey(const ValueKey('service-ol-ask')), 'tool');
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('service-ol-place-Costing')), findsOneWidget);
    expect(find.byKey(const ValueKey('service-ol-place-Money')), findsNothing);
    expect(find.text('Lend out a tool'), findsOneWidget);
    expect(find.text('Book a visit'), findsNothing);

    await t.enterText(find.byKey(const ValueKey('service-ol-ask')), 'how do I change opening hours');
    await t.tap(find.byKey(const ValueKey('service-ol-send')));
    await t.pumpAndSettle();
    for (final s in ['Opening hours and slots are in Service management:', 'Tap Service management', 'Tap Edit hours', 'Take me there']) {
      expect(find.text(s), findsWidgets, reason: s);
    }
    await t.tap(find.byKey(const ValueKey('service-ol-take')));
    await t.pumpAndSettle();
    expect(opened.single.$1, 'Home');
    expect(opened.single.$2, isA<ManageScreen>());
  });

  testWidgets('Show me how starts the walkthrough on the real screens; Costing is a tab plus a walk to it', (t) async {
    final opened = await _show(t);
    await _openOl(t);
    await t.tap(find.byKey(const ValueKey('service-ol-tour-Book a visit')));
    await t.pumpAndSettle();
    expect(OlWalk.current?.tour.name, 'Book a visit');
    OlWalk.current?.stop();
    await t.pumpAndSettle();
    await _openOl(t);
    await t.tap(find.byKey(const ValueKey('service-ol-place-Costing')));
    await t.pumpAndSettle();
    expect(opened.single, ('Catalogue', null));
    expect(OlWalk.current?.tour.name, 'Open Costing');
    OlWalk.current?.stop();
    await t.pumpAndSettle();
  });

  test('answers: the topic with the most shared words; otherwise not sure', () {
    expect(serviceOlAnswer('book an appointment').place, 'Bookings');
    expect(serviceOlAnswer('lend the ladder tool').place, 'Costing');
    expect(serviceOlAnswer('send the bill on whatsapp').place, 'Bills');
    expect(serviceOlAnswer('who is free').place, 'Free slots');
    expect(serviceOlAnswer('xyz qwerty').text, serviceOlNotSure);
  });

  test('every place answers point to exists, and every place has a tab on the service bar', () {
    final titles = serviceOlPlaces.map((p) => p.title).toSet();
    for (final q in ['book', 'reschedule', 'job', 'pay', 'whatsapp', 'discount', 'add service', 'pause', 'tool', 'team', 'hours', 'free', 'money', 'photo', 'package',
      'membership', 'history', 'holiday']) {
      final a = serviceOlAnswer(q);
      expect(a.place == null || titles.contains(a.place), isTrue, reason: q);
    }
    for (final p in serviceOlPlaces) {
      expect(['Home', 'Catalogue', 'Bill', 'Bookings'], contains(p.tab), reason: p.title);
    }
  });
}
