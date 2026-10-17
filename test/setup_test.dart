import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/auth/partner_api.dart';
import 'package:vinii_pos/onboarding/document_picker.dart';
import 'package:vinii_pos/setup/business_screens.dart';
import 'package:vinii_pos/setup/operations_screens.dart';
import 'package:vinii_pos/setup/setup_api.dart';
import 'package:vinii_pos/setup/setup_flow.dart';
import 'package:vinii_pos/setup/storefront_screens.dart';

import 'helpers.dart';

/// Setup as the server describes it. [done] lists the checklist keys already done; [seen] the coach marks already read.
SetupState sampleSetup({
  Set<String> done = const {'business_profile', 'location', 'owner_details', 'plan'},
  List<int> seen = const [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
  String type = 'store',
  bool posRequired = true,
  bool completed = false,
  Map<String, dynamic>? extra,
}) {
  final rows = <Map<String, dynamic>>[];
  void row(String key, String title, bool req, [String? note]) => rows.add({
        'key': key, 'title': title, 'required': req, 'done': done.contains(key), 'note': ?note,
        'status': done.contains(key) ? 'completed' : (req ? 'pending' : 'optional'),
      });
  row('business_profile', 'Business Profile', true);
  row('location', 'Location', true);
  row('owner_details', 'Owner Details', true);
  row('plan', 'Plan & Subscription', true);
  row('catalogue', 'Catalogue', true);
  row('payment', 'Payment Setup', true);
  row('staff', 'Staff', false, 'Optional');
  row('inventory', 'Inventory', false, 'Optional');
  row('onelocal_profile', 'OneLocal Profile', true);
  if (posRequired) row('pos', 'POS Setup', true);
  row('delivery', 'Delivery / Fulfilment', false, 'When applicable');
  final req = rows.where((r) => r['required'] == true);
  final reqDone = req.where((r) => r['done'] == true).length;
  return SetupState({
    'organization': {'id': 'o1', 'name': 'Sharma General Store', 'partner_type': type, 'sell_plan': posRequired ? 'pos_and_onelocal' : 'onelocal_app'},
    'checklist': rows,
    'progress': {'done': reqDone, 'total': req.length, 'can_complete': reqDone == req.length, 'completed': completed,
      'next': req.where((r) => r['done'] != true).map((r) => r['key']).firstOrNull},
    'tour_seen': seen,
    'plan': {'selected_code': 'starter', 'confirmed': done.contains('plan'), 'sell_plan': 'pos_and_onelocal', 'available': [
      {'code': 'starter', 'name': 'Retail Starter', 'cadence': 'Monthly', 'price': 0, 'users_limit': 2, 'locations_limit': 1, 'modules': ['POS billing', 'Catalogue']},
    ]},
    'payment': {'saved': done.contains('payment'), 'holder_name': 'Riya Sharma', 'account_masked': '•••• •••• 6789', 'bank_status': 'verified', 'accept_upi': false, 'accept_card': false},
    'tax': {'saved': done.contains('payment'), 'gst_registered': null, 'invoice_prefix': 'INV', 'prices_include_tax': true, 'show_address_on_receipt': true, 'show_gstin_on_invoice': true},
    'pos': {'required': posRequired, 'registered': done.contains('pos'), 'devices': [], 'kot_allowed': type == 'restaurant'},
    'staff': {'invites': [], 'roles': type == 'restaurant' ? ['cashier', 'manager', 'kitchen'] : ['cashier', 'manager']},
    'catalogue': {'items': done.contains('catalogue') ? 2 : 0, 'names_done': done.contains('catalogue'), 'prices_done': false, 'categories': ['Staples']},
    'listing': {'saved': done.contains('onelocal_profile'), 'public_name': 'Sharma General Store', 'description': null, 'address_line': '12 Main Road, Latur', 'open_days': null},
    'fulfilment': {'saved': done.contains('delivery'), 'pickup': true, 'self_delivery': false, 'onelocal_delivery': false, 'delivery_hours': 'same_as_opening'},
    ...?extra,
  });
}

const allDone = {'business_profile', 'location', 'owner_details', 'plan', 'catalogue', 'payment', 'onelocal_profile', 'pos'};

class FakeSetup extends SetupApi {
  FakeSetup({SetupState? initial}) : state = initial ?? sampleSetup(), super(accessToken: () => 't', baseUrl: 'http://x');
  SetupState state;
  SetupState? after;           // what saves return; defaults to [state]
  final calls = <String>[];
  final bodies = <String, Map<String, dynamic>>{};
  Object? failWith;

  Future<SetupState> _do(String what, [Map<String, dynamic>? body]) async {
    calls.add(what);
    if (body != null) bodies[what] = body;
    if (failWith != null) throw failWith!;
    return after ?? state;
  }

  @override
  Future<SetupState> get() => _do('get');
  @override
  Future<SetupState> confirmPlan(String? code) => _do('plan $code');
  @override
  Future<SetupState> savePayment(Map<String, dynamic> b) => _do('payment', b);
  @override
  Future<SetupState> saveTax(Map<String, dynamic> b) => _do('tax', b);
  @override
  Future<SetupState> registerPos(Map<String, dynamic> b) => _do('pos', b);
  @override
  Future<SetupState> inviteStaff(Map<String, dynamic> b) => _do('staff', b);
  @override
  Future<SetupState> addItem(Map<String, dynamic> b) => _do('item', b);
  @override
  Future<SetupState> saveListing(Map<String, dynamic> b) => _do('listing', b);
  @override
  Future<SetupState> saveFulfilment(Map<String, dynamic> b) => _do('fulfilment', b);
  @override
  Future<SetupState> tourSeen(int step) => _do('tour $step');
  @override
  Future<SetupState> complete() => _do('complete');
  @override
  Future<SetupState> uploadImage({required String kind, required Uint8List bytes, required String contentType}) => _do('image $kind $contentType');
}

class FakePicker extends DocumentPicker {
  const FakePicker(this.doc);
  final PickedDocument? doc;
  @override
  Future<PickedDocument?> pick() async => doc;
}

Future<void> tap(WidgetTester t, String text) async {
  final f = find.text(text).last;
  await t.ensureVisible(f);
  await t.pumpAndSettle();
  await t.tap(f);
  await t.pumpAndSettle();
}

Future<void> type(WidgetTester t, String label, String value) async {
  final field = find.descendant(of: find.ancestor(of: find.text(label), matching: find.byType(Column)).first, matching: find.byType(TextField));
  await t.ensureVisible(field.first);
  await t.enterText(field.first, value);
  await t.pump();
}

Future<void> choose(WidgetTester t, String fieldText, String option) async {
  await tap(t, fieldText);
  await tap(t, option);
}

Future<void> dashboard(WidgetTester t, FakeSetup api, {void Function(BuildContext)? onFinished}) =>
    show(t, SetupDashboardScreen(api: api, initial: api.state, onFinished: onFinished ?? (_) {}));

void main() {
  group('SetupApi', () {
    test('reads state with the session token and surfaces the server message on failure', () async {
      final seen = <String>[];
      final client = MockClient((r) async {
        seen.add('${r.method} ${r.url.path} ${r.headers['Authorization']}');
        const json = {'content-type': 'application/json'};
        if (r.url.path == '/rpc/partner_setup_save_tax') return http.Response(jsonEncode({'detail': 'GSTIN looks wrong.'}), 400, headers: json);
        return http.Response(jsonEncode(sampleSetup().raw), 200, headers: json);
      });
      final api = SetupApi(client: client, baseUrl: 'http://api.test/', accessToken: () => 'tok');
      final s = await api.get();
      expect(s.businessName, 'Sharma General Store');
      expect(seen.single, 'POST /rpc/partner_setup_get Bearer tok');
      await expectLater(api.saveTax({'gst_registered': true}), throwsA(isA<PartnerApiException>().having((e) => e.message, 'message', 'GSTIN looks wrong.')));
    });
    test('no session, no call', () async {
      final api = SetupApi(client: MockClient((_) async => fail('must not call')), baseUrl: 'http://x', accessToken: () => null);
      await expectLater(api.get(), throwsA(isA<PartnerApiException>().having((e) => e.status, 'status', 401)));
    });
    test('state helpers', () {
      final s = sampleSetup(posRequired: false);
      expect(s.total, 7);
      expect(setupSequence(s), isNot(contains('pos')));
      expect(stepDone(s, 'plan'), isTrue);
      expect(stepDone(s, 'payment'), isFalse);
    });
  });

  group('Dashboard (frame 17)', () {
    testWidgets('shows the checklist with completed, pending and optional items', (t) async {
      await dashboard(t, FakeSetup());
      expect(find.text('Set up your business'), findsOneWidget);
      expect(find.text('4 of 8 required tasks complete'), findsOneWidget);
      expect(find.text('Completed'), findsNWidgets(4));
      expect(find.text('Pending'), findsNWidgets(4));
      expect(find.text('Optional'), findsWidgets);
      expect(find.text('When applicable'), findsOneWidget);
      expect(find.text('Continue Setup'), findsOneWidget);
    });
    testWidgets('first visit shows coach mark 1 of 10; Next records it and hides it', (t) async {
      final api = FakeSetup(initial: sampleSetup(seen: const []));
      await dashboard(t, api);
      expect(find.text('Your setup checklist'), findsOneWidget);
      expect(find.text('1 of 10'), findsOneWidget);
      await tap(t, 'Next');
      expect(find.text('Your setup checklist'), findsNothing);
      expect(api.calls, contains('tour 1'));
    });
    testWidgets('a coach mark already read is not shown again', (t) async {
      await dashboard(t, FakeSetup(initial: sampleSetup(seen: const [1])));
      expect(find.text('1 of 10'), findsNothing);
    });
    testWidgets('Continue Setup opens the first required step not done (payment)', (t) async {
      await dashboard(t, FakeSetup());
      await tap(t, 'Continue Setup');
      expect(find.text('Payment Setup'), findsWidgets);
      expect(find.text('Settlement bank account'), findsOneWidget);
    });
    testWidgets('onboarding rows say they came from the approved application', (t) async {
      await dashboard(t, FakeSetup());
      await tap(t, 'Business Profile');
      expect(toast('Completed in your approved application.'), findsOneWidget);
    });
    testWidgets('OneLocal-only sellers have no POS row', (t) async {
      await dashboard(t, FakeSetup(initial: sampleSetup(posRequired: false)));
      expect(find.text('POS Setup'), findsNothing);
      expect(find.text('4 of 7 required tasks complete'), findsOneWidget);
    });
    testWidgets('with every required item done, Continue completes setup and shows frame 26', (t) async {
      final api = FakeSetup(initial: sampleSetup(done: allDone));
      api.after = sampleSetup(done: allDone, completed: true);
      var finished = false;
      await dashboard(t, api, onFinished: (_) => finished = true);
      await tap(t, 'Continue Setup');
      expect(api.calls, contains('complete'));
      expect(find.text('Your business is ready!'), findsOneWidget);
      expect(find.text('8 of 8 required tasks complete'), findsOneWidget);
      await tap(t, 'Go to Partner Home');
      expect(finished, isTrue);
    });
    testWidgets('a refused completion shows the server message and stays', (t) async {
      final api = FakeSetup(initial: sampleSetup(done: allDone))..failWith = const PartnerApiException(400, 'Finish "Catalogue" before you complete setup.');
      await dashboard(t, api);
      await tap(t, 'Continue Setup');
      expect(toast('Finish "Catalogue" before you complete setup.'), findsOneWidget);
      expect(find.text('Your business is ready!'), findsNothing);
    });
    testWidgets('Save & Continue walks to the next step', (t) async {
      final api = FakeSetup();
      await dashboard(t, api);
      await tap(t, 'Plan & Subscription');
      await tap(t, 'Continue');
      expect(api.calls, contains('plan starter'));
      expect(find.text('Settlement bank account'), findsOneWidget);   // payment is next
    });
  });

  group('Plan (frame 18)', () {
    testWidgets('shows plan, modules and limits; Continue confirms the plan', (t) async {
      final api = FakeSetup();
      await show(t, PlanScreen(api: api, state: api.state));
      expect(find.text('Current plan · Retail Starter'), findsOneWidget);
      expect(find.text('Monthly'), findsOneWidget);
      expect(find.text('Up to 2 staff'), findsOneWidget);
      expect(find.text('Your selection only. No subscription or charge starts here.'), findsOneWidget);
      await tap(t, 'Change Plan');
      expect(toast('This is the only plan available right now.'), findsOneWidget);
      await tap(t, 'Continue');
      expect(api.calls, ['plan starter']);
    });
    testWidgets('with no published plan it shows the selling choice and sends no code', (t) async {
      final api = FakeSetup(initial: sampleSetup(extra: {'plan': {'selected_code': null, 'available': [], 'sell_plan': 'pos_and_onelocal'}}));
      await show(t, PlanScreen(api: api, state: api.state));
      expect(find.text('Current plan · POS + OneLocal'), findsOneWidget);
      expect(find.text('Not set yet'), findsOneWidget);
      await tap(t, 'Continue');
      expect(api.calls, ['plan null']);
    });
    testWidgets('coach mark 2 of 10', (t) async {
      final api = FakeSetup(initial: sampleSetup(seen: const []));
      await show(t, PlanScreen(api: api, state: api.state));
      expect(find.text('Choose your plan'), findsOneWidget);
      expect(find.text('2 of 10'), findsOneWidget);
    });
  });

  group('Payment (frame 19)', () {
    testWidgets('UPI on needs an id; nothing is sent', (t) async {
      final api = FakeSetup();
      await show(t, PaymentScreen(api: api, state: api.state));
      await tap(t, 'UPI');
      await tap(t, 'Save & Continue');
      expect(toast('Enter your business UPI ID, or turn UPI off.'), findsOneWidget);
      expect(api.calls, isEmpty);
    });
    testWidgets('blank account number keeps the verified account; only methods and UPI are sent', (t) async {
      final api = FakeSetup();
      await show(t, PaymentScreen(api: api, state: api.state));
      expect(find.text('Using •••• •••• 6789 · verified by OneLocal'), findsOneWidget);
      await tap(t, 'UPI');
      await tap(t, 'Card');
      await type(t, 'UPI ID · if enabled', 'sharma@okhdfc');
      await tap(t, 'Save & Continue');
      expect(api.bodies['payment'], {'holder_name': 'Riya Sharma', 'accept_upi': true, 'accept_card': true, 'upi_id': 'sharma@okhdfc'});
    });
    testWidgets('a new account number goes with its IFSC', (t) async {
      final api = FakeSetup();
      await show(t, PaymentScreen(api: api, state: api.state));
      await type(t, 'Account number', '555566667777');
      await type(t, 'IFSC · if changing the account', 'hdfc0001234');
      await tap(t, 'Save & Continue');
      expect(api.bodies['payment']!['account_number'], '555566667777');
      expect(api.bodies['payment']!['ifsc'], 'HDFC0001234');
    });
  });

  group('Tax (frame 20)', () {
    testWidgets('GST registration must be answered, and registered needs a GSTIN', (t) async {
      final api = FakeSetup();
      await show(t, TaxScreen(api: api, state: api.state));
      await tap(t, 'Save & Continue');
      expect(toast('Tell us whether your business is GST-registered.'), findsOneWidget);
      await choose(t, 'Is your business GST-registered?', 'Registered · I have a GSTIN');
      await tap(t, 'Save & Continue');
      expect(toast('GSTIN looks wrong. It has 15 characters, like 27ABCDE1234F1Z5.'), findsOneWidget);
      expect(api.calls, isEmpty);
    });
    testWidgets('saves GST, prefix and receipt flags', (t) async {
      final api = FakeSetup();
      await show(t, TaxScreen(api: api, state: api.state));
      await choose(t, 'Is your business GST-registered?', 'Registered · I have a GSTIN');
      await type(t, 'GSTIN', '27abcde1234f1z5');
      await type(t, 'Invoice prefix', 'shr');
      await choose(t, 'Yes · tax-inclusive prices', 'No · tax added at billing');
      await tap(t, 'Show business address on receipts');
      await tap(t, 'Save & Continue');
      expect(api.bodies['tax'], {'gst_registered': true, 'gstin': '27ABCDE1234F1Z5', 'invoice_prefix': 'SHR', 'prices_include_tax': false,
        'show_address_on_receipt': false, 'show_gstin_on_invoice': true});
    });
  });

  group('POS (frame 21)', () {
    testWidgets('peripherals need a connection; a shop cannot tick a KOT printer', (t) async {
      final api = FakeSetup();
      await show(t, PosScreen(api: api, state: api.state));
      expect(find.text('Device not registered'), findsOneWidget);
      await type(t, 'POS device name', 'Counter 1');
      await tap(t, 'KOT printer');
      await tap(t, 'Receipt printer');
      await tap(t, 'Set Up Device');
      expect(toast('Choose Bluetooth, USB or network for your peripherals.'), findsOneWidget);
      await choose(t, 'Choose Bluetooth, USB or network', 'Bluetooth');
      await tap(t, 'Set Up Device');
      expect(api.bodies['pos'], {'device_name': 'Counter 1', 'peripherals': ['receipt_printer'], 'connection': 'bluetooth'});
    });
    testWidgets('Skip for Now sends nothing', (t) async {
      final api = FakeSetup();
      await dashboard(t, api);
      await tap(t, 'POS Setup');
      await tap(t, 'Skip for Now');
      expect(api.calls.where((c) => c == 'pos'), isEmpty);
    });
    testWidgets('a restaurant can tick a KOT printer', (t) async {
      final api = FakeSetup(initial: sampleSetup(type: 'restaurant'));
      await show(t, PosScreen(api: api, state: api.state));
      await type(t, 'POS device name', 'Kitchen pass');
      await tap(t, 'KOT printer');
      await choose(t, 'Choose Bluetooth, USB or network', 'USB');
      await tap(t, 'Set Up Device');
      expect(api.bodies['pos']!['peripherals'], ['kot_printer']);
    });
  });

  group('Staff (frame 22)', () {
    testWidgets('invite with role defaults; changing role resets permissions', (t) async {
      final api = FakeSetup();
      await show(t, StaffScreen(api: api, state: api.state));
      expect(find.text('Cashier permissions'), findsOneWidget);
      await type(t, 'Staff name', 'Ravi Kumar');
      await type(t, 'Email for the invite', 'ravi@example.com');
      await tap(t, 'Manage refunds');
      await tap(t, 'Add Staff');
      expect(api.bodies['staff'], {'name': 'Ravi Kumar', 'email': 'ravi@example.com', 'role': 'cashier', 'permissions': ['billing.collect', 'catalogue.view', 'refunds.manage']});
      expect(toast('Invite saved.'), findsOneWidget);
      await choose(t, 'Cashier', 'Manager');
      expect(find.text('Manager permissions'), findsOneWidget);
    });
    testWidgets('a bad email is caught before sending; shops have no kitchen role', (t) async {
      final api = FakeSetup();
      await show(t, StaffScreen(api: api, state: api.state));
      await type(t, 'Staff name', 'Ravi');
      await type(t, 'Email for the invite', 'ravi');
      await tap(t, 'Add Staff');
      expect(toast('Enter a valid email for the invite.'), findsOneWidget);
      await tap(t, 'Cashier');
      expect(find.text('Kitchen'), findsNothing);
      expect(api.calls, isEmpty);
    });
  });

  group('Catalogue (frame 23)', () {
    testWidgets('Add Items opens the sheet; the item goes to the server', (t) async {
      final api = FakeSetup();
      api.after = sampleSetup(done: {...api.state.checklist.where((r) => r['done'] == true).map((r) => r['key'] as String), 'catalogue'});
      await show(t, CatalogueScreen(api: api, state: api.state));
      expect(find.text('No items added yet'), findsOneWidget);
      await tap(t, 'Add Items');
      await type(t, 'Item name', 'Tata Salt 1kg');
      await type(t, 'Selling price (₹)', '0');
      await tap(t, 'Add item');
      expect(toast('Enter a selling price above zero.'), findsOneWidget);
      await type(t, 'Selling price (₹)', '28.50');
      await tap(t, 'Add item');
      expect(api.bodies['item'], {'name': 'Tata Salt 1kg', 'category': 'Staples', 'price': '28.50'});
      expect(find.text('2 items added'), findsOneWidget);
      expect(find.text('Continue'), findsOneWidget);
    });
  });

  group('Listing (frame 24)', () {
    testWidgets('needs a description and open days; saves hours as HH:MM', (t) async {
      final api = FakeSetup(initial: sampleSetup(extra: {'listing': {'saved': false, 'public_name': 'Sharma Store', 'description': 'Daily groceries', 'address_line': '12 Main Road, Latur',
        'open_days': [1, 2, 3], 'opens_at': '09:00', 'closes_at': '21:30'}}));
      await show(t, ListingScreen(api: api, state: api.state, picker: const FakePicker(null)));
      expect(find.text('Mon, Tue, Wed'), findsOneWidget);
      await tap(t, 'Save Listing');
      expect(api.bodies['listing'], {'public_name': 'Sharma Store', 'description': 'Daily groceries', 'address_line': '12 Main Road, Latur',
        'open_days': [1, 2, 3], 'opens_at': '09:00', 'closes_at': '21:30'});
    });
    testWidgets('missing description or days is caught before sending', (t) async {
      final api = FakeSetup();
      await show(t, ListingScreen(api: api, state: api.state, picker: const FakePicker(null)));
      await tap(t, 'Save Listing');
      expect(toast('Tell customers what you sell in 10 to 500 characters.'), findsOneWidget);
      await type(t, 'Description', 'Daily groceries and staples');
      await tap(t, 'Save Listing');
      expect(toast('Select the days you are open.'), findsOneWidget);
      expect(api.calls, isEmpty);
    });
    testWidgets('logo upload goes through the server; a PDF is refused', (t) async {
      final api = FakeSetup();
      await show(t, ListingScreen(api: api, state: api.state, picker: FakePicker(PickedDocument(name: 'logo.png', bytes: Uint8List.fromList([1, 2, 3]), contentType: 'image/png'))));
      await tap(t, 'Upload logo');
      expect(api.calls, ['image logo image/png']);
      await show(t, ListingScreen(api: api, state: api.state, picker: FakePicker(PickedDocument(name: 'a.pdf', bytes: Uint8List.fromList([1]), contentType: 'application/pdf'))));
      await tap(t, 'Upload cover');
      expect(toast('Upload a JPG or PNG.'), findsOneWidget);
    });
  });

  group('Delivery (frame 25)', () {
    testWidgets('at least one option; self-delivery shows its settings and needs a radius', (t) async {
      final api = FakeSetup();
      await show(t, FulfilmentScreen(api: api, state: api.state));
      expect(find.text('Self-delivery settings'), findsNothing);
      await tap(t, 'Customer pickup');
      await tap(t, 'Save & Continue');
      expect(toast('Choose at least one way customers get their orders.'), findsOneWidget);
      await tap(t, 'Self-delivery');
      expect(find.text('Self-delivery settings'), findsOneWidget);
      await tap(t, 'Save & Continue');
      expect(toast('Delivery radius must be 0.5 to 30 km.'), findsOneWidget);
      await type(t, 'Delivery radius (km)', '3');
      await type(t, 'Delivery areas · optional', 'Shivaji Nagar, Ausa Road, ');
      await type(t, 'Minimum order', '199');
      await tap(t, 'Save & Continue');
      expect(api.bodies['fulfilment'], {'pickup': false, 'self_delivery': true, 'onelocal_delivery': false, 'radius_km': '3',
        'service_areas': ['Shivaji Nagar', 'Ausa Road'], 'min_order': '199', 'delivery_fee': '', 'delivery_hours': 'same_as_opening'});
    });
    testWidgets('coach mark 9 of 10 is labelled optional', (t) async {
      final api = FakeSetup(initial: sampleSetup(seen: const []));
      await show(t, FulfilmentScreen(api: api, state: api.state));
      expect(find.text('BUSINESS SETUP · OPTIONAL'), findsOneWidget);
      expect(find.text('9 of 10'), findsOneWidget);
    });
  });

  group('Entry', () {
    testWidgets('loads from the server, and offers a retry when it cannot', (t) async {
      final api = FakeSetup()..failWith = const PartnerApiException(503, 'down');
      await show(t, SetupEntry(api: api, onFinished: (_) {}));
      await t.pumpAndSettle();
      expect(find.text('We could not load your setup.'), findsOneWidget);
      api.failWith = null;
      await tap(t, 'Try again');
      expect(find.text('Set up your business'), findsOneWidget);
    });
  });
}
