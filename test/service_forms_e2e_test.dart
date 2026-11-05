import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/catalogue/item_photo.dart';
import 'package:vinii_pos/service/service_api.dart' show ServiceDetail;
import 'package:vinii_pos/service/service_form.dart';
import 'package:vinii_pos/service/service_parts.dart';

import 'service_screens_test.dart' show FakeRpc, serviceDetail;

// End to end, every listing form (founder, 4 Nov 2026: "do end to end testing of the service pos ... content inside the forms and if they're
// relevant to the subcategories"): each category × each subcategory, on a 375 px phone, opened as that category (never changeable inside),
// walked through every step, filled, published; what reaches the server is checked, and one line per form is printed for the report.

class _NoPhotos extends ItemPhotoService {
  @override
  Future<ItemPhoto?> pick() async => null;
  @override
  Future<ItemPhoto> removeBackground(ItemPhoto photo, {String? bgColor}) async => photo;
  @override
  Future<void> attach(String itemId, ItemPhoto photo) async {}
  @override
  Future<void> remove(String itemId) async {}
}

FakeRpc _fake() => FakeRpc({
      'svc_listing_view': (_) => {
            'listing': {},
            'can_edit': true,
            'places': [],
            'tools': [],
            'materials': [],
            'team': [
              {'staff_id': 'st1', 'name': 'Neha Rao', 'title': 'Senior stylist'},
            ],
            'branches': [],
          },
      'svc_template_list': (_) => {'templates': [], 'total': 0, 'can_edit': true},
      'svc_service_save': (_) => serviceDetail(),
      'svc_listing_save': (_) => {'listing': {}, 'can_edit': true, 'places': [], 'tools': [], 'materials': [], 'team': [], 'branches': []},
    });

Future<void> _tap(WidgetTester t, Key key) async {
  await t.ensureVisible(find.byKey(key));
  await t.pumpAndSettle();
  await t.tap(find.byKey(key));
  await t.pumpAndSettle();
}

Future<void> _choose(WidgetTester t, Key box, String option) async {
  await _tap(t, box);
  await t.ensureVisible(find.byKey(ValueKey('opt-$option')).last);
  await t.pumpAndSettle();
  await t.tap(find.byKey(ValueKey('opt-$option')).last);
  await t.pumpAndSettle();
}

Future<void> _step(WidgetTester t, int n) => _tap(t, ValueKey('sf-seg-${n - 1}'));

bool _has(String k) => find.byKey(ValueKey('sf-$k')).evaluate().isNotEmpty;

/// The options a dropdown offers, read from its open menu, then closed.
Future<List<String>> _options(WidgetTester t, String key) async {
  await _tap(t, ValueKey('sf-$key'));
  final opts = [
    for (final e in find.byWidgetPredicate((w) => w.key is ValueKey<String> && '${(w.key as ValueKey<String>).value}'.startsWith('opt-')).evaluate())
      '${(e.widget.key as ValueKey<String>).value}'.substring(4),
  ].where((o) => o != 'add').toSet().toList();
  await t.tapAt(const Offset(2, 2));
  await t.pumpAndSettle();
  return opts;
}

void main() {
  for (final c in listingCategories) {
    for (final sub in c.allSubcategories) {
      testWidgets('${c.name} · $sub: its own form, every step fits a phone, the right fields, saved as it should', (t) async {
        t.view.physicalSize = const Size(375, 812);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        final f = _fake();
        final p = listingProfile(c.key, sub);
        await t.pumpWidget(MaterialApp(home: ServiceFormScreen(api: f.api, category: c.key, photos: _NoPhotos())));
        await t.pumpAndSettle();

        // 1 Basics: the category is fixed (no dropdown, no tiles); the subcategory picks the rest
        expect(find.text('New listing · ${c.name}'), findsOneWidget);
        expect(_has('category'), isFalse, reason: 'no category dropdown inside the form');
        expect(_has('category-first'), isFalse);
        await t.enterText(find.byKey(const ValueKey('sf-name')), 'Test $sub');
        final group = groupOfSubcategory(c.key, sub);
        if (group != null) {
          await _choose(t, const ValueKey('sf-sub_group'), group);
          final others = [for (final (g, n) in c.subcategories) if (g != group) ...n];
          await _tap(t, const ValueKey('sf-subcategory'));
          for (final o in others) {
            expect(find.byKey(ValueKey('opt-$o')), findsNothing, reason: 'only $group subcategories, not $o');
          }
          await t.tapAt(const Offset(2, 2));
          await t.pumpAndSettle();
        }
        await _choose(t, const ValueKey('sf-subcategory'), sub);
        expect(_has('amenity-${p.amenities.first}'), isTrue, reason: 'its own amenities');
        expect(t.takeException(), isNull, reason: 'step 1 fits');

        // 2 How it is booked
        await _step(t, 2);
        expect(await _options(t, 'booking_type'), p.bookingTypes);
        final type = p.bookingType;
        expect(_has('unit_kind'), p.unitKinds.isNotEmpty, reason: 'units only where customers book one');
        if (p.unitKinds.isNotEmpty) {
          await _tap(t, const ValueKey('sf-unit-add'));
          expect(_has('unit-0-surface'), p.surfaces.isNotEmpty, reason: 'a surface only where it means something');
        }
        expect(_has('part-bookings'), p.parts);
        expect(_has('check_in'), type == 'Nights');
        expect(_has('event_date'), type == 'Entry');
        expect(_has('duration'), type == 'Slot');
        expect(t.takeException(), isNull, reason: 'step 2 fits');

        // 3 Where and who
        await _step(t, 3);
        expect(_has('where'), p.where.isNotEmpty);
        if (p.where.isNotEmpty) expect(await _options(t, 'where'), p.where);
        expect(_has('age_rule'), p.age);
        expect(_has('gender_rule'), p.gender);
        expect(_has('safety_rule'), p.safety);
        expect(_has('adults'), type == 'Nights');
        expect(_has('capacity'), type == 'Entry');
        expect(t.takeException(), isNull, reason: 'step 3 fits');

        // 4 Price (with the rules)
        await _step(t, 4);
        expect(await _options(t, 'pricing'), p.pricing);
        if (_has('price')) await t.enterText(find.byKey(const ValueKey('sf-price')), '500');
        if (p.pricingDefault == 'By type') {
          await _tap(t, const ValueKey('sf-type-add'));
          await t.enterText(find.byKey(const ValueKey('sf-type-0-name')), 'Standard');
          await t.enterText(find.byKey(const ValueKey('sf-type-0-price')), '500');
        }
        expect(_has('rules-on'), isTrue);
        expect(t.takeException(), isNull, reason: 'step 4 fits');

        // 5 What it uses, 6 Notes and confirm
        await _step(t, 5);
        expect(_has('need-add'), isTrue);
        expect(_has('after_checkout'), c.key == 'stay');
        expect(t.takeException(), isNull, reason: 'step 5 fits');
        await _step(t, 6);
        expect(_has('publish'), isTrue);
        expect(t.takeException(), isNull, reason: 'step 6 fits');
        await _tap(t, const ValueKey('sf-publish'));

        // what reaches the server
        final core = f.of('svc_service_save').single.$2;
        final listing = (f.of('svc_listing_save').single.$2['listing'] as Map);
        expect(f.of('svc_listing_save').single.$2['category'], c.key);
        expect(core['category'], sub);
        expect(core['price'], 500);
        expect(listing['booking_type'], type);
        expect(listing['unit_kind'], p.unitKind);
        final fulfilment = c.key == 'events' || type == 'Entry' ? 'event' : p.whereDefault == 'On call' ? 'on_location' : 'appointment';
        expect(core['fulfilment'], fulfilment);
        // one line per form for the report
        // ignore: avoid_print
        print('E2E|${c.name}|$sub|${p.bookingTypes.join('/')}|${p.unitKinds.isEmpty ? '-' : p.unitKinds.join('/')}|'
            '${p.surfaces.isEmpty ? '-' : p.surfaces.join('/')}|${p.parts ? 'yes' : '-'}|${p.where.isEmpty ? 'at the venue' : p.where.join('/')}|'
            '${p.pricing.join('/')}|${[if (p.age) 'age', if (p.gender) 'gender', if (p.safety) 'safety'].join('+')}|${p.amenities.take(4).join(', ')}…|$fulfilment|PASS');
      });
    }
  }

  testWidgets('a subcategory change resets to its own defaults: Cricket nets to Swimming lane drops the surface, Lane is booked', (t) async {
    final f = _fake();
    await t.pumpWidget(MaterialApp(home: ServiceFormScreen(api: f.api, category: 'play', photos: _NoPhotos())));
    await t.pumpAndSettle();
    await _choose(t, const ValueKey('sf-subcategory'), 'Cricket nets');
    await _step(t, 2);
    expect(find.text('Net'), findsWidgets);
    await _step(t, 1);
    await _choose(t, const ValueKey('sf-subcategory'), 'Swimming lane');
    await _step(t, 2);
    expect(find.text('Lane'), findsWidgets);
    await _tap(t, const ValueKey('sf-unit-add'));
    expect(_has('unit-0-surface'), isFalse);
  });

  testWidgets('an older service asks its category once; then it is fixed like any other', (t) async {
    final f = _fake();
    await t.pumpWidget(MaterialApp(home: ServiceFormScreen(api: f.api, detail: ServiceDetail(serviceDetail()), photos: _NoPhotos())));
    await t.pumpAndSettle();
    expect(_has('category-first'), isTrue);
    await _tap(t, const ValueKey('sf-cat-play'));
    expect(_has('category-first'), isFalse);
    expect(find.text('Edit listing · Play'), findsOneWidget);
  });

  testWidgets('the examples in the empty boxes follow the category and the subcategory, never a manicure on an event', (t) async {
    final f = _fake();
    String hintOf(String key) => (t.widget<TextField>(find.byKey(ValueKey('sf-$key'))).decoration?.hintText) ?? '';
    await t.pumpWidget(MaterialApp(home: ServiceFormScreen(api: f.api, category: 'events', photos: _NoPhotos())));
    await t.pumpAndSettle();
    expect(hintOf('name'), isNot(contains('Manicure')));
    await _choose(t, const ValueKey('sf-subcategory'), 'Stand-up comedy');
    expect(hintOf('name'), 'e.g. Saturday stand-up night');
    expect(hintOf('description'), 'e.g. Four comics, 90 minutes');
    await _choose(t, const ValueKey('sf-subcategory'), 'Party hall and banquet');
    expect(hintOf('name'), contains('Banquet hall'));
    await t.pumpWidget(MaterialApp(home: ServiceFormScreen(key: UniqueKey(), api: f.api, category: 'service', photos: _NoPhotos())));
    await t.pumpAndSettle();
    await _choose(t, const ValueKey('sf-sub_group'), 'Home and repairs');
    await _choose(t, const ValueKey('sf-subcategory'), 'Plumbing');
    expect(hintOf('name'), 'e.g. Tap and leak repair');
    await t.pumpWidget(MaterialApp(home: ServiceFormScreen(key: UniqueKey(), api: f.api, category: 'play', photos: _NoPhotos())));
    await t.pumpAndSettle();
    await _choose(t, const ValueKey('sf-subcategory'), 'Football turf');
    expect(hintOf('name'), 'e.g. 5-a-side turf · 1 hour');
    // every subcategory has an example of its own words, not the salon's
    for (final c in listingCategories) {
      for (final sub in c.allSubcategories) {
        final eg = listingExamples(c.key, sub);
        if (c.key != 'service' || !(sub.contains('salon') || sub == 'Beauty parlour')) expect(eg.name, isNot('Manicure'), reason: '${c.name} · $sub');
      }
    }
  });

  testWidgets('amenities can be picked and unpicked with a tap, and are saved with the listing', (t) async {
    t.view.physicalSize = const Size(375, 812);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final f = _fake();
    await t.pumpWidget(MaterialApp(home: ServiceFormScreen(api: f.api, category: 'play', photos: _NoPhotos())));
    await t.pumpAndSettle();
    bool on(String a) => t.widget<FilterChip>(find.byKey(ValueKey('sf-amenity-$a'))).selected;
    await _tap(t, const ValueKey('sf-amenity-WiFi'));
    await _tap(t, const ValueKey('sf-amenity-Parking'));
    expect(on('WiFi'), isTrue);
    expect(on('Parking'), isTrue);
    await _tap(t, const ValueKey('sf-amenity-WiFi'));
    expect(on('WiFi'), isFalse, reason: 'a second tap takes it off');
    expect(on('Parking'), isTrue);
    await t.enterText(find.byKey(const ValueKey('sf-name')), 'Court');
    await _choose(t, const ValueKey('sf-subcategory'), 'Football turf');
    await _step(t, 4);
    await t.enterText(find.byKey(const ValueKey('sf-price')), '900');
    await _step(t, 6);
    await _tap(t, const ValueKey('sf-draft'));
    expect((f.of('svc_listing_save').single.$2['listing'] as Map)['amenities'], ['Parking']);
  });

  testWidgets('number fields take no letters: + Add on Book up to, GST and the others takes digits and adds the unit; prices and quantities are digits only', (t) async {
    final f = _fake();
    await t.pumpWidget(MaterialApp(home: ServiceFormScreen(api: f.api, category: 'stay', photos: _NoPhotos())));
    await t.pumpAndSettle();
    await _step(t, 2);
    // + Add on Book up to
    await _tap(t, const ValueKey('sf-book_up_to'));
    await t.ensureVisible(find.byKey(const ValueKey('opt-add')).last);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('opt-add')).last);
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('ask-text')), 'kjhvgjbhukybjik');
    await t.pump();
    expect(t.widget<TextField>(find.byKey(const ValueKey('ask-text'))).controller!.text, '', reason: 'letters are refused');
    await t.enterText(find.byKey(const ValueKey('ask-text')), '45');
    await t.pump();
    await t.tap(find.byKey(const ValueKey('own-add')));
    await t.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const ValueKey('sf-book_up_to')), matching: find.text('45 days ahead')), findsOneWidget);
    // times are a complete list: no typing a time
    await _tap(t, const ValueKey('sf-check_in'));
    expect(find.byKey(const ValueKey('opt-add')), findsNothing);
    await t.tapAt(const Offset(2, 2));
    await t.pumpAndSettle();
    // prices: digits and a decimal point only
    await _step(t, 4);
    await t.enterText(find.byKey(const ValueKey('sf-price')), '12ab3.456');
    await t.pump();
    expect(t.widget<TextField>(find.byKey(const ValueKey('sf-price'))).controller!.text, isNot(contains('a')));
    await t.enterText(find.byKey(const ValueKey('sf-price')), 'abc');
    await t.pump();
    expect(t.widget<TextField>(find.byKey(const ValueKey('sf-price'))).controller!.text, '');
    // GST + Add takes a percent
    await _tap(t, const ValueKey('sf-gst'));
    await t.ensureVisible(find.byKey(const ValueKey('opt-add')).last);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('opt-add')).last);
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('ask-text')), '3');
    await t.pump();
    await t.tap(find.byKey(const ValueKey('own-add')));
    await t.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const ValueKey('sf-gst')), matching: find.text('3%')), findsOneWidget);
    // a rule's price and a need's quantity
    await t.tap(find.byKey(const ValueKey('sf-rules-on')));
    await t.pumpAndSettle();
    await _tap(t, const ValueKey('sf-rule-add'));
    await t.enterText(find.byKey(const ValueKey('sf-rule-0-price')), 'free');
    await t.pump();
    expect(t.widget<EditableText>(find.descendant(of: find.byKey(const ValueKey('sf-rule-0-price')), matching: find.byType(EditableText))).controller.text, '');
    await _step(t, 5);
    await _tap(t, const ValueKey('sf-need-add'));
    await t.enterText(find.byKey(const ValueKey('sf-need-0-qty')), 'two');
    await t.pump();
    expect(t.widget<EditableText>(find.descendant(of: find.byKey(const ValueKey('sf-need-0-qty')), matching: find.byType(EditableText))).controller.text, '');
  });
}
