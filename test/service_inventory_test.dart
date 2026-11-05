import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/service/catalogue_screen.dart';
import 'package:vinii_pos/service/service_widgets.dart' show SlideIn;

import 'service_screens_test.dart' show FakeRpc, refuse, serviceList, show, staff;

// The catalogue's Inventory tab (founder's design, 3 Nov 2026): Team, Places, Tools, Materials and In care, with what needs doing.

Map<String, dynamic> inventory({bool canEdit = true}) => {
      'can_edit': canEdit,
      'counts': {'places': 2, 'tools': 1, 'materials': 1, 'care': 1},
      'places': [
        {'id': 'p1', 'kind': 'place', 'name': 'Chair 1', 'qty': 1, 'state_label': 'Ready', 'tone': 'good', 'line': '', 'services': 'Haircut (men)', 'service_ids': ['s1'], 'blocked': false},
        {'id': 'p2', 'kind': 'place', 'name': 'Facial room', 'qty': 1, 'state_label': 'Blocked', 'tone': 'bad', 'line': 'Painting · till 8 Nov', 'services': '', 'service_ids': [], 'blocked': true},
      ],
      'tools': [
        {'id': 't1', 'kind': 'tool', 'name': 'Ladder', 'qty': 3, 'qty_out': 1, 'state_label': '1 out', 'tone': 'info', 'line': '2 of 3 available · With Arjun', 'bar': 67, 'services': 'AC service', 'service_ids': ['s2']},
      ],
      'materials': [
        {'id': 'm1', 'kind': 'material', 'name': 'Hair colour tubes', 'qty': 3, 'unit': 'tubes', 'reorder_at': 4, 'per_booking': 1, 'state_label': 'Low', 'tone': 'warn',
          'line': '3 tubes · reorder at 4 · 1 per booking', 'bar': 25, 'services': '', 'service_ids': []},
      ],
      'care': [
        {'id': 'c1', 'tag': 'C-1', 'item': 'Laptop', 'customer_name': 'Kiran Rao', 'customer_phone': '9876543210', 'note': 'Screen repair', 'promised_on': '2026-11-01',
          'status': 'with_you', 'state_label': 'Overdue', 'tone': 'bad', 'line': 'Tag C-1 · Screen repair · promised 1 Nov'},
      ],
      'alerts': [
        {'kind': 'material', 'id': 'm1', 'title': 'Hair colour tubes is running low', 'line': '3 tubes · reorder at 4 · 1 per booking'},
        {'kind': 'care', 'id': 'c1', 'title': 'Laptop · Kiran Rao is overdue', 'line': 'Tag C-1 · Screen repair · promised 1 Nov'},
      ],
      'services': [
        {'id': 's1', 'name': 'Haircut (men)'},
        {'id': 's2', 'name': 'AC service'},
      ],
    };

FakeRpc _fake({bool canEdit = true}) => FakeRpc({
      'svc_service_list': (_) => serviceList(),
      'svc_staff_list': (_) => staff(),
      'svc_inventory': (_) => inventory(canEdit: canEdit),
      'svc_inventory_save': (_) => inventory(),
      'svc_inventory_move': (b) => b['qty'] == 9 ? refuse(400, 'Only 3 left.', 'bad_request') : inventory(),
      'svc_care_save': (_) => inventory(),
    });

Future<void> _tap(WidgetTester t, Key key) async {
  await t.ensureVisible(find.byKey(key));
  await t.pumpAndSettle();
  await t.tap(find.byKey(key));
  await t.pumpAndSettle();
}

Future<void> _open(WidgetTester t, FakeRpc f, [String section = 'team']) async {
  await show(t, ServiceCatalogueScreen(api: f.api));
  await t.tap(find.byKey(const ValueKey('tab-inventory')));
  await t.pumpAndSettle();
  if (section != 'team') await _tap(t, ValueKey('inv-tile-$section'));
}

void main() {
  slidingTests();
  testWidgets('five tiles with counts; Team first; the tab says how many things need doing', (t) async {
    final f = _fake();
    await _open(t, f);
    for (final s in ['Team', 'Places', 'Tools', 'Materials', 'In care', '8', '2', 'Neha Rao', '5 free now · 2 on a job · 1 off']) {
      expect(find.text(s), findsWidgets, reason: s);
    }
    expect(find.descendant(of: find.byKey(const ValueKey('tab-count-inventory')), matching: find.text('2')), findsOneWidget,
        reason: 'the Inventory tab shows how many things need doing');
    expect(f.of('svc_inventory').length, 1);
    expect(f.of('svc_staff_list').length, 1);
  });

  testWidgets('on a phone the three tabs fit: no label spills over, even with things to do', (t) async {
    final f = _fake();
    t.view.physicalSize = const Size(375, 812);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(home: ServiceCatalogueScreen(api: f.api)));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('tab-inventory')));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull, reason: 'no overflow');
    expect(find.byKey(const ValueKey('tab-count-inventory')), findsOneWidget);
  });

  testWidgets('Places: ready and blocked with the reason; Block asks why and sends it; Take it back in use', (t) async {
    final f = _fake();
    await _open(t, f, 'places');
    for (final s in ['Rooms, chairs, courts, bays: anything a booking uses', 'Chair 1', 'Ready', 'Haircut (men)', 'Facial room', 'Blocked', 'Painting · till 8 Nov']) {
      expect(find.text(s), findsWidgets, reason: s);
    }
    await _tap(t, const ValueKey('inv-p1'));
    await _tap(t, const ValueKey('inv-act-block'));
    await t.enterText(find.byKey(const ValueKey('ask-text')), 'Under repair');
    await t.tap(find.text('Block').last);
    await t.pumpAndSettle();
    final b = f.of('svc_inventory_save').single;
    expect(b.$2, {'id': 'p1', 'name': 'Chair 1', 'blocked': true, 'blocked_note': 'Under repair', 'blocked_until': ''});
    expect(b.$3, startsWith('svc-'));
    await _tap(t, const ValueKey('inv-p2'));
    await _tap(t, const ValueKey('inv-act-unblock'));
    expect(f.of('svc_inventory_save').last.$2['blocked'], false);
  });

  testWidgets('a row menu is a small box over the card tapped, not a sheet from the bottom, and stays on a phone screen', (t) async {
    final f = _fake();
    t.view.physicalSize = const Size(375, 812);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(home: ServiceCatalogueScreen(api: f.api)));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('tab-inventory')));
    await t.pumpAndSettle();
    await _tap(t, const ValueKey('inv-tile-places'));
    await _tap(t, const ValueKey('inv-p1'));
    final card = t.getRect(find.byKey(const ValueKey('inv-p1'))), box = t.getRect(find.byKey(const ValueKey('action-box')));
    expect(box.overlaps(card), isTrue, reason: 'over the card');
    expect(box.top, greaterThanOrEqualTo(0));
    expect(box.bottom, lessThanOrEqualTo(812));
    expect(box.width, lessThan(300), reason: 'a small box, not a full-width sheet');
    expect(find.byKey(const ValueKey('inv-act-block')), findsOneWidget);
  });

  testWidgets('adding a place: name, how many, note, the services it is for', (t) async {
    final f = _fake();
    await _open(t, f, 'places');
    await _tap(t, const ValueKey('inv-add-places'));
    expect(find.text('Add a place'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('inv-name')), 'Court 2');
    await t.enterText(find.byKey(const ValueKey('inv-qty')), '2');
    await t.tap(find.text('AC service').last);
    await t.pumpAndSettle();
    await _tap(t, const ValueKey('inv-save'));
    expect(f.of('svc_inventory_save').single.$2, {'kind': 'place', 'name': 'Court 2', 'qty': 2, 'note': '', 'service_ids': ['s2']});
  });

  testWidgets('Tools: availability and the bar; Lend out sends how many and who has them; Got back', (t) async {
    final f = _fake();
    await _open(t, f, 'tools');
    for (final s in ['Tools and gear', 'Ladder', '1 out', '2 of 3 available · With Arjun', 'AC service']) {
      expect(find.text(s), findsWidgets, reason: s);
    }
    await _tap(t, const ValueKey('inv-t1'));
    await _tap(t, const ValueKey('inv-act-out'));
    await t.enterText(find.byKey(const ValueKey('ask-text')), '2');
    await t.tap(find.text('Save').last);
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('ask-text')), 'With Ravi');
    await t.tap(find.text('Lend out').last);
    await t.pumpAndSettle();
    expect(f.of('svc_inventory_move').single.$2, {'id': 't1', 'action': 'out', 'qty': 2, 'note': 'With Ravi'});
    await _tap(t, const ValueKey('inv-t1'));
    await _tap(t, const ValueKey('inv-act-back'));
    await t.enterText(find.byKey(const ValueKey('ask-text')), '1');
    await t.tap(find.text('Save').last);
    await t.pumpAndSettle();
    expect(f.of('svc_inventory_move').last.$2, {'id': 't1', 'action': 'back', 'qty': 1});
  });

  testWidgets('Materials: the low-stock warning on top; Use some; a refusal is shown as the server says it', (t) async {
    final f = _fake();
    await _open(t, f, 'materials');
    for (final s in ['Hair colour tubes is running low', 'Hair colour tubes', 'Low', '3 tubes · reorder at 4 · 1 per booking']) {
      expect(find.text(s), findsWidgets, reason: s);
    }
    expect(find.text('Laptop · Kiran Rao is overdue'), findsNothing, reason: 'each section shows its own warnings');
    await _tap(t, const ValueKey('inv-m1'));
    await _tap(t, const ValueKey('inv-act-use'));
    await t.enterText(find.byKey(const ValueKey('ask-text')), '9');
    await t.tap(find.text('Save').last);
    await t.pumpAndSettle();
    expect(f.of('svc_inventory_move').single.$2, {'id': 'm1', 'action': 'use', 'qty': 9});
    expect(find.text('Only 3 left.'), findsOneWidget);
  });

  testWidgets('In care: the tag, overdue, and moving it on; taking in a new item', (t) async {
    final f = _fake();
    await _open(t, f, 'care');
    for (final s in ['Items in care', 'C-1', 'Laptop · Kiran Rao', 'Overdue', 'Tag C-1 · Screen repair · promised 1 Nov', 'Laptop · Kiran Rao is overdue']) {
      expect(find.text(s), findsWidgets, reason: s);
    }
    await _tap(t, const ValueKey('inv-c1'));
    await _tap(t, const ValueKey('inv-act-ready'));
    expect(f.of('svc_care_save').single.$2, {'id': 'c1', 'status': 'ready'});

    await _tap(t, const ValueKey('inv-add-care'));
    await t.enterText(find.byKey(const ValueKey('inv-item')), 'Kit bag');
    await t.enterText(find.byKey(const ValueKey('inv-customer')), 'Rohit S.');
    await _tap(t, const ValueKey('inv-save'));
    expect(f.of('svc_care_save').last.$2, {'item': 'Kit bag', 'customer_name': 'Rohit S.', 'note': ''});
  });

  testWidgets('a role that cannot edit sees no Add, Edit or Block on places, but can still lend tools and take in items', (t) async {
    final f = _fake(canEdit: false);
    await _open(t, f, 'places');
    expect(find.byKey(const ValueKey('inv-add-places')), findsNothing);
    await _tap(t, const ValueKey('inv-tile-tools'));
    await _tap(t, const ValueKey('inv-t1'));
    expect(find.byKey(const ValueKey('inv-act-out')), findsOneWidget);
    expect(find.byKey(const ValueKey('inv-act-edit')), findsNothing);
    await t.tapAt(const Offset(5, 5));
    await t.pumpAndSettle();
    await _tap(t, const ValueKey('inv-tile-care'));
    expect(find.byKey(const ValueKey('inv-add-care')), findsOneWidget);
  });
}

// Sliding after a tap (founder, 4 Nov 2026): a chip shows a tick when picked and the list slides in from the side of the chip.
void slidingTests() {
  testWidgets('catalogue chips: the picked chip gets a tick; the list slides in from the right, then from the left going back', (t) async {
    final f = _fake();
    await show(t, ServiceCatalogueScreen(api: f.api));
    await t.ensureVisible(find.byKey(const ValueKey('chip-cat-Grooming')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('chip-cat-Grooming')));
    await t.pumpAndSettle();
    final slides = t.widgetList<SlideIn>(find.byType(SlideIn));
    expect(slides, isNotEmpty);
    expect(slides.first.dir, 1);
    expect(find.descendant(of: find.byKey(const ValueKey('chip-cat-Grooming')), matching: find.byType(Icon)), findsOneWidget, reason: 'the tick');
    await t.ensureVisible(find.byKey(const ValueKey('chip-all')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('chip-all')));
    await t.pumpAndSettle();
    expect(t.widgetList<SlideIn>(find.byType(SlideIn)).first.dir, -1);
  });
}
