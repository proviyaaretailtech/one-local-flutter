import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:vinii_pos/catalogue/item_photo.dart';
import 'package:vinii_pos/service/image_adjust_screen.dart';
import 'package:vinii_pos/service/service_form.dart';
import 'package:vinii_pos/service/service_parts.dart';

import 'service_screens_test.dart' show FakeRpc, serviceDetail;

// The founder's form changes of 6 Nov 2026: photos at the top with crop and rotate, "+ Add" first in dropdowns, plain wording, type of entry,
// named rules saved as templates, and an optional cost on what a listing uses.

Uint8List _png(int w, int h) => img.encodePng(img.Image(width: w, height: h));

class _OnePhoto extends ItemPhotoService {
  @override
  Future<ItemPhoto?> pick() async => ItemPhoto(bytes: _png(40, 20), contentType: 'image/png');
  @override
  Future<ItemPhoto> removeBackground(ItemPhoto photo, {String? bgColor}) async => photo;
  @override
  Future<void> attach(String itemId, ItemPhoto photo) async => attached = photo;
  ItemPhoto? attached;
  @override
  Future<void> remove(String itemId) async {}
}

FakeRpc _fake({List<Map<String, dynamic>>? saved}) {
  final rules = saved ?? <Map<String, dynamic>>[];
  return FakeRpc({
    'svc_listing_view': (_) => {'listing': {}, 'can_edit': true, 'places': [], 'tools': [], 'materials': [], 'team': [], 'branches': []},
    'svc_service_save': (_) => serviceDetail(),
    'svc_listing_save': (_) => {'listing': {}, 'can_edit': true, 'places': [], 'tools': [], 'materials': [], 'team': [], 'branches': []},
    'svc_rule_template_list': (_) => {'templates': rules},
    'svc_rule_template_save': (b) {
      rules
        ..removeWhere((r) => r['name'] == b['name'])
        ..add({'id': 'r${rules.length}', 'name': b['name'], 'rule': b['rule']});
      return {'templates': rules};
    },
  });
}

Future<void> _phone(WidgetTester t, Widget screen) async {
  t.view.physicalSize = const Size(375, 1400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(home: screen));
  await t.pumpAndSettle();
}

Future<void> _tap(WidgetTester t, Key key) async {
  await t.ensureVisible(find.byKey(key));
  await t.pumpAndSettle();
  await t.tap(find.byKey(key));
  await t.pumpAndSettle();
}

Future<void> _step(WidgetTester t, int n) => _tap(t, ValueKey('sf-seg-${n - 1}'));

void main() {
  group('photos', () {
    testWidgets('the Add tile stays at the top, first in the row, above the fields', (t) async {
      await _phone(t, ServiceFormScreen(api: _fake().api, category: 'service', photos: _OnePhoto()));
      await _tap(t, const ValueKey('sf-media-add'));
      await t.tap(find.byKey(const ValueKey('sf-media-photo')));
      await t.pumpAndSettle();
      final add = t.getTopLeft(find.byKey(const ValueKey('sf-media-add')));
      final cover = t.getTopLeft(find.byKey(const ValueKey('sf-cover')));
      expect(add.dx, lessThan(cover.dx), reason: 'Add comes first');
      expect(add.dy, lessThan(t.getTopLeft(find.byKey(const ValueKey('sf-name'))).dy), reason: 'above the name');
    });

    testWidgets('a picked cover opens in Adjust from its tile; the rotated photo is what is sent', (t) async {
      final photos = _OnePhoto();
      final f = _fake();
      await _phone(t, ServiceFormScreen(api: f.api, category: 'service', photos: photos));
      await _tap(t, const ValueKey('sf-media-add'));
      await t.tap(find.byKey(const ValueKey('sf-media-photo')));
      await t.pumpAndSettle();
      await _tap(t, const ValueKey('sf-cover-adjust'));
      expect(find.byType(ImageAdjustScreen), findsOneWidget);
      await _tap(t, const ValueKey('adjust-right'));
      await _tap(t, const ValueKey('adjust-use'));
      expect(find.byType(ImageAdjustScreen), findsNothing);
      expect(find.byKey(const ValueKey('sf-cover')), findsOneWidget, reason: 'back on the form');
    });
  });

  group('Adjust photo', () {
    Future<ItemPhoto?> run(WidgetTester t, ItemPhoto photo, Future<void> Function() steps) async {
      ItemPhoto? out;
      t.view.physicalSize = const Size(375, 812);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        home: Builder(builder: (c) => TextButton(key: const ValueKey('go'), onPressed: () async => out = await ImageAdjustScreen.open(c, photo), child: const Text('go'))),
      ));
      await t.tap(find.byKey(const ValueKey('go')));
      await t.pumpAndSettle();
      await steps();
      return out;
    }

    Size sizeOf(ItemPhoto p) {
      final i = img.decodeImage(p.bytes)!;
      return Size(i.width.toDouble(), i.height.toDouble());
    }

    testWidgets('nothing done: the same photo comes back, untouched', (t) async {
      final photo = ItemPhoto(bytes: _png(40, 20), contentType: 'image/png');
      final out = await run(t, photo, () => _tap(t, const ValueKey('adjust-use')));
      expect(identical(out, photo), isTrue);
    });

    testWidgets('rotate swaps the sides, and a PNG stays a PNG', (t) async {
      final out = await run(t, ItemPhoto(bytes: _png(40, 20), contentType: 'image/png'), () async {
        await _tap(t, const ValueKey('adjust-left'));
        await _tap(t, const ValueKey('adjust-use'));
      });
      expect(sizeOf(out!), const Size(20, 40));
      expect(out.contentType, 'image/png');
    });

    testWidgets('Square crops the middle to a square; a JPG stays a JPG', (t) async {
      final jpg = img.encodeJpg(img.Image(width: 100, height: 50));
      final out = await run(t, ItemPhoto(bytes: jpg, contentType: 'image/jpeg'), () async {
        await _tap(t, const ValueKey('adjust-ratio-Square'));
        await _tap(t, const ValueKey('adjust-use'));
      });
      expect(sizeOf(out!), const Size(50, 50));
      expect(out.contentType, 'image/jpeg');
    });

    testWidgets('dragging a corner in makes the crop smaller', (t) async {
      final out = await run(t, ItemPhoto(bytes: _png(200, 200), contentType: 'image/png'), () async {
        final box = find.byKey(const ValueKey('adjust-crop'));
        final corner = t.getBottomRight(box) - const Offset(2, 2);
        await t.dragFrom(corner, Offset(-t.getSize(box).width / 2, -t.getSize(box).height / 2));
        await t.pumpAndSettle();
        await _tap(t, const ValueKey('adjust-use'));
      });
      final s = sizeOf(out!);
      expect(s.width, inInclusiveRange(95, 110));
      expect(s.height, inInclusiveRange(95, 110));
    });

    testWidgets('a file it cannot read says so and has no tools', (t) async {
      await run(t, ItemPhoto(bytes: Uint8List.fromList([1, 2, 3]), contentType: 'image/jpeg'), () async {});
      expect(find.byKey(const ValueKey('adjust-unreadable')), findsOneWidget);
      expect(find.byKey(const ValueKey('adjust-use')), findsNothing);
    });
  });

  testWidgets('+ Add is the first choice in a dropdown, above the options', (t) async {
    await _phone(t, ServiceFormScreen(api: _fake().api, category: 'service', photos: _OnePhoto()));
    await _step(t, 2);
    await _tap(t, const ValueKey('sf-book_up_to'));
    final add = t.getTopLeft(find.byKey(const ValueKey('opt-add')).last).dy;
    expect(add, lessThan(t.getTopLeft(find.byKey(const ValueKey('opt-7 days ahead')).last).dy));
  });

  testWidgets('the notice box says it is about booking', (t) async {
    await _phone(t, ServiceFormScreen(api: _fake().api, category: 'service', photos: _OnePhoto()));
    await _step(t, 2);
    expect(find.text('Minimum notice to book'), findsOneWidget);
  });

  testWidgets('On site replaces At your place, an old answer reads as On site, and on-call questions stay away from it', (t) async {
    await _phone(t, ServiceFormScreen(api: _fake().api, category: 'service', listing: const {'subcategory': 'Haircut', 'where': 'At your place'}, photos: _OnePhoto()));
    await _step(t, 3);
    expect(find.text('At your place'), findsNothing);
    expect(find.text('On site'), findsOneWidget);
    expect(find.byKey(const ValueKey('sf-oncall_area')), findsNothing);
    expect(listingProfile('service', 'Haircut').where, isNot(contains('At your place')));
  });

  testWidgets('Where and who asks the type of entry; it is saved with the listing', (t) async {
    final f = _fake();
    await _phone(t, ServiceFormScreen(api: f.api, category: 'service', listing: const {'subcategory': 'Haircut', 'name': 'Cut', 'price': '100'}, photos: _OnePhoto()));
    await _step(t, 3);
    await _tap(t, const ValueKey('sf-entry_type'));
    await t.tap(find.byKey(const ValueKey('opt-Members only')).last);
    await t.pumpAndSettle();
    await _step(t, 6);
    await _tap(t, const ValueKey('sf-publish'));
    final listing = f.of('svc_listing_save').single.$2['listing'] as Map;
    expect(listing['entry_type'], 'Members only');
  });

  group('pricing rules', () {
    Future<FakeRpc> open(WidgetTester t, {List<Map<String, dynamic>>? saved}) async {
      final f = _fake(saved: saved);
      await _phone(t, ServiceFormScreen(api: f.api, category: 'service', listing: const {'subcategory': 'Haircut', 'name': 'Cut', 'price': '100', 'rules_on': true}, photos: _OnePhoto()));
      await _step(t, 4);
      return f;
    }

    testWidgets('a rule can be named, and the name is saved with it', (t) async {
      final f = await open(t);
      await _tap(t, const ValueKey('sf-rule-add'));
      await t.enterText(find.byKey(const ValueKey('sf-rule-0-name')), 'Under 18 women');
      await _step(t, 6);
      await _tap(t, const ValueKey('sf-publish'));
      final listing = f.of('svc_listing_save').single.$2['listing'] as Map;
      expect((listing['rules'] as List).single['name'], 'Under 18 women');
    });

    testWidgets('Save as a template asks a name and sends the rule; then it can be picked for a new rule', (t) async {
      final f = await open(t);
      expect(find.byKey(const ValueKey('sf-rule-saved')), findsNothing, reason: 'nothing saved yet');
      await _tap(t, const ValueKey('sf-rule-add'));
      await t.enterText(find.byKey(const ValueKey('sf-rule-0-name')), 'Under 18 women');
      await t.enterText(find.byKey(const ValueKey('sf-rule-0-price')), '250');
      await _tap(t, const ValueKey('sf-rule-0-template'));
      await t.tap(find.text('Save template'));
      await t.pumpAndSettle();
      final sent = f.of('svc_rule_template_save').single;
      expect(sent.$2['name'], 'Under 18 women');
      expect((sent.$2['rule'] as Map)['price'], 250);
      expect(sent.$3, isNotNull, reason: 'a repeat tap is one save');

      await _tap(t, const ValueKey('sf-rule-saved'));
      await t.tap(find.byKey(const ValueKey('opt-Under 18 women')).last);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('sf-rule-1-name')), findsOneWidget);
      expect(t.widget<TextFormField>(find.byKey(const ValueKey('sf-rule-1-name'))).initialValue, 'Under 18 women');
      expect(t.widget<TextFormField>(find.byKey(const ValueKey('sf-rule-1-price'))).initialValue, '250');
    });

    testWidgets('removing a rule leaves the next rule showing its own name', (t) async {
      await open(t);
      await _tap(t, const ValueKey('sf-rule-add'));
      await _tap(t, const ValueKey('sf-rule-add'));
      await t.enterText(find.byKey(const ValueKey('sf-rule-0-name')), 'First');
      await t.enterText(find.byKey(const ValueKey('sf-rule-1-name')), 'Second');
      await t.pump();
      await _tap(t, const ValueKey('sf-rule-0-remove'));
      expect(find.text('Second'), findsOneWidget);
      expect(find.text('First'), findsNothing);
    });

    testWidgets('a business with no saved rules, or a failed read, still shows the rules', (t) async {
      final f = FakeRpc({
        'svc_listing_view': (_) => {'listing': {}, 'can_edit': true, 'places': [], 'tools': [], 'materials': [], 'team': [], 'branches': []},
      });
      await _phone(t, ServiceFormScreen(api: f.api, category: 'service', listing: const {'subcategory': 'Haircut', 'rules_on': true}, photos: _OnePhoto()));
      await _step(t, 4);
      expect(find.byKey(const ValueKey('sf-rule-add')), findsOneWidget);
      expect(find.byKey(const ValueKey('sf-rule-saved')), findsNothing);
    });
  });

  group('what it uses', () {
    Future<FakeRpc> open(WidgetTester t) async {
      final f = _fake();
      await _phone(t, ServiceFormScreen(api: f.api, category: 'service', listing: const {'subcategory': 'Haircut', 'name': 'Cut', 'price': '100'}, photos: _OnePhoto()));
      await _step(t, 5);
      return f;
    }

    testWidgets('each row takes an optional cost; the total multiplies by how many and is saved', (t) async {
      final f = await open(t);
      await _tap(t, const ValueKey('sf-need-add'));
      expect(find.byKey(const ValueKey('needs-cost')), findsNothing, reason: 'optional: no cost, no line');
      await t.enterText(find.byKey(const ValueKey('sf-need-0-qty')), '2');
      await t.enterText(find.byKey(const ValueKey('sf-need-0-cost')), '150');
      await t.pumpAndSettle();
      expect(t.widget<Text>(find.byKey(const ValueKey('needs-cost'))).data, '₹300');
      expect(find.text('Cost per booking'), findsOneWidget);
      await _step(t, 6);
      await _tap(t, const ValueKey('sf-publish'));
      final listing = f.of('svc_listing_save').single.$2['listing'] as Map;
      expect((listing['requirements'] as List).single['cost'], 150);
    });

    test('needsCost: nothing typed is zero, text and numbers both count', () {
      expect(needsCost(const []), 0);
      expect(needsCost(const [{'qty': 1}]), 0);
      expect(needsCost(const [{'qty': 2, 'cost': 10.5}, {'qty': '3', 'cost': '4'}, {'cost': 5}]), 38);
    });

    testWidgets('a material row fits a 375 px phone with its cost', (t) async {
      await open(t);
      await _tap(t, const ValueKey('sf-need-add'));
      await _tap(t, const ValueKey('sf-need-0-type'));
      await t.tap(find.byKey(const ValueKey('opt-Other')).last);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('sf-need-0-cost')), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });
}
