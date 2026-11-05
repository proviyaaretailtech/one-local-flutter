import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vinii_pos/catalogue/item_photo.dart';
import 'package:vinii_pos/service/catalogue_screen.dart';
import 'package:vinii_pos/service/service_api.dart';
import 'package:vinii_pos/service/service_form.dart';
import 'package:vinii_pos/service/service_parts.dart';
import 'package:vinii_pos/service/templates_pane.dart';
import 'package:vinii_pos/ui/xlsx.dart';

import 'service_screens_test.dart' show FakeRpc, serviceDetail, serviceList, show;

// Templates like the restaurant's recipe master, and the one Add service form (founder, 3 Nov 2026).

Map<String, dynamic> _manicure() => {
      'id': 'tp1',
      'name': 'Manicure',
      'category': 'service',
      'subcategory': 'Beauty parlour',
      'duration_min': 45,
      'notes': 'Classic manicure',
      'used_by': 2,
      'requirements': [
        {'type': 'person', 'item_id': null, 'name': 'Any staff', 'qty': 1},
        {'type': 'material', 'item_id': 'm1', 'name': 'Nail paint', 'qty': 1, 'unit': 'bottle'},
        {'type': 'tool', 'item_id': 't1', 'name': 'Nail filer', 'qty': 1},
      ],
      'rules': [
        {'category': 'Gender', 'condition': 'Women', 'result': 'Allowed'},
      ],
    };

Map<String, dynamic> _options() => {
      'listing': {},
      'can_edit': true,
      'places': [
        {'id': 'p1', 'name': 'Chair 1'},
      ],
      'tools': [
        {'id': 't1', 'name': 'Nail filer'},
      ],
      'materials': [
        {'id': 'm1', 'name': 'Nail paint', 'unit': 'bottle'},
      ],
      'team': [
        {'staff_id': 'st1', 'name': 'Neha Rao', 'title': 'Senior stylist'},
      ],
      'branches': [],
    };

FakeRpc _fake({List<Map<String, dynamic>>? templates}) {
  final list = templates ?? [_manicure()];
  return FakeRpc({
    'svc_service_list': (_) => serviceList(),
    'svc_service_detail': (_) => serviceDetail(),
    'svc_listing_view': (b) => b['service_id'] == null ? _options() : {..._options(), 'category': 'service', 'listing': {'subcategory': 'Unisex salon', 'requirements': []}},
    'svc_template_list': (b) => {'templates': list, 'total': list.length, 'can_edit': true},
    'svc_template_save': (b) => {'templates': list, 'total': list.length, 'can_edit': true, 'saved': _manicure()},
    'svc_template_import': (b) => {'templates': list, 'total': list.length, 'can_edit': true, 'added': 1, 'updated': 1},
    'svc_service_save': (_) => serviceDetail(),
    'svc_listing_save': (_) => _options(),
  });
}

/// Picks one small photo, for the cover.
class _OnePhoto extends _NoPhotos {
  @override
  Future<ItemPhoto?> pick() async =>
      ItemPhoto(bytes: base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='), contentType: 'image/png');
}

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

/// Jumps to a step of the form through its segment of the step bar (1 Basics, 2 How it is booked, 3 Where and who, 4 Price (with the
/// rules), 5 What it uses, 6 Notes and confirm).
Future<void> _step(WidgetTester t, int n) async {
  await _tap(t, ValueKey('sf-seg-${n - 1}'));
}

Future<void> _templatesTab(WidgetTester t, FakeRpc f) async {
  await show(t, ServiceCatalogueScreen(api: f.api));
  await t.tap(find.byKey(const ValueKey('tab-templates')));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('Templates tab: each template with what it needs, its rules and use; search', (t) async {
    final f = _fake();
    await _templatesTab(t, f);
    expect(find.byKey(const ValueKey('tpl-new')), findsNothing, reason: 'templates are made from Add service (Save as a template)');
    for (final s in ['Import', 'Export', '1 saved', 'Manicure', 'Service · Beauty parlour · 45 min', '1 person · 1 tool · 1 material', 'Used by 2',
      '1 rule · Women → Allowed']) {
      expect(find.text(s), findsWidgets, reason: s);
    }
    await t.enterText(find.byKey(const ValueKey('tpl-search')), 'filer');
    await t.pumpAndSettle();
    expect(f.of('svc_template_list').last.$2, {'q': 'filer'});
  });

  testWidgets('No templates yet says where they come from', (t) async {
    await _templatesTab(t, _fake(templates: []));
    expect(find.textContaining('tap "Save as a template" at the end'), findsOneWidget);
  });

  testWidgets('the template editor (Edit template), like a recipe: name, category, rows of what it needs picked from dropdowns, rules; Save template', (t) async {
    final f = _fake(templates: []);
    await show(t, TemplateEditorScreen(api: f.api));
    expect(find.text('New template'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('te-name')), 'Manicure');
    await _choose(t, const ValueKey('te-category'), 'Service');
    await _choose(t, const ValueKey('te-subcategory'), 'Beauty parlour');
    await _choose(t, const ValueKey('te-length'), '45 min');
    // in steps like every form: Template, What it needs, Rules, Notes (Save template on the last)
    expect(find.text('Step 1 of 4'), findsOneWidget);
    expect(find.byKey(const ValueKey('te-save')), findsNothing);
    // one person (picked from the team), a bottle of nail paint, a filer
    await _tap(t, const ValueKey('te-next'));
    expect(find.text('Step 2 of 4'), findsOneWidget);
    await _tap(t, const ValueKey('te-need-add'));
    await _choose(t, const ValueKey('te-need-0-item'), 'Neha Rao · Senior stylist');
    await _tap(t, const ValueKey('te-need-add'));
    await _choose(t, const ValueKey('te-need-1-type'), 'Material');
    expect(find.text('Nail paint'), findsWidgets, reason: 'the first material is picked');
    await _tap(t, const ValueKey('te-need-add'));
    await _choose(t, const ValueKey('te-need-2-type'), 'Tool');
    await _tap(t, const ValueKey('te-need-add'));
    await _choose(t, const ValueKey('te-need-3-type'), 'Other');
    await t.enterText(find.byKey(const ValueKey('te-need-3-name')), 'Cotton pads');
    expect(find.text('1 person · 1 tool · 1 material · 1 other item'), findsOneWidget);
    // a rule on a category the publisher picks
    await _tap(t, const ValueKey('te-seg-2'));
    await _tap(t, const ValueKey('te-rule-add'));
    // one rule combines conditions (the design's builder): 5 or more people + 18 and above → ₹250 per group
    await _choose(t, const ValueKey('te-rule-0-category'), 'Number of people');
    await _choose(t, const ValueKey('te-rule-0-condition'), '5 or more');
    await _tap(t, const ValueKey('te-rule-0-and'));
    expect(find.byKey(const ValueKey('te-rule-0-1-condition')), findsOneWidget);
    await _choose(t, const ValueKey('te-rule-0-result'), 'Different price');
    await t.enterText(find.byKey(const ValueKey('te-rule-0-price')), '250');
    await _choose(t, const ValueKey('te-rule-0-per'), 'per group');
    await _tap(t, const ValueKey('te-seg-3'));
    await _tap(t, const ValueKey('te-save'));
    final sent = f.of('svc_template_save').single;
    expect(sent.$3, startsWith('svc-'));
    expect(sent.$2['name'], 'Manicure');
    expect(sent.$2['category'], 'service');
    expect(sent.$2['subcategory'], 'Beauty parlour');
    expect(sent.$2['duration_min'], 45);
    expect(sent.$2['requirements'], [
      {'type': 'person', 'name': 'Neha Rao · Senior stylist', 'qty': 1, 'item_id': 'st1'},
      {'type': 'material', 'item_id': 'm1', 'name': 'Nail paint', 'qty': 1, 'unit': 'bottle'},
      {'type': 'tool', 'item_id': 't1', 'name': 'Nail filer', 'qty': 1},
      {'type': 'other', 'item_id': null, 'name': 'Cotton pads', 'qty': 1, 'unit': 'pcs'},
    ]);
    expect(sent.$2['rules'], [
      {
        'conditions': [
          {'category': 'Number of people', 'condition': '5 or more'},
          {'category': 'Age', 'condition': '18 and above'},
        ],
        'result': 'Different price',
        'per': 'per group',
        'price': 250,
      },
    ]);
  });

  testWidgets('Export writes one sheet a row per need and rule; Import reads it back and sends the templates', (t) async {
    Uint8List? file;
    saveTemplatesFile = (bytes, name) async => file = bytes;
    final f = _fake();
    await _templatesTab(t, f);
    await _tap(t, const ValueKey('tpl-export'));
    final rows = readXlsx(file!);
    expect(rows.first.first, 'Template');
    expect(rows.where((r) => r.first == 'Manicure').length, 4, reason: '3 needs and 1 rule');
    expect(rows[1].take(4).toList(), ['Manicure', 'Service', 'Beauty parlour', '45']);

    pickTemplatesFile = () async => (name: 'templates.xlsx', bytes: file!);
    await _tap(t, const ValueKey('tpl-import'));
    await _tap(t, const ValueKey('tpl-import-pick'));
    final sent = (f.of('svc_template_import').single.$2['templates'] as List).single as Map;
    expect(sent['name'], 'Manicure');
    expect(sent['duration_min'], 45);
    expect((sent['requirements'] as List)[1], {'type': 'material', 'item_id': 'm1', 'name': 'Nail paint', 'qty': 1, 'unit': 'bottle'},
        reason: 'matched to the material in Inventory by name');
    expect(sent['rules'], [
      {
        'conditions': [
          {'category': 'Gender', 'condition': 'Women'}
        ],
        'result': 'Allowed',
        'per': 'each',
      }
    ]);
    expect(find.text('1 added · 1 replaced.'), findsOneWidget);
  });

  test('a row naming something not in Inventory is kept by name', () {
    final t = templatesFromRows([
      kTemplateColumns,
      ['Facial', 'Service', 'Spa', '60', 'Needs', 'Material', 'Face mask', '2', 'pcs', '', '', ''],
      ['Facial', '', '', '', 'Rule', 'Age', '18 and above', '', '', 'Allowed', '', ''],
    ], const NeedsOptions());
    expect(t.single['requirements'], [
      {'type': 'material', 'item_id': null, 'name': 'Face mask', 'qty': 2, 'unit': 'pcs'}
    ]);
    expect(t.single['category'], 'service');
    expect(needsSummary([
      {'type': 'person'},
      {'type': 'person'},
      {'type': 'material'},
    ]), '2 people · 1 material');
  });

  testWidgets('the one form: a template fills what it needs, its rules and length; Publish saves the service, its listing and the uses', (t) async {
    final f = _fake();
    await show(t, ServiceFormScreen(api: f.api, photos: _NoPhotos()));
    expect(find.byKey(const ValueKey('sf-template')), findsNothing, reason: 'templates are picked in Add service\'s list, not inside the form');
    await show(t, ServiceFormScreen(key: UniqueKey(), api: f.api, template: ServiceTemplate(_manicure()), photos: _NoPhotos()));
    expect(find.text('From template: Manicure'), findsOneWidget);
    await t.pump(const Duration(seconds: 4)); // the "filled in" note goes
    await t.pumpAndSettle();
    await _step(t, 2);
    expect(find.text('45 min'), findsOneWidget);
    await _step(t, 4);
    await t.enterText(find.byKey(const ValueKey('sf-price')), '400');
    await t.pumpAndSettle();
    await _step(t, 5);
    expect(find.text('1 person · 1 tool · 1 material'), findsOneWidget);
    expect(find.text('Nail filer'), findsOneWidget);
    await _step(t, 6);
    await _tap(t, const ValueKey('sf-publish'));
    final core = f.of('svc_service_save').single.$2;
    expect(core['name'], 'Manicure', reason: 'an empty name takes the template name');
    expect(core['price'], 400);
    expect(core['category'], 'Beauty parlour');
    expect(core['duration_min'], 45);
    expect(core['is_bookable'], true);
    final l = f.of('svc_listing_save').single.$2;
    expect(l['category'], 'service');
    final listing = l['listing'] as Map;
    expect(listing['template_id'], 'tp1');
    expect(listing['tool_ids'], ['t1']);
    expect(listing['materials'], [
      {'id': 'm1', 'qty': 1, 'unit': 'bottle'}
    ]);
    expect((listing['rules'] as List).single, containsPair('condition', 'Women'));
    expect(f.of('svc_template_save'), isEmpty);
  });

  testWidgets('the one form: "Save as a template" at the end saves this setup under a name and keeps the form open; nothing is published without a category', (t) async {
    final f = _fake(templates: []);
    await show(t, ServiceFormScreen(api: f.api, photos: _NoPhotos()));
    await t.enterText(find.byKey(const ValueKey('sf-name')), 'AC deep clean');
    await _step(t, 4);
    await t.enterText(find.byKey(const ValueKey('sf-price')), '1200');
    await _step(t, 6);
    await _tap(t, const ValueKey('sf-publish'));
    expect(find.text('Choose the category and subcategory.'), findsOneWidget);
    expect(find.text('Basics'), findsWidgets, reason: 'taken back to the step with what is missing');
    expect(find.text('Step 1 of 6'), findsOneWidget);
    expect(f.of('svc_service_save'), isEmpty);
    await t.pump(const Duration(seconds: 4));
    await _tap(t, const ValueKey('sf-cat-service'));
    await _choose(t, const ValueKey('sf-sub_group'), 'Home and repairs');
    await _choose(t, const ValueKey('sf-subcategory'), 'Appliance and AC repair');
    await _step(t, 5);
    await _tap(t, const ValueKey('sf-need-add'));
    // Save as a template sits on the last step, with Save draft and Publish
    expect(find.byKey(const ValueKey('sf-save-template')), findsNothing);
    await _step(t, 6);
    expect(find.byKey(const ValueKey('sf-draft')), findsOneWidget);
    await _tap(t, const ValueKey('sf-save-template'));
    expect(find.text('Save as a template'), findsWidgets);
    expect(t.widget<TextField>(find.byKey(const ValueKey('ask-text'))).controller!.text, 'AC deep clean', reason: 'the service name to start with');
    await t.enterText(find.byKey(const ValueKey('ask-text')), 'AC service basic');
    await t.tap(find.text('Save template').last);
    await t.pumpAndSettle();
    final tpl = f.of('svc_template_save').single.$2;
    expect(tpl['name'], 'AC service basic');
    expect(tpl['subcategory'], 'Appliance and AC repair');
    expect(tpl['requirements'], [
      {'type': 'person', 'name': 'Any staff', 'qty': 1}
    ]);
    expect(f.of('svc_service_save'), isEmpty, reason: 'saving a template does not publish');
    expect(find.byType(ServiceFormScreen), findsOneWidget, reason: 'the form stays open');
    await t.pump(const Duration(seconds: 4));
    await t.pumpAndSettle();
    await _tap(t, const ValueKey('sf-draft'));
    expect(f.of('svc_service_save').single.$2['is_bookable'], false);
  });

  testWidgets('a template\'s "Use for a new service" opens the form filled from it; Edit opens the same form', (t) async {
    final f = _fake();
    await _templatesTab(t, f);
    await _tap(t, const ValueKey('tpl-tp1'));
    await _tap(t, const ValueKey('tpl-use'));
    expect(find.byType(ServiceFormScreen), findsOneWidget);
    expect(find.text('From template: Manicure'), findsOneWidget);
  });

  testWidgets('Add from existing templates: a screen of templates with search; a tap opens the form filled from it', (t) async {
    final f = _fake();
    await show(t, ServiceCatalogueScreen(api: f.api));
    await _tap(t, const ValueKey('add-service'));
    await _tap(t, const ValueKey('add-kind-templates'));
    expect(find.byType(TemplatePickScreen), findsOneWidget);
    expect(find.text('Add from existing templates'), findsWidgets);
    expect(find.byKey(const ValueKey('tpl-new')), findsNothing, reason: 'only picking here');
    expect(find.byKey(const ValueKey('tpl-import')), findsNothing);
    await _tap(t, const ValueKey('tpl-tp1'));
    expect(find.byType(ServiceFormScreen), findsOneWidget);
    expect(find.text('From template: Manicure'), findsOneWidget);
  });

  testWidgets('Edit opens the same one form, filled in', (t) async {
    final g = _fake();
    await show(t, ServiceCatalogueScreen(key: UniqueKey(), api: g.api));
    await _tap(t, const ValueKey('more-s1'));
    await t.tap(find.text('Edit service'));
    await t.pumpAndSettle();
    expect(find.textContaining('Edit listing'), findsWidgets);
    expect(find.byType(ServiceFormScreen), findsOneWidget);
    expect(find.text('Unisex salon'), findsOneWidget);
  });

  testWidgets('short fields sit two to a row on a phone, three on a wide screen; need rows go on one line when there is room', (t) async {
    Future<double> widthOf(Size size) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(home: ServiceFormScreen(key: UniqueKey(), api: _fake().api, photos: _NoPhotos())));
      await t.pumpAndSettle();
      await _step(t, 2);
      return t.getSize(find.byKey(const ValueKey('sf-duration'))).width;
    }

    expect(await widthOf(const Size(390, 2400)), lessThan(390 / 2));
    expect(await widthOf(const Size(1000, 2400)), lessThan(860 / 3));
  });

  test('lengthLabel and listingMinutes agree', () {
    for (final l in kLengths) {
      expect(lengthLabel(listingMinutes(l)), l);
    }
    expect(ServiceTemplate(_manicure()).requirements.length, 3);
  });

  // Founder, 4 Nov 2026: "each drop down in the app should have a + add option to add their own options in the field".
  Future<void> addOwn(WidgetTester t, Key box, String typed) async {
    await _tap(t, box);
    await t.ensureVisible(find.byKey(const ValueKey('opt-add')).last);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('opt-add')).last);
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('ask-text')), typed);
    await t.pump();
    await t.tap(find.byKey(const ValueKey('own-add')));
    await t.pumpAndSettle();
  }

  testWidgets('every dropdown ends with + Add: the typed option fills the box, is listed next time and is saved with the service', (t) async {
    SharedPreferences.setMockInitialValues({});
    CustomOptions.reset();
    final f = _fake(templates: []);
    await show(t, ServiceFormScreen(api: f.api, photos: _NoPhotos()));
    await t.enterText(find.byKey(const ValueKey('sf-name')), 'Gutter clean');
    // the category is one of the five tiles (customers browse by it), never a dropdown with + Add
    expect(find.byKey(const ValueKey('sf-category')), findsNothing);
    await _tap(t, const ValueKey('sf-cat-service'));

    await _choose(t, const ValueKey('sf-sub_group'), 'Home and repairs');
    await addOwn(t, const ValueKey('sf-subcategory'), 'Gutter cleaning');
    expect(find.descendant(of: find.byKey(const ValueKey('sf-subcategory')), matching: find.text('Gutter cleaning')), findsOneWidget);
    await _tap(t, const ValueKey('sf-subcategory'));
    expect(find.text('Add subcategory'), findsOneWidget);
    expect(find.byKey(const ValueKey('opt-Gutter cleaning')), findsOneWidget, reason: 'listed next time, under Your own');
    await t.tapAt(const Offset(5, 5));
    await t.pumpAndSettle();

    await _step(t, 2);
    await addOwn(t, const ValueKey('sf-duration'), '75');
    expect(find.descendant(of: find.byKey(const ValueKey('sf-duration')), matching: find.text('75 min')), findsOneWidget, reason: 'a bare number is minutes');
    // the box opens where the dropdown is, not as a sheet from the bottom; a length takes digits and a unit, no letters
    await _tap(t, const ValueKey('sf-buffer'));
    await t.ensureVisible(find.byKey(const ValueKey('opt-add')).last);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('opt-add')).last);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('own-box')), findsOneWidget);
    expect((t.getTopLeft(find.byKey(const ValueKey('own-box'))).dy - t.getBottomLeft(find.byKey(const ValueKey('sf-buffer'))).dy).abs(), lessThan(20),
        reason: 'right under the dropdown');
    await t.enterText(find.byKey(const ValueKey('ask-text')), 'soon');
    await t.pump();
    expect(t.widget<TextField>(find.byKey(const ValueKey('ask-text'))).controller!.text, '', reason: 'letters are not allowed');
    expect(t.widget<FilledButton>(find.byKey(const ValueKey('own-add'))).onPressed, isNull);
    await t.enterText(find.byKey(const ValueKey('ask-text')), '2');
    await t.tap(find.byKey(const ValueKey('own-unit-hr')));
    await t.pump();
    expect(find.text('Add "2 hr"'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('own-add')));
    await t.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const ValueKey('sf-buffer')), matching: find.text('2 hr')), findsOneWidget);
    await _step(t, 3);
    await addOwn(t, const ValueKey('sf-people_max'), '120');
    await _step(t, 4);
    await addOwn(t, const ValueKey('sf-pricing'), 'Per metre');
    await t.enterText(find.byKey(const ValueKey('sf-price')), '900');

    await _step(t, 6);
    await _tap(t, const ValueKey('sf-publish'));
    final svc = f.of('svc_service_save').single.$2;
    expect(svc['category'], 'Gutter cleaning');
    expect(svc['duration_min'], 75);
    expect(svc['capacity'], 120);
    expect((f.of('svc_listing_save').single.$2['listing'] as Map)['pricing'], 'Per metre');
    expect(CustomOptions.of('Pricing basis'), ['Per metre']);
  });

  testWidgets('+ Add in what a service needs: a typed item is kept by name; the type stays one of the five', (t) async {
    SharedPreferences.setMockInitialValues({});
    CustomOptions.reset();
    final f = _fake(templates: []);
    await show(t, ServiceFormScreen(api: f.api, photos: _NoPhotos()));
    await _step(t, 5);
    await _tap(t, const ValueKey('sf-need-add'));
    await _tap(t, const ValueKey('sf-need-0-type'));
    expect(find.byKey(const ValueKey('opt-add')), findsNothing);
    await t.tap(find.byKey(const ValueKey('opt-Person')).last);
    await t.pumpAndSettle();
    await addOwn(t, const ValueKey('sf-need-0-item'), 'Trainee');
    expect(find.descendant(of: find.byKey(const ValueKey('sf-need-0-item')), matching: find.text('Trainee')), findsOneWidget);
  });

  test('typed lengths and counts', () {
    expect([for (final x in ['75', '75 min', '2 hr', '1.5 hours', '2 days', '0', 'soon']) tidyLength(x)], ['75 min', '75 min', '2 hr', '1.5 hr', '2 day', null, null]);
    expect([tidyCount('12'), tidyCount('0'), tidyCount('x')], ['12', null, null]);
  });

  testWidgets('in steps: the circle shows 1/6 and the next step; Next and the small Back move between them; save buttons only on the last', (t) async {
    final f = _fake(templates: []);
    await show(t, ServiceFormScreen(api: f.api, category: 'events', photos: _NoPhotos()));
    expect(find.text('Step 1 of 6'), findsOneWidget);
    expect(find.text('Basics'), findsWidgets);
    expect(find.text('Next: How it is booked'), findsWidgets);
    // the step bar sits under the step's name: six segments, the first one green
    expect(t.getTopLeft(find.byKey(const ValueKey('sf-seg-0'))).dy, greaterThan(t.getTopLeft(find.text('Basics').first).dy));
    expect(find.byKey(const ValueKey('sf-seg-5')), findsOneWidget);
    expect(find.byKey(const ValueKey('sf-back')), findsNothing, reason: 'the first step has Close instead');
    expect(find.byKey(const ValueKey('sf-publish')), findsNothing);
    expect(find.byKey(const ValueKey('sf-filled')), findsNothing, reason: 'no percentage bar any more');
    for (final (i, name) in [(2, 'How it is booked'), (3, 'Where and who'), (4, 'Price'), (5, 'What it uses'), (6, 'Notes and confirm')]) {
      await _tap(t, const ValueKey('sf-next'));
      expect(find.text('Step $i of 6'), findsOneWidget);
      expect(find.text(name), findsWidgets);
    }
    expect(find.text('Last step: save or publish'), findsOneWidget);
    expect(find.byKey(const ValueKey('sf-next')), findsNothing);
    for (final k in ['sf-save-template', 'sf-draft', 'sf-publish']) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }
    await _tap(t, const ValueKey('sf-back'));
    expect(find.text('Step 5 of 6'), findsOneWidget);
    expect(find.text('What it uses'), findsWidgets);
  });

  testWidgets('photos and videos in one compact row: Add opens Photo / Video / Camera on the tile; the first photo is the cover, the rest banners; x takes one off', (t) async {
    final f = _fake(templates: []);
    var n = 0;
    await show(
        t,
        ServiceFormScreen(
            api: f.api,
            category: 'service',
            photos: _OnePhoto(),
            addMedia: ({required bool video}) async => (url: 'https://cdn.test/${++n}.${video ? 'mp4' : 'jpg'}', kind: video ? 'video' : 'image')));
    // the banner on top, as customers will see it (4 Nov 2026): a big box to add to until there are photos
    expect(find.byKey(const ValueKey('sf-hero')), findsOneWidget);
    expect(find.text('Add photos and videos'), findsOneWidget);
    expect(t.getTopLeft(find.byKey(const ValueKey('sf-hero'))).dy, lessThan(t.getTopLeft(find.byKey(const ValueKey('sf-name'))).dy), reason: 'above the name');
    expect(find.text('Choose a photo'), findsNothing, reason: 'one compact row, no separate photo button');
    Future<void> add(String what) async {
      await _tap(t, const ValueKey('sf-media-add'));
      await t.tap(find.byKey(ValueKey('sf-media-$what')));
      await t.pumpAndSettle();
    }

    await _tap(t, const ValueKey('sf-media-add'));
    expect(find.text('Cover photo'), findsOneWidget, reason: 'the first photo is the cover');
    expect(find.text('Camera'), findsOneWidget);
    await t.tapAt(const Offset(5, 5));
    await t.pumpAndSettle();
    await add('photo');
    expect(find.byKey(const ValueKey('sf-cover')), findsOneWidget);
    expect(find.text('Add photos and videos'), findsNothing, reason: 'the banner now shows the photo');
    expect(find.text('Photos and videos'), findsOneWidget, reason: 'the row to check or take one off');
    expect(find.text('Cover'), findsNWidgets(2), reason: 'on the banner and on its thumbnail');
    await add('photo');
    await add('video');
    await add('photo');
    expect(find.byKey(const ValueKey('sf-media-2')), findsOneWidget);
    expect(find.text('Video'), findsOneWidget);
    await _tap(t, const ValueKey('sf-media-remove-2'));
    expect(find.byKey(const ValueKey('sf-media-2')), findsNothing);
    expect(t.getSize(find.byKey(const ValueKey('sf-media-add'))).height, lessThan(90), reason: 'compact');
    await t.enterText(find.byKey(const ValueKey('sf-name')), 'Pest control');
    await _choose(t, const ValueKey('sf-sub_group'), 'Home and repairs');
    await _choose(t, const ValueKey('sf-subcategory'), 'Appliance and AC repair');
    await _step(t, 4);
    await t.enterText(find.byKey(const ValueKey('sf-price')), '700');
    await _step(t, 6);
    await _tap(t, const ValueKey('sf-draft'));
    expect((f.of('svc_listing_save').single.$2['listing'] as Map)['media'], [
      {'kind': 'image', 'url': 'https://cdn.test/1.jpg'},
      {'kind': 'video', 'url': 'https://cdn.test/2.mp4'},
    ]);
  });

  test('the six steps', () {
    expect([for (final s in kServiceSteps) s.$1], ['Basics', 'How it is booked', 'Where and who', 'Price', 'What it uses', 'Notes and confirm']);
  });

  testWidgets('on a 375 px phone every step fits: no overflow from the circle header to the three buttons on the last step', (t) async {
    t.view.physicalSize = const Size(375, 812);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(home: ServiceFormScreen(api: _fake().api, category: 'service', photos: _NoPhotos())));
    await t.pumpAndSettle();
    for (var i = 0; i < 5; i++) {
      expect(t.takeException(), isNull, reason: 'step ${i + 1}');
      await t.tap(find.byKey(const ValueKey('sf-next')));
      await t.pumpAndSettle();
    }
    expect(t.takeException(), isNull, reason: 'step 6');
    expect(find.byKey(const ValueKey('sf-publish')), findsOneWidget);
  });

  // The design canvas's listing forms (founder, 4 Nov 2026: "check these screens are in their respective forms ... the data points")
  testWidgets("each category shows the design's fields: Stay by the night, Events by entry, Play units and parts, Service on call, Activities safety", (t) async {
    Future<void> open(String cat) async {
      await show(t, ServiceFormScreen(key: UniqueKey(), api: _fake(templates: []).api, category: cat, photos: _NoPhotos()));
    }

    bool has(String k) => find.byKey(ValueKey('sf-$k')).evaluate().isNotEmpty;

    await open('stay');
    expect(has('amenity-WiFi'), isTrue);
    await _step(t, 2);
    expect(find.text('Nights'), findsWidgets);
    for (final k in ['check_in', 'check_out', 'min_stay', 'book_up_to', 'min_notice']) {
      expect(has(k), isTrue, reason: 'stay: $k');
    }
    expect(has('duration'), isFalse, reason: 'a stay has no slot length');
    await _step(t, 3);
    for (final k in ['adults', 'children', 'guest_id', 'age_rule', 'booked_for']) {
      expect(has(k), isTrue, reason: 'stay: $k');
    }
    expect(has('where'), isFalse);
    await _step(t, 4);
    expect(has('weekend_price'), isTrue);
    expect(has('extra_guest'), isTrue);
    await _step(t, 5);
    expect(has('after_checkout'), isTrue);

    await open('events');
    expect(has('amenity-Stage'), isTrue, reason: 'amenities on every category, its own list');
    await _step(t, 2);
    for (final k in ['entry_valid', 'event_date', 'starts_at', 'repeats']) {
      expect(has(k), isTrue, reason: 'events: $k');
    }
    await _step(t, 3);
    for (final k in ['where', 'capacity', 'max_per_booking', 'age_rule', 'gender_rule']) {
      expect(has(k), isTrue, reason: 'events: $k');
    }

    await open('play');
    await _step(t, 2);
    for (final k in ['unit_kind', 'unit_count', 'duration', 'start_every', 'shortest', 'longest', 'length_step', 'late_grace', 'no_show', 'unit-add', 'band-add', 'part-bookings', 'mark-arrived']) {
      expect(has(k), isTrue, reason: 'play: $k');
    }
    await _tap(t, const ValueKey('sf-unit-add'));
    expect(has('unit-0-surface'), isTrue);
    await t.tap(find.byKey(const ValueKey('sf-part-bookings')));
    await t.pumpAndSettle();
    await _step(t, 3);
    expect(has('where'), isFalse, reason: 'players come to the venue');
    expect(has('safety_rule'), isTrue);
    await _step(t, 4);
    expect(has('part-add'), isTrue, reason: 'parts and prices once part bookings are on');
    expect(has('addon-add'), isTrue);

    await open('service');
    expect(has('amenity-WiFi'), isTrue, reason: 'amenities on every category');
    await _step(t, 3);
    expect(has('ask-staff'), isTrue);
    expect(has('oncall_area'), isFalse, reason: 'only when it is done on call');
    await _choose(t, const ValueKey('sf-where'), 'On call');
    expect(has('oncall_area'), isTrue);
    expect(has('travel_charge'), isTrue);

    await open('activities');
    expect(has('amenity-Lockers'), isTrue);
    await _step(t, 3);
    expect(has('safety-terms'), isTrue);
    expect(has('safety_rule'), isTrue);
  });

  testWidgets("a stay saves its nights, guests and notice: capacity is adults + children; the design's answers go with the listing", (t) async {
    final f = _fake(templates: []);
    await show(t, ServiceFormScreen(api: f.api, category: 'stay', photos: _NoPhotos()));
    await t.enterText(find.byKey(const ValueKey('sf-name')), 'Deluxe double room');
    await _choose(t, const ValueKey('sf-subcategory'), 'Hotel');
    await _step(t, 2);
    await _choose(t, const ValueKey('sf-check_in'), '12:00 pm');
    await _choose(t, const ValueKey('sf-min_notice'), '1 day');
    await _step(t, 3);
    await _choose(t, const ValueKey('sf-adults'), '2');
    await _choose(t, const ValueKey('sf-children'), '1');
    await _choose(t, const ValueKey('sf-guest_id'), 'Required at check-in');
    await _step(t, 4);
    await t.enterText(find.byKey(const ValueKey('sf-price')), '3200');
    await t.enterText(find.byKey(const ValueKey('sf-weekend_price')), '3800');
    await _choose(t, const ValueKey('sf-advance'), 'First night');
    await _step(t, 6);
    await _tap(t, const ValueKey('sf-draft'));
    final core = f.of('svc_service_save').single.$2;
    expect(core['capacity'], 3);
    expect(core['min_notice_min'], 1440);
    expect(core['price'], 3200);
    final listing = f.of('svc_listing_save').single.$2['listing'] as Map;
    expect(listing['booking_type'], 'Nights');
    expect(listing['check_in'], '12:00 pm');
    expect(listing['guest_id'], 'Required at check-in');
    expect(listing['weekend_price'], '3800');
    expect(listing['advance'], 'First night');
  });

  testWidgets('no Dining anywhere in the Service POS', (t) async {
    expect([for (final c in listingCategories) c.key], ['events', 'activities', 'play', 'service', 'stay']);
  });

  testWidgets('every category fits a 375 px phone on every step', (t) async {
    t.view.physicalSize = const Size(375, 812);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    for (final cat in ['events', 'activities', 'play', 'service', 'stay']) {
      await t.pumpWidget(MaterialApp(home: ServiceFormScreen(key: UniqueKey(), api: _fake().api, category: cat, photos: _NoPhotos())));
      await t.pumpAndSettle();
      for (var i = 0; i < 5; i++) {
        expect(t.takeException(), isNull, reason: '$cat step ${i + 1}');
        await t.tap(find.byKey(const ValueKey('sf-next')));
        await t.pumpAndSettle();
      }
      expect(t.takeException(), isNull, reason: '$cat step 6');
    }
  });

  testWidgets('a service saved before the categories opens as a Service with its fields; a template without one asks first', (t) async {
    final f = _fake(templates: []);
    // an older service: category "Grooming" (not a subcategory), booked by appointment
    await show(t, ServiceFormScreen(api: f.api, detail: ServiceDetail(serviceDetail()), photos: _NoPhotos()));
    expect(find.text('Edit listing · Service'), findsOneWidget);
    // its category was guessed: the tiles ask once, with Service picked; after a tap it is fixed
    expect(find.text('Check what this is'), findsOneWidget);
    await _tap(t, const ValueKey('sf-cat-service'));
    expect(find.byKey(const ValueKey('sf-category-first')), findsNothing);
    expect(find.byKey(const ValueKey('sf-category-line')), findsOneWidget);
    await _step(t, 3);
    expect(find.byKey(const ValueKey('sf-ask-staff')), findsOneWidget, reason: 'the Service form\'s own fields');

    await show(t, ServiceFormScreen(key: UniqueKey(), api: f.api, template: ServiceTemplate({..._manicure(), 'category': null, 'subcategory': null}), photos: _NoPhotos()));
    expect(find.byKey(const ValueKey('sf-category-first')), findsOneWidget);
    expect(find.text('New listing'), findsOneWidget);
    await _tap(t, const ValueKey('sf-cat-play'));
    expect(find.text('New listing · Play'), findsOneWidget);
    expect(find.byKey(const ValueKey('sf-amenity-WiFi')), findsOneWidget);
    await _step(t, 2);
    expect(find.byKey(const ValueKey('sf-unit_kind')), findsOneWidget);
  });

  testWidgets('rules live in Price, folded under a switch; a template\'s rules open it; turning it off clears them', (t) async {
    final f = _fake(templates: []);
    await show(t, ServiceFormScreen(api: f.api, category: 'events', photos: _NoPhotos()));
    await _step(t, 4);
    expect(find.byKey(const ValueKey('sf-rules-on')), findsOneWidget);
    expect(find.byKey(const ValueKey('sf-rule-add')), findsNothing, reason: 'folded until needed');
    expect(find.text('Price for everyone else'), findsNothing);
    await t.tap(find.byKey(const ValueKey('sf-rules-on')));
    await t.pumpAndSettle();
    expect(find.text('Price for everyone else'), findsOneWidget, reason: 'the price stays: whoever no rule matches pays it');
    await _tap(t, const ValueKey('sf-rule-add'));
    expect(find.text('Rule 1'), findsOneWidget);
    expect(t.getTopLeft(find.byKey(const ValueKey('sf-rule-add'))).dy, greaterThan(t.getTopLeft(find.byKey(const ValueKey('sf-price'))).dy), reason: 'after the base price');
    await t.tap(find.byKey(const ValueKey('sf-rules-on')));
    await t.pumpAndSettle();
    expect(find.text('Rule 1'), findsNothing);

    await show(t, ServiceFormScreen(key: UniqueKey(), api: f.api, template: ServiceTemplate(_manicure()), photos: _NoPhotos()));
    await _step(t, 4);
    expect(find.text('Rule 1'), findsOneWidget, reason: 'the template\'s rule shows without turning anything on');
  });
}
