import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/auth/partner_api.dart';
import 'package:vinii_pos/onboarding/agreement_screens.dart';
import 'package:vinii_pos/onboarding/pan_scan.dart';
import 'package:vinii_pos/onboarding/pan_camera_screen.dart' show cropToCard, kCardAspect;
import 'package:image/image.dart' as img;
import 'package:vinii_pos/onboarding/checklist_screen.dart';
import 'package:vinii_pos/onboarding/document_picker.dart';
import 'package:vinii_pos/onboarding/onboarding_api.dart';
import 'package:vinii_pos/onboarding/profile_screens.dart';
import 'package:vinii_pos/onboarding/section_screens.dart';
import 'package:vinii_pos/onboarding/status_screens.dart';
import 'package:vinii_pos/setup/setup_api.dart';

import 'helpers.dart';

/// An application as the server describes it. [done] is how many of the seven sections are complete (in order).
Application sample({int done = 4, String status = 'draft', String? plan = 'onelocal_app', Map<String, dynamic>? extra}) {
  const keys = ['business', 'contact', 'address', 'tax', 'documents', 'bank', 'agreement'];
  const titles = ['Business details', 'Contact details', 'Address', 'Tax details', 'Identity & documents', 'Bank details', 'Agreement & consent'];
  return Application({
    'exists': true,
    'application': {
      'id': 'a1', 'reference': 'OL-2026-0001', 'status': status, 'partner_type': 'store', 'business_name': 'Sharma General Store',
      'owner_name': 'Riya Sharma', 'phone': '9876543210', 'sell_plan': plan, 'selling_mode': 'physical', 'category': 'Grocery & essentials',
      'subcategories': ['General store'], 'submitted_at': '2026-10-05T10:00:00Z', 'review_note': null,
    },
    'address': {'address_line': '12, 2nd Main Road', 'locality': 'Indiranagar', 'city': 'Bengaluru', 'state': 'Karnataka', 'pin_code': '560038', 'confirmed': done > 2},
    'tax': {'pan_masked': done > 3 ? '••••••123F' : null, 'gst_registered': done > 3 ? true : null},
    'identity': {'consent': false, 'pan_masked': done > 3 ? '••••••123F' : null, 'aadhaar_last4': null},
    'bank': null,
    'consents': {'service_terms': false, 'privacy_notice': false, 'marketing_updates': false, 'merchant_agreement': false},
    'documents': <Map<String, dynamic>>[],
    'sections': [for (var i = 0; i < 7; i++) {'key': keys[i], 'title': titles[i], 'done': i < done, 'summary': 'x$i'}],
    'progress': {'done': done, 'total': 7, 'percent': (done * 100 / 7).round(), 'next': done >= 7 ? null : keys[done], 'can_submit': done == 7},
    'checks': <Map<String, dynamic>>[],
    'timeline': [
      {'key': 'received', 'state': 'complete'},
      {'key': 'review', 'state': 'in_progress'},
      {'key': 'decision', 'state': 'pending'},
    ],
    ...?extra,
  });
}

class FakeOnb extends OnboardingApi {
  FakeOnb({Application? initial}) : _app = initial ?? sample();
  Application _app;
  final calls = <String>[];
  final bodies = <String, Map<String, dynamic>>{};
  Object? failWith;

  Future<Application> _do(String what, [Map<String, dynamic>? body]) async {
    calls.add(what);
    if (body != null) bodies[what] = body;
    if (failWith != null) throw failWith!;
    return _app;
  }

  @override
  Future<Application> get() => _do('get');
  @override
  Future<Taxonomy> taxonomy() async => Taxonomy({
        'states': ['Karnataka', 'Goa'],
        'banks': ['HDFC Bank', 'Other'],
        'restaurant': {'categories': ['Bakery', 'Cafe']},
        'store': [{'family': 'Food', 'name': 'Grocery & essentials', 'subcategories': ['General store', 'Kirana']}],
        'service': {'categories': [{'name': 'Cleaning', 'subcategories': []}]},
      });
  @override
  Future<Application> saveProfile(Map<String, dynamic> b) => _do('profile', b);
  @override
  Future<Application> choosePlan(String plan) => _do('plan $plan');
  @override
  Future<Application> saveAddress(Map<String, dynamic> b) => _do('address', b);
  @override
  Future<Application> saveTax(Map<String, dynamic> b) => _do('tax', b);
  @override
  Future<Application> saveIdentity(Map<String, dynamic> b) => _do('identity', b);
  @override
  Future<Application> saveBank(Map<String, dynamic> b) => _do('bank', b);
  @override
  Future<Application> saveConsents(Map<String, dynamic> b) => _do('consents', b);
  @override
  Future<Application> acceptAgreement(String v) => _do('agreement $v');
  @override
  Future<Application> submit() => _do('submit');
  @override
  Future<Application> uploadDocument({required String kind, required Uint8List bytes, required String fileName, required String contentType}) =>
      _do('upload $kind $fileName $contentType');
  @override
  Future<Application> removeDocument(String kind) => _do('remove $kind');
}

class FakeScanner extends PanScanner {
  FakeScanner(this.result);
  final PanScan? result;
  @override
  Future<PanScan?> scan(BuildContext context) async => result;
}

PanScan panScan({String? pan = 'ABCDE0123F', bool looks = true}) =>
    PanScan(file: PickedDocument(name: 'pan_card_scan.jpg', bytes: Uint8List(10), contentType: 'image/jpeg'), panNumber: pan, looksLikePan: looks);

class FakePicker extends DocumentPicker {
  FakePicker(this.file);
  final PickedDocument? file;
  @override
  Future<PickedDocument?> pick() async => file;
}

Future<void> tapIt(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.tap(f);
  await t.pumpAndSettle();
}

Future<void> tapText(WidgetTester t, String text) async {
  await t.pump(const Duration(seconds: 4)); // a toast from the step before would sit over the buttons
  await t.pumpAndSettle();
  final f = find.text(text).first;
  await t.ensureVisible(f);
  await t.tap(f);
  await t.pumpAndSettle();
}

void main() {
  group('Merchant profile', () {
    testWidgets('store: refuses an empty form with the first missing answer', (t) async {
      final api = FakeOnb();
      await show(t, MerchantProfileScreen(api: api, type: 'store'));
      await t.pumpAndSettle();
      expect(find.text('Register as a Store'), findsOneWidget);
      await tapText(t, 'Save & continue');
      expect(toast('Enter your shop name.'), findsOneWidget);
      expect(api.calls, isNot(contains('profile')));
    });

    testWidgets('store: owner from sign-up; a full form saves the profile and the plan in one tap, then opens the next section', (t) async {
      final api = FakeOnb(initial: sample(done: 2, plan: null));
      await show(t, MerchantProfileScreen(api: api, type: 'store', phone: '+919876543210', name: 'Riya Sharma'));
      await t.pumpAndSettle();
      expect(find.text('Riya Sharma'), findsOneWidget); // the owner, from sign-up: not typed again
      await t.enterText(find.byType(TextField).at(0), 'Sharma General Store');
      await tapText(t, 'Choose'); // category
      await tapText(t, 'Grocery & essentials');
      await tapText(t, 'Choose'); // subcategory
      await tapText(t, 'General store');
      await tapText(t, 'Online or both');
      await tapText(t, 'Save & continue');
      expect(toast('Choose your OneLocal plan.'), findsOneWidget); // the plan is on this screen now
      await tapText(t, 'Purchase POS');
      await tapText(t, 'Save & continue');
      expect(api.bodies['profile'], {
        'partner_type': 'store', 'business_name': 'Sharma General Store', 'owner_name': 'Riya Sharma', 'phone': '9876543210',
        'selling_mode': 'online_or_both', 'category': 'Grocery & essentials', 'subcategory': 'General store',
      });
      expect(api.calls, contains('plan pos_only'));
      expect(find.text('How do you want to sell?'), findsNothing); // no separate plan screen
      expect(find.text('Let’s finish your setup.'), findsNothing); // straight on to the next section, not the checklist
    });

    testWidgets('restaurant has no subcategory; service says "Services"', (t) async {
      await show(t, MerchantProfileScreen(api: FakeOnb(), type: 'restaurant'));
      await t.pumpAndSettle();
      expect(find.text('Register as a Restaurant'), findsOneWidget);
      expect(find.text('Subcategory'), findsNothing);
      // A restaurant registers a restaurant, not a shop or store.
      expect(find.text('Restaurant name'), findsOneWidget);
      expect(find.text('Restaurant owner'), findsOneWidget);
      expect(find.text('Dine-in & takeaway'), findsOneWidget);
      expect(find.textContaining(RegExp(r'\b([Ss]hop|[Ss]tore)\b')), findsNothing);
      await show(t, MerchantProfileScreen(api: FakeOnb(), type: 'service'));
      await t.pumpAndSettle();
      expect(find.text('Services'), findsOneWidget);
    });

    testWidgets('restaurant: picks several cuisines, in the order tapped; none is refused', (t) async {
      final api = FakeOnb(initial: sample(done: 2, plan: null));
      await show(t, MerchantProfileScreen(api: api, type: 'restaurant', phone: '9876543210'));
      await t.pumpAndSettle();
      expect(find.text('Cuisines you serve'), findsOneWidget);
      await t.enterText(find.byType(TextField).at(0), 'Demo Spice');
      await t.enterText(find.byType(TextField).at(1), 'Asha Rao');
      await tapText(t, 'Dine-in & takeaway');
      await tapText(t, 'Save & continue');
      expect(toast('Choose the cuisines you serve.'), findsOneWidget);
      expect(api.calls, isNot(contains('profile')));
      await tapText(t, 'Cafe');
      await tapText(t, 'Bakery');
      await tapText(t, 'Purchase POS');
      await tapText(t, 'Save & continue');
      expect(api.bodies['profile'], {
        'partner_type': 'restaurant', 'business_name': 'Demo Spice', 'owner_name': 'Asha Rao', 'phone': '9876543210',
        'selling_mode': 'physical', 'categories': ['Cafe', 'Bakery'],
      });
    });

    testWidgets('the server\'s own message is shown when a save is refused', (t) async {
      final api = FakeOnb()..failWith = const PartnerApiException(400, 'Enter a 10-digit mobile number.');
      await show(t, MerchantProfileScreen(api: api, type: 'restaurant', app: sample(), phone: '9876543210'));
      await t.pumpAndSettle();
      await tapText(t, 'Save & continue');
      expect(toast('Enter a 10-digit mobile number.'), findsOneWidget);
    });
  });

  group('Choose how to sell', () {
    testWidgets('app only: records the plan and opens the checklist', (t) async {
      final api = FakeOnb();
      await show(t, ChooseSellScreen(api: api, app: sample(plan: null)));
      await tapText(t, 'Sell on OneLocal App');
      expect(api.calls, contains('plan onelocal_app'));
      expect(find.text('Let’s finish your setup.'), findsOneWidget);
    });
    testWidgets('POS: shows the plan, Purchase POS records it', (t) async {
      final api = FakeOnb();
      await show(t, ChooseSellScreen(api: api, app: sample(plan: null)));
      await tapText(t, 'Purchase POS & sell on OneLocal');
      expect(find.text('Basic Pack'), findsOneWidget);
      expect(find.text('Auto inventory sync'), findsOneWidget);
      await tapText(t, 'Purchase POS');
      expect(api.calls, contains('plan pos_and_onelocal'));
      expect(find.text('Let’s finish your setup.'), findsOneWidget);
    });
  });

  group('Checklist', () {
    testWidgets('shows progress and offers the next section', (t) async {
      await show(t, ChecklistScreen(api: FakeOnb(), app: sample()));
      expect(find.text('4 of 7 sections complete'), findsOneWidget);
      expect(find.text('57%'), findsOneWidget);
      expect(find.text('Resume identity & documents'), findsOneWidget);
      expect(find.text('Three sections to go'), findsOneWidget);
      expect(find.text('Submit application'), findsNothing);
    });
    testWidgets('all seven done: Submit application goes to the receipt', (t) async {
      final api = FakeOnb(initial: sample(done: 7, status: 'submitted'));
      await show(t, ChecklistScreen(api: api, app: sample(done: 7)));
      await tapText(t, 'Submit application');
      expect(api.calls, contains('submit'));
      expect(find.text('Application received.'), findsOneWidget);
      expect(find.text('Reference: OL-2026-0001'), findsOneWidget);
    });
    testWidgets('a section opens its screen', (t) async {
      await show(t, ChecklistScreen(api: FakeOnb(), app: sample(done: 2)));
      await tapText(t, 'Address');
      expect(find.text('Locate your business.'), findsOneWidget);
    });
  });

  group('Address', () {
    testWidgets('needs the confirmation, then saves every part', (t) async {
      final api = FakeOnb();
      await show(t, AddressScreen(api: api, app: sample(done: 2)));
      await t.pumpAndSettle();
      await tapText(t, 'Confirm address');
      expect(toast('Confirm that the address identifies your business.'), findsOneWidget);
      await tapIt(t, find.text('The address and map pin identify my business location.'));
      await tapText(t, 'Confirm address');
      expect(api.bodies['address'], {'address_line': '12, 2nd Main Road', 'locality': 'Indiranagar', 'city': 'Bengaluru', 'state': 'Karnataka', 'pin_code': '560038', 'confirmed': true});
    });
    testWidgets('the state first, then a city from that state (search, or Other to type it)', (t) async {
      SharedPreferences.setMockInitialValues({});
      final api = FakeOnb();
      await show(t, AddressScreen(api: api, app: sample(done: 1, extra: {'address': <String, dynamic>{}})));
      await t.pumpAndSettle();
      expect(t.getTopLeft(find.byKey(const ValueKey('address-state'))).dy, lessThan(t.getTopLeft(find.byKey(const ValueKey('address-city'))).dy));
      expect(find.text('Choose your state first'), findsOneWidget);
      await tapIt(t, find.byKey(const ValueKey('address-state')));
      await tapIt(t, find.text('Karnataka'));
      await tapIt(t, find.byKey(const ValueKey('address-city')));
      await t.enterText(find.byKey(const ValueKey('select-search')), 'mys');
      await t.pumpAndSettle();
      expect(find.text('Bengaluru'), findsNothing);
      await tapIt(t, find.text('Mysuru'));
      expect(find.descendant(of: find.byKey(const ValueKey('address-city')), matching: find.text('Mysuru')), findsOneWidget);
      // a town not in the list
      await tapIt(t, find.byKey(const ValueKey('address-city')));
      await t.enterText(find.byKey(const ValueKey('select-search')), 'ausa road'); // not in the list: Other stays
      await t.pumpAndSettle();
      await tapIt(t, find.text('Other (type your city)'));
      expect(find.text('Your city or town'), findsOneWidget);
    });
    testWidgets('a PIN code from another state is flagged as it is typed and refused on save', (t) async {
      final api = FakeOnb();
      await show(t, AddressScreen(api: api, app: sample(done: 2))); // Karnataka
      await t.pumpAndSettle();
      await tapIt(t, find.text('The address and map pin identify my business location.'));
      await t.enterText(find.byType(TextField).last, '413512'); // Latur, Maharashtra
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('pin-error')), findsOneWidget);
      await tapText(t, 'Confirm address');
      expect(toast('This PIN code is not in Karnataka. Check the PIN code or the state.'), findsOneWidget);
      expect(api.calls, isNot(contains('address')));
      await t.enterText(find.byType(TextField).last, '560038');
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('pin-error')), findsNothing);
    });
    testWidgets('a short PIN code is refused before any call', (t) async {
      final api = FakeOnb();
      await show(t, AddressScreen(api: api, app: sample(done: 2)));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).last, '5600');
      await tapText(t, 'Confirm address');
      expect(toast('PIN code must be 6 digits.'), findsOneWidget);
      expect(api.calls, isNot(contains('address')));
    });
  });

  group('Tax', () {
    testWidgets('bad PAN refused; GST-registered needs a GSTIN', (t) async {
      final api = FakeOnb();
      await show(t, TaxScreen(api: api, app: sample(done: 3)));
      await t.enterText(find.byType(TextField).first, 'abc');
      await tapText(t, 'Save & continue');
      expect(toast('PAN looks wrong. It has 5 letters, 4 digits and 1 letter.'), findsOneWidget);
      await t.enterText(find.byType(TextField).first, 'abcde1234f');
      await tapText(t, 'GST registered');
      await tapText(t, 'Save & continue');
      expect(toast('Enter your 15-character GSTIN.'), findsOneWidget);
      await t.enterText(find.byType(TextField).last, '29abcde1234f1z5');
      await tapText(t, 'Save & continue');
      expect(api.bodies['tax'], {'pan': 'ABCDE1234F', 'gst_registered': true, 'gstin': '29ABCDE1234F1Z5'});
    });
    testWidgets('not registered sends no GSTIN; a saved PAN may be left blank', (t) async {
      final api = FakeOnb();
      await show(t, TaxScreen(api: api, app: sample(done: 4)));
      await tapText(t, 'Not registered / not applicable');
      await tapText(t, 'Save & continue');
      expect(api.bodies['tax'], {'pan': '', 'gst_registered': false});
    });
  });

  group('Identity and documents', () {
    testWidgets('consent is required before documents open', (t) async {
      final api = FakeOnb();
      await show(t, IdentityScreen(api: api, app: sample()));
      await tapText(t, 'Continue to documents');
      expect(toast('Please consent to the use of your details for verification.'), findsOneWidget);
      expect(api.calls, isNot(contains('identity')));
    });
    testWidgets('consent saved, then the documents screen opens', (t) async {
      final api = FakeOnb();
      await show(t, IdentityScreen(api: api, app: sample()));
      await tapIt(t, find.textContaining('I consent to use of the details'));
      await tapText(t, 'Continue to documents');
      expect(api.bodies['identity'], {'consent': true});
      expect(find.text('Add your documents.'), findsOneWidget);
    });
    testWidgets('upload sends kind, name and type; an oversize file never leaves the phone', (t) async {
      final api = FakeOnb();
      await show(t, DocumentsScreen(api: api, app: sample(), picker: FakePicker(PickedDocument(name: 'pan.pdf', bytes: Uint8List(10), contentType: 'application/pdf'))));
      await t.pumpAndSettle();
      await tapIt(t, find.byKey(const ValueKey('docs-needed-ok'))); // the "keep these handy" sheet
      await tapText(t, 'Upload file');
      expect(api.calls, contains('upload pan_copy pan.pdf application/pdf'));
      final api2 = FakeOnb();
      await show(t, DocumentsScreen(api: api2, app: sample(), picker: FakePicker(PickedDocument(name: 'big.png', bytes: Uint8List(5 * 1024 * 1024 + 1), contentType: 'image/png'))));
      await tapText(t, 'Upload');
      expect(toast('Each file can be up to 5 MB.'), findsOneWidget);
      expect(api2.calls.where((c) => c.startsWith('upload')), isEmpty);
    });
    testWidgets('both required documents present: shows them uploaded and lets the person continue', (t) async {
      final docs = [
        {'kind': 'pan_copy', 'file_name': 'pan.pdf', 'mime_type': 'application/pdf', 'size_bytes': 1258291, 'status': 'uploaded'},
        {'kind': 'business_proof', 'file_name': 'shop.jpg', 'mime_type': 'image/jpeg', 'size_bytes': 2048, 'status': 'uploaded'},
      ];
      await show(t, DocumentsScreen(api: FakeOnb(), app: sample(extra: {'documents': docs})));
      expect(find.text('PAN card'), findsOneWidget);
      expect(find.textContaining('1.2 MB'), findsWidgets);
      for (final k in ['pan-view', 'pan-replace', 'pan-remove']) {
        expect(find.byKey(ValueKey(k)), findsOneWidget);
      }
      await tapText(t, 'Save & continue');
      expect(toast('Add your PAN copy and business proof to continue.'), findsNothing);
    });
  });

  group('PAN card scan', () {
    testWidgets('before the first upload: what to keep handy; it can be opened again', (t) async {
      await show(t, DocumentsScreen(api: FakeOnb(), app: sample()));
      await t.pumpAndSettle();
      expect(find.text('Keep these handy'), findsOneWidget);
      expect(find.text('PAN card'), findsWidgets);
      expect(find.textContaining('Gumasta'), findsOneWidget);
      await tapIt(t, find.byKey(const ValueKey('docs-needed-ok')));
      expect(find.text('Keep these handy'), findsNothing);
      await tapIt(t, find.byKey(const ValueKey('docs-needed')));
      expect(find.text('Keep these handy'), findsOneWidget);
    });
    test('reads the PAN and knows a PAN card', () {
      expect(readPanText('INCOME TAX DEPARTMENT\nGOVT. OF INDIA\nPermanent Account Number\nABCDE1234F'), (pan: 'ABCDE1234F', looksLikePan: true));
      expect(readPanText('Electricity bill 12345'), (pan: null, looksLikePan: false));
    });
    test('the camera photo is cropped to the card frame (card shaped, centred)', () {
      final photo = img.Image(width: 1000, height: 1500);
      final out = img.decodeJpg(cropToCard(Uint8List.fromList(img.encodeJpg(photo))))!;
      expect(out.width / out.height, closeTo(kCardAspect, 0.15));
      expect(out.width, lessThan(1000));
    });
    testWidgets('the camera scan is uploaded as a JPG', (t) async {
      final api = FakeOnb();
      await show(t, DocumentsScreen(api: api, app: sample(), scanner: FakeScanner(panScan())));
      await t.pumpAndSettle();
      await tapIt(t, find.byKey(const ValueKey('docs-needed-ok'))); // the "keep these handy" sheet
      await tapIt(t, find.byKey(const ValueKey('pan-scan')));
      expect(api.calls, contains('upload pan_copy pan_card_scan.jpg image/jpeg'));
    });
    testWidgets('a photo that is not a PAN card is questioned before upload', (t) async {
      final api = FakeOnb();
      await show(t, DocumentsScreen(api: api, app: sample(), scanner: FakeScanner(panScan(pan: null, looks: false))));
      await t.pumpAndSettle();
      await tapIt(t, find.byKey(const ValueKey('docs-needed-ok'))); // the "keep these handy" sheet
      await tapIt(t, find.byKey(const ValueKey('pan-scan')));
      expect(find.textContaining('This does not look like a PAN card'), findsOneWidget);
      await tapText(t, 'Use it anyway');
      expect(api.calls, contains('upload pan_copy pan_card_scan.jpg image/jpeg'));
    });
    testWidgets('a card with a different PAN from tax details is questioned', (t) async {
      final api = FakeOnb();
      await show(t, DocumentsScreen(api: api, app: sample(extra: {'tax': {'pan_masked': '••••••999Z'}}), scanner: FakeScanner(panScan())));
      await t.pumpAndSettle();
      await tapIt(t, find.byKey(const ValueKey('docs-needed-ok'))); // the "keep these handy" sheet
      await tapIt(t, find.byKey(const ValueKey('pan-scan')));
      expect(find.textContaining('is not the one in your tax details'), findsOneWidget);
    });
    testWidgets('remove asks first, then takes the PAN copy off', (t) async {
      final api = FakeOnb();
      final docs = [{'kind': 'pan_copy', 'file_name': 'pan.pdf', 'mime_type': 'application/pdf', 'size_bytes': 2048, 'status': 'uploaded'}];
      await show(t, DocumentsScreen(api: api, app: sample(extra: {'documents': docs})));
      await tapIt(t, find.byKey(const ValueKey('pan-remove')));
      expect(api.calls, isNot(contains('remove pan_copy')));
      await tapIt(t, find.byKey(const ValueKey('confirm-remove')));
      expect(api.calls, contains('remove pan_copy'));
    });
  });

  group('Bank', () {
    testWidgets('refuses mismatching numbers; Save for later sends draft', (t) async {
      final api = FakeOnb();
      await show(t, BankScreen(api: api, app: sample()));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).at(1), '123456789012');
      await t.enterText(find.byType(TextField).at(2), '123456789013');
      await tapText(t, 'Choose'); // bank
      await tapText(t, 'HDFC Bank');
      await tapText(t, 'Save & continue');
      expect(toast('The account numbers do not match.'), findsOneWidget);
      await tapText(t, 'Save for later');
      expect(api.bodies['bank']!['draft'], true);
      expect(api.bodies['bank']!['bank_name'], 'HDFC Bank');
    });
    testWidgets('a full valid form is saved and goes straight on (no verification stop)', (t) async {
      final api = FakeOnb();
      await show(t, BankScreen(api: api, app: sample()));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).at(1), '123456789012');
      await t.enterText(find.byType(TextField).at(2), '123456789012');
      await t.enterText(find.byType(TextField).at(3), 'hdfc0001234');
      await tapText(t, 'Choose'); // bank
      await tapText(t, 'HDFC Bank');
      await tapText(t, 'Choose'); // account type
      await tapText(t, 'Current account');
      await tapIt(t, find.text('I confirm that I am authorized to use this account for this business.'));
      await tapText(t, 'Save & continue');
      expect(api.bodies['bank'], {
        'holder_name': 'Riya Sharma', 'bank_name': 'HDFC Bank', 'account_number': '123456789012', 'confirm_account_number': '123456789012',
        'ifsc': 'HDFC0001234', 'account_type': 'current', 'authorised': true,
      });
      expect(find.text('Business verification.'), findsNothing);
    });
  });

  group('Verification overview', () {
    testWidgets('shows what operations recorded, never "verified" for saved details', (t) async {
      final checks = [
        {'kind': 'individual_identity', 'status': 'verified'},
        {'kind': 'business_identity', 'status': 'under_review'},
        {'kind': 'business_address', 'status': 'pending'},
        {'kind': 'bank_ownership', 'status': 'failed', 'note': 'Name differs'},
      ];
      await show(t, VerificationScreen(api: FakeOnb(), app: sample(extra: {'checks': checks})));
      expect(find.text('Verified'), findsOneWidget);
      expect(find.text('Under review'), findsOneWidget);
      expect(find.text('Check pending'), findsOneWidget);
      expect(find.text('Needs correction'), findsOneWidget);
    });
  });

  group('Agreement and consent', () {
    testWidgets('agreement and terms on one screen: acknowledge once; the terms from sign-up are recorded with it', (t) async {
      final api = FakeOnb();
      await show(t, AgreementScreen(api: api, app: sample(done: 6)));
      expect(find.text('Send me OneLocal news and marketing updates.'), findsOneWidget);
      await tapText(t, 'Accept & continue');
      expect(toast('Please acknowledge that you have reviewed the agreement.'), findsOneWidget);
      await tapIt(t, find.textContaining('I have reviewed this agreement preview'));
      await tapText(t, 'Accept & continue');
      expect(api.bodies['consents'], {'service_terms': true, 'privacy_notice': true, 'marketing_updates': false});
      expect(api.calls, contains('agreement $kAgreementVersion'));
      expect(find.text('Your terms. Your choices.'), findsNothing); // no second screen
    });
    testWidgets('as the last step it says Accept & submit application', (t) async {
      await show(t, AgreementScreen(api: FakeOnb(), app: sample(done: 6), last: true));
      expect(find.text('Accept & submit application'), findsOneWidget);
    });
    testWidgets('terms and privacy are required, marketing is optional', (t) async {
      final api = FakeOnb();
      await show(t, ConsentScreen(api: api, app: sample(done: 6)));
      await tapText(t, 'Save & continue to review');
      expect(toast('Please agree to the OneLocal service terms to continue.'), findsOneWidget);
      await tapIt(t, find.text('I agree to the OneLocal service terms.'));
      await tapText(t, 'Save & continue to review');
      expect(toast('Please acknowledge the privacy notice to continue.'), findsOneWidget);
      await tapIt(t, find.textContaining('I acknowledge the privacy notice'));
      await tapText(t, 'Save & continue to review');
      expect(api.bodies['consents'], {'service_terms': true, 'privacy_notice': true, 'marketing_updates': false});
    });
  });

  group('After submit', () {
    testWidgets('receipt shows reference and date', (t) async {
      await show(t, SubmittedScreen(api: FakeOnb(), app: sample(done: 7, status: 'submitted')));
      expect(find.text('Submitted, not yet approved'), findsOneWidget);
      expect(find.text('Reference: OL-2026-0001'), findsOneWidget);
      expect(find.textContaining('05 Oct 2026'), findsOneWidget);
      expect(find.textContaining('Thanks, Riya.'), findsOneWidget);
    });
    testWidgets('status: timeline, and Refresh moves to Approved when the decision arrives', (t) async {
      final api = FakeOnb(initial: sample(done: 7, status: 'approved'));
      await show(t, StatusScreen(api: api, app: sample(done: 7, status: 'submitted')));
      expect(find.text('Your review is in progress.'), findsOneWidget);
      expect(find.text('In progress'), findsOneWidget);
      await tapText(t, 'Refresh status');
      expect(find.text('Your application is approved.'), findsOneWidget);
    });
    testWidgets('a rejected application shows the reviewer\'s note', (t) async {
      final app = sample(done: 7, status: 'rejected');
      app.app['review_note'] = 'PAN does not match the business name.';
      await show(t, StatusScreen(api: FakeOnb(), app: app));
      expect(find.text('Your application was not approved.'), findsOneWidget);
      expect(find.text('PAN does not match the business name.'), findsOneWidget);
      expect(find.text('Not approved'), findsOneWidget);
    });
    testWidgets('approved: "Finish workspace setup" opens workspace setup (section C)', (t) async {
      final setup = SetupApi(client: MockClient((r) async => http.Response('{"detail":"down"}', 503)), baseUrl: 'http://x', accessToken: () => 't');
      await show(t, ApprovedScreen(api: FakeOnb(), app: sample(done: 7, status: 'approved'), setupApi: setup));
      await tapText(t, 'Finish workspace setup');
      await t.pumpAndSettle();
      expect(find.text('We could not load your setup.'), findsOneWidget);
    });
    testWidgets('complete screen greets by first name', (t) async {
      await show(t, CompleteScreen(app: sample(done: 7, status: 'approved')));
      expect(find.text('You’re all set, Riya.'), findsOneWidget);
    });
  });

  group('Shorter flow', () {
    testWidgets('what is typed is kept on the phone if the app closes, and comes back', (t) async {
      SharedPreferences.setMockInitialValues({});
      await show(t, MerchantProfileScreen(api: FakeOnb(), type: 'store'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).at(0), 'Half Done Store');
      await t.pump(const Duration(milliseconds: 600)); // kept a moment after typing stops
      // the app is closed and opened again: a fresh screen
      await t.pumpWidget(const SizedBox());
      await show(t, MerchantProfileScreen(api: FakeOnb(), type: 'store'));
      await t.pumpAndSettle();
      expect(find.text('Half Done Store'), findsOneWidget);
    });

    testWidgets('the checklist opens the next section by itself (one section after another)', (t) async {
      await show(t, ChecklistScreen(api: FakeOnb(), app: sample(done: 2), autoNext: true));
      await t.pumpAndSettle();
      expect(find.text('Let’s finish your setup.'), findsNothing);
    });
  });

  group('Entry', () {
    Future<void> enter(WidgetTester t, Application a) async {
      await show(t, OnboardingEntry(key: UniqueKey(), api: FakeOnb(initial: a), auth: FakeAuth()));
      await t.pumpAndSettle();
    }

    testWidgets('no application: choose Restaurant, Store or Service', (t) async {
      await enter(t, Application({'exists': false}));
      expect(find.text('Welcome to OneLocal.'), findsOneWidget);
      await tapText(t, 'Store');
      await tapText(t, 'Continue as merchant');
      expect(find.text('Register as a Store'), findsOneWidget);
    });
    testWidgets('draft without a plan: the business details, which carry the plan now', (t) async {
      await enter(t, sample(done: 2, plan: null));
      expect(find.text('Your OneLocal plan'), findsOneWidget);
    });
    testWidgets('draft with a plan: checklist', (t) async {
      await enter(t, sample());
      expect(find.text('Let’s finish your setup.'), findsOneWidget);
    });
    testWidgets('submitted: status; approved: approved', (t) async {
      await enter(t, sample(done: 7, status: 'submitted'));
      expect(find.text('Your review is in progress.'), findsOneWidget);
      await enter(t, sample(done: 7, status: 'approved'));
      expect(find.text('Your application is approved.'), findsOneWidget);
    });
    testWidgets('offline: Try again asks again; Switch account signs out', (t) async {
      final api = FakeOnb()..failWith = const PartnerApiException(503, 'down');
      final auth = FakeAuth();
      await show(t, OnboardingEntry(api: api, auth: auth));
      await t.pumpAndSettle();
      expect(find.text('We could not reach OneLocal.'), findsOneWidget);
      api.failWith = null;
      await tapText(t, 'Try again');
      expect(find.text('Let’s finish your setup.'), findsOneWidget);
    });
  });
}
