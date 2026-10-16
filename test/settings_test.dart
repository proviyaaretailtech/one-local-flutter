import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/app_routes.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/onboarding/document_picker.dart';
import 'package:vinii_pos/settings/settings_api.dart';
import 'package:vinii_pos/settings/settings_screen.dart';
import 'package:vinii_pos/settings/settings_widgets.dart' show SettingRow;
import 'package:vinii_pos/settings/support_screens.dart';

import 'helpers.dart';

/// Answers captured from the real local database (the functions of migration 0470): the app is built against what the server sends.
final Map<String, dynamic> fx = jsonDecode(File('test/fixtures/settings_server.json').readAsStringSync()) as Map<String, dynamic>;
const _json = {'content-type': 'application/json; charset=utf-8'};
http.Response ok(Object? body) => http.Response(jsonEncode(body), 200, headers: _json);
http.Response err(int status, String detail, [String? code]) => http.Response(jsonEncode({'detail': detail, 'code': ?code}), status, headers: _json);
String fnOf(http.Request r) => r.url.path.split('/').last;
Map<String, dynamic> argsOf(http.Request r) => r.body.isEmpty ? {} : jsonDecode(r.body) as Map<String, dynamic>;

Map<String, dynamic> readOnly() {
  final s = jsonDecode(jsonEncode(fx['full'])) as Map<String, dynamic>;
  s['can_edit'] = false;
  s['bank_visible'] = false;
  s['bank'] = null;
  return s;
}

const _help = {
  'hours': '9 AM–9 PM',
  'faq': [
    {'id': 'a', 'question': 'How do I accept a new order?', 'answer': 'Open Online orders and press Accept.'},
    {'id': 'b', 'question': 'When will my payout reach my bank?', 'answer': 'See Money > Settlements.'},
  ],
  'categories': [
    {'id': 'orders', 'title': 'Orders', 'hint': 'Accept, cancel or deliver', 'topic': 'orders'},
    {'id': 'payments', 'title': 'Payments', 'hint': 'Payments and bank payouts', 'topic': 'payments'},
  ],
};

/// A fake server: records every request, answers reads from the fixtures and a save with the `full` page.
class Fake {
  Fake([this.handler]);
  final http.Response? Function(http.Request r)? handler;
  final requests = <http.Request>[];
  Map<String, dynamic> page = fx['fresh'] as Map<String, dynamic>;
  final putBodies = <Uint8List>[];

  List<http.Request> calls(String fn) => requests.where((r) => fnOf(r) == fn).toList();

  late final api = SettingsApi(
    baseUrl: 'http://pos.test',
    accessToken: () => 'token-123',
    client: MockClient((r) async {
      requests.add(r);
      final custom = handler?.call(r);
      if (custom != null) return custom;
      if (r.method == 'PUT') {
        putBodies.add(r.bodyBytes);
        return http.Response('', 200);
      }
      switch (fnOf(r)) {
        case 'pos_settings_get':
          return ok(page);
        case 'pos_settings_file_slot':
          final a = argsOf(r);
          return ok({'path': 'org/${a['kind']}/f1.png', 'upload_url': 'http://storage.test/up/${a['kind']}', 'max_bytes': 5242880});
        case 'pos_settings_file_attach':
          return ok({'kind': argsOf(r)['kind'], 'id': 'doc-1'});
        case 'pos_settings_documents':
          return ok({'documents': _docs});
        case 'pos_settings_file_link':
          return ok({'url': 'http://storage.test/signed', 'expires_in': 300});
        case 'pos_help_content':
          return ok(_help);
        case 'pos_support_list':
          return ok(fx['support']);
        case 'pos_support_create':
          return ok({'id': 's2', 'reference': 'SUP-2001', 'status': 'open', 'replayed': false});
        case 'partner_setup_save_payment':
          return ok({'saved': true});
        case 'pos_settings_remove_qr' || 'pos_settings_document_remove':
          return ok({'removed': true});
        default:
          // every save answers with the new page (the database returns the whole page)
          if (fnOf(r).startsWith('pos_settings_')) return ok(fx['full']);
          return err(404, 'not found: ${fnOf(r)}');
      }
    }),
  );
}

List<Map<String, dynamic>> _docs = [];

class FakePicker extends DocumentPicker {
  FakePicker(this.file);
  final PickedDocument? file;
  int calls = 0;
  @override
  Future<PickedDocument?> pick() async {
    calls++;
    return file;
  }
}

final _png = PickedDocument(name: 'fssai.png', bytes: Uint8List.fromList([1, 2, 3, 4]), contentType: 'image/png');

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 60));
  }
}

/// Scrolls the page until [f] is built and on screen.
Future<void> see(WidgetTester t, Finder f) async {
  if (f.evaluate().isEmpty) await t.scrollUntilVisible(f, 300, scrollable: find.byType(Scrollable).first);
  await t.ensureVisible(f.first);
  await t.pump();
}

Future<void> tapText(WidgetTester t, String text, {bool last = false}) async {
  final f = last ? find.text(text).last : find.text(text).first;
  await see(t, find.text(text));
  await t.tap(f, warnIfMissed: false);
  await settle(t);
}

/// The Edit / Verify button inside the row titled [title].
Finder rowAction(String title, [String label = 'Edit']) =>
    find.descendant(of: find.ancestor(of: find.text(title), matching: find.byType(SettingRow)), matching: find.text(label));

Future<void> tapEdit(WidgetTester t, String title, [String label = 'Edit']) async {
  await see(t, find.text(title));
  await t.tap(rowAction(title, label));
  await settle(t);
}

Future<void> openSettings(WidgetTester t, Fake f, {SettingsEnv? env}) async {
  await show(t, SettingsScreen(env: env ?? SettingsEnv(api: f.api, picker: FakePicker(_png), pickTime: null)));
  await settle(t);
}

Finder field(String hint) => find.widgetWithText(TextField, hint).first;

void main() {
  setUp(() => _docs = []);
  tearDown(HomeNav.reset);

  group('Settings page', () {
    testWidgets('a business with nothing set sees "Not set" / "Not added" and the switches off, all from the server', (t) async {
      final f = Fake();
      await openSettings(t, f);
      expect(find.text('Opening: Not set · Closing: Not set'), findsOneWidget);
      expect(find.text('Delivery time / readiness'), findsOneWidget);
      expect(find.text('Not added'), findsNWidgets(4)); // help, owner, staff, location; the bank row says "Account ending"
      expect(find.text('Off · Accept orders for store pickup'), findsOneWidget);
      expect(find.text('Off · Let customers scan and pay'), findsOneWidget);
      expect(find.text('Account ending 4321 · Unverified'), findsOneWidget);
      expect(find.text('Bank details must match the Shop Act.'), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
      expect(find.text('Add users'), findsOneWidget);
      expect(f.calls('pos_settings_get'), hasLength(1));
      expect(f.requests.first.headers['Authorization'], 'Bearer token-123');
    });

    testWidgets('a saved business shows its times, readiness, contacts, address and an open QR switch', (t) async {
      final f = Fake()..page = fx['full'] as Map<String, dynamic>;
      await openSettings(t, f);
      expect(find.text('Opening: 9:00 AM · Closing: 10:30 PM'), findsOneWidget);
      expect(find.text('20 min'), findsOneWidget);
      expect(find.text('Asha · +91 9876543210'), findsOneWidget);
      expect(find.text('Rohan Shah · +91 9123456780'), findsOneWidget);
      expect(find.text('+91 9000011111'), findsOneWidget);
      expect(find.text('12 Station Road, Latur 413512'), findsOneWidget);
      expect(find.text('On · Let customers scan and pay'), findsOneWidget);
    });

    testWidgets('no number of any bank account is ever drawn: only the last four digits', (t) async {
      final f = Fake()..page = fx['full'] as Map<String, dynamic>;
      await openSettings(t, f);
      expect(find.textContaining('ending 4321'), findsOneWidget);
      expect(find.textContaining('deadbeef'), findsNothing);
      expect(jsonEncode(fx['full']), isNot(contains('account_enc')));
    });

    testWidgets('a person who may not edit sees the page read-only, no bank and no Edit buttons', (t) async {
      final f = Fake()..page = readOnly();
      await openSettings(t, f);
      expect(find.text('Only the owner or a manager can change these settings.'), findsOneWidget);
      expect(rowAction('Documents'), findsOneWidget); // Documents and Upload your QR open read-only views
      expect(rowAction('Upload your QR'), findsOneWidget);
      expect(rowAction('Opening & closing timings'), findsNothing);
      expect(find.text('Bank details'), findsNothing);
      expect(find.text('Verify'), findsNothing);
      final sw = t.widget<Switch>(find.byType(Switch).first);
      expect(sw.onChanged, isNull);
    });

    testWidgets('offline: shows the offline card, Try again loads the page', (t) async {
      var fail = true;
      final f = Fake((r) {
        if (fail) throw const SocketException('no route');
        return null;
      });
      await openSettings(t, f);
      expect(find.text('You’re offline'), findsOneWidget);
      fail = false;
      await tapText(t, 'Try again');
      expect(find.text('Opening & closing timings'), findsOneWidget);
    });

    testWidgets('the server refuses the page (403): its own sentence is shown, not "offline"', (t) async {
      final f = Fake((r) => err(403, 'Sign in to a business to continue.', 'forbidden'));
      await openSettings(t, f);
      expect(find.text('Could not open Settings'), findsOneWidget);
      expect(find.text('Sign in to a business to continue.'), findsOneWidget);
    });

    testWidgets('Add users goes to the Team section when it is plugged in, and says so when it is not', (t) async {
      final f = Fake();
      await openSettings(t, f);
      await tapText(t, 'Add users');
      expect(toast('Team opens in a later release.'), findsOneWidget);
      await t.pump(const Duration(seconds: 5));
      var team = 0;
      HomeNav.team = (_) => team++;
      await tapText(t, 'Add users');
      expect(team, 1);
    });

    testWidgets('Store Delivery opens the orders screens through the shared hook', (t) async {
      final f = Fake();
      var orders = 0;
      HomeNav.orders = (_) => orders++;
      await openSettings(t, f);
      await tapText(t, 'Store Delivery');
      expect(orders, 1);
    });
  });

  group('edit sheets', () {
    testWidgets('hours: pick both times, Save sends HH:MM and the page shows what the server answers', (t) async {
      final f = Fake();
      final times = ['09:00', '22:30'];
      await openSettings(t, f, env: SettingsEnv(api: f.api, pickTime: (c, cur) async => times.removeAt(0)));
      await tapEdit(t, 'Opening & closing timings');
      expect(find.text('Select opening time'), findsOneWidget);
      await tapText(t, 'Select opening time');
      await tapText(t, 'Select closing time');
      expect(find.text('9:00 AM'), findsOneWidget);
      expect(find.text('10:30 PM'), findsOneWidget);
      await tapText(t, 'Save');
      expect(argsOf(f.calls('pos_settings_save_hours').single), {'opens_at': '09:00', 'closes_at': '22:30'});
      expect(find.text('Opening: 9:00 AM · Closing: 10:30 PM'), findsOneWidget);
    });

    testWidgets('hours: Save with no times asks for them and sends nothing', (t) async {
      final f = Fake();
      await openSettings(t, f);
      await tapEdit(t, 'Opening & closing timings');
      await tapText(t, 'Save');
      expect(find.text('Choose both an opening and a closing time.'), findsOneWidget);
      expect(f.calls('pos_settings_save_hours'), isEmpty);
    });

    testWidgets('readiness: minutes go to the server as a number', (t) async {
      final f = Fake();
      await openSettings(t, f);
      await tapEdit(t, 'Delivery time / readiness');
      await t.enterText(field('Enter time in minutes'), '20');
      await tapText(t, 'Save');
      expect(argsOf(f.calls('pos_settings_save_readiness').single), {'prep_minutes': 20});
      expect(find.text('20 min'), findsOneWidget);
    });

    testWidgets('owner: the database sentence stays in the sheet when it refuses, and nothing is shown as saved', (t) async {
      final f = Fake((r) => fnOf(r) == 'pos_settings_save_owner' ? err(400, 'Enter a valid 10-digit owner mobile number.', 'bad_request') : null);
      await openSettings(t, f);
      await tapEdit(t, 'Owner');
      await t.enterText(field('Enter owner name'), 'Rohan Shah');
      await t.enterText(field('Enter mobile number'), '1234567890');
      await tapText(t, 'Save');
      expect(find.text('Enter a valid 10-digit owner mobile number.'), findsOneWidget);
      expect(find.text('Add the store owner’s contact details.'), findsOneWidget); // still open
      expect(argsOf(f.calls('pos_settings_save_owner').single), {'name': 'Rohan Shah', 'phone': '1234567890'});
    });

    testWidgets('help contact: name, number and instructions are sent; an empty contact is stopped on the phone', (t) async {
      final f = Fake();
      await openSettings(t, f);
      await tapEdit(t, 'Help / replacements');
      await tapText(t, 'Save');
      expect(find.text('Enter a contact name and a mobile number.'), findsOneWidget);
      expect(f.calls('pos_settings_save_help'), isEmpty);
      await t.enterText(field('Enter contact name'), 'Asha');
      await t.enterText(field('Enter mobile number'), '9876543210');
      await t.enterText(field('Enter help or replacement instructions'), 'Call first');
      await tapText(t, 'Save');
      expect(argsOf(f.calls('pos_settings_save_help').single), {'name': 'Asha', 'phone': '9876543210', 'info': 'Call first'});
    });

    testWidgets('staff number: digits only, ten at most', (t) async {
      final f = Fake();
      await openSettings(t, f);
      await tapEdit(t, 'Staff number');
      await t.enterText(field('Enter staff mobile number'), '90a00-011111999');
      await tapText(t, 'Save');
      expect(argsOf(f.calls('pos_settings_save_staff_phone').single), {'phone': '9000011111'});
    });

    testWidgets('location saves the address', (t) async {
      final f = Fake();
      await openSettings(t, f);
      await tapEdit(t, 'Location');
      await t.enterText(field('Enter full store address'), '12 Station Road, Latur 413512');
      await tapText(t, 'Save');
      expect(argsOf(f.calls('pos_settings_save_location').single), {'address': '12 Station Road, Latur 413512'});
    });

    testWidgets('language: choose one of the listed languages and save its code', (t) async {
      final f = Fake();
      await openSettings(t, f);
      await tapText(t, 'Language');
      expect(find.text('Choose App’s primary language'), findsOneWidget);
      await tapText(t, 'English', last: true);
      await tapText(t, 'हिन्दी (Hindi)');
      await tapText(t, 'Save');
      expect(argsOf(f.calls('pos_settings_save_language').single), {'language': 'hi'});
    });
  });

  group('switches', () {
    testWidgets('the switch on the page saves straight away', (t) async {
      final f = Fake();
      await openSettings(t, f);
      await see(t, find.byType(Switch));
      await t.tap(find.byType(Switch).first);
      await settle(t);
      expect(argsOf(f.calls('pos_settings_set_pickup').single), {'enabled': true});
    });

    testWidgets('a refusal (pickup is the only way to receive orders) keeps the switch where it was and shows the sentence', (t) async {
      final f = Fake((r) => fnOf(r) == 'pos_settings_set_pickup' ? err(400, 'Pickup is your only way to receive orders. Turn on delivery first, then switch pickup off.') : null)..page = {...(fx['full'] as Map<String, dynamic>), 'pickup': true};
      await openSettings(t, f);
      await see(t, find.byType(Switch));
      await t.tap(find.byType(Switch).first);
      await settle(t);
      expect(toast('Pickup is your only way to receive orders. Turn on delivery first, then switch pickup off.'), findsOneWidget);
      expect(t.widget<Switch>(find.byType(Switch).first).value, isTrue);
    });

    testWidgets('the pickup sheet shows Off, turning it on and Save sends enabled true', (t) async {
      final f = Fake();
      await openSettings(t, f);
      await tapText(t, 'Online self-pickup orders');
      expect(find.text('Accept pickup orders'), findsOneWidget);
      expect(find.text('Choose whether to accept store pickup orders.'), findsOneWidget);
      await t.tap(find.byType(Switch).last);
      await settle(t);
      await tapText(t, 'Save');
      expect(argsOf(f.calls('pos_settings_set_pickup').single), {'enabled': true});
    });

    testWidgets('the QR self-checkout sheet states what it does and saves', (t) async {
      final f = Fake();
      await openSettings(t, f);
      await tapText(t, 'QR self-checkout');
      expect(find.text('When enabled, customers can scan your store QR code to check out and pay themselves.'), findsOneWidget);
      await t.tap(find.byType(Switch).last);
      await settle(t);
      await tapText(t, 'Save');
      expect(argsOf(f.calls('pos_settings_set_qr_checkout').single), {'enabled': true});
    });
  });

  group('bank details', () {
    testWidgets('Verify saves holder, account number and IFSC through the secure handler, and the number is not kept on screen', (t) async {
      final f = Fake();
      await openSettings(t, f);
      await tapEdit(t, 'Bank details', 'Verify');
      expect(find.text('Add bank details for your store payouts.'), findsOneWidget);
      expect(find.text('Account ending 4321'), findsOneWidget);
      await t.enterText(field('Enter account number'), '123456789012');
      await tapText(t, 'Verify', last: true);
      final sent = argsOf(f.calls('partner_setup_save_payment').single);
      expect(sent, {'holder_name': 'Rohan Shah', 'account_number': '123456789012', 'ifsc': 'HDFC0001234'});
      expect(find.textContaining('123456789012'), findsNothing);
      expect(f.calls('pos_settings_get'), hasLength(2)); // the page is read again after the save
    });

    testWidgets('leaving the account number blank keeps the saved account (nothing sent for it)', (t) async {
      final f = Fake();
      await openSettings(t, f);
      await tapEdit(t, 'Bank details');
      expect(find.text('Saved account ending 4321. Leave blank to keep it.'), findsOneWidget);
      await tapText(t, 'Verify', last: true);
      expect(argsOf(f.calls('partner_setup_save_payment').single), {'holder_name': 'Rohan Shah', 'ifsc': 'HDFC0001234'});
    });

    testWidgets('an empty holder name is stopped on the phone and nothing is sent', (t) async {
      final f = Fake();
      await openSettings(t, f);
      await tapEdit(t, 'Bank details');
      await t.enterText(field('Enter name as per Shop Act'), '');
      await tapText(t, 'Verify', last: true);
      expect(find.text('Enter the account holder name.'), findsOneWidget);
      expect(f.calls('partner_setup_save_payment'), isEmpty);
    });
  });

  group('documents and QR', () {
    testWidgets('documents: empty state, then upload sends slot, bytes, attach in that order', (t) async {
      final f = Fake();
      await openSettings(t, f);
      await tapEdit(t, 'Documents');
      expect(find.text('No documents available'), findsOneWidget);
      await tapText(t, 'Upload document');
      expect(find.text('Document details'), findsOneWidget);
      expect((t.widget<TextField>(find.byType(TextField).first).controller!.text), 'fssai'); // name from the file name
      await tapText(t, 'Upload');
      final order = f.requests.map(fnOf).where((n) => n.startsWith('pos_settings_file') || n == 'up').toList();
      expect(order.take(2), ['pos_settings_file_slot', 'document'.isEmpty ? '' : order[1]]);
      expect(f.calls('pos_settings_file_slot').single.body, contains('"kind":"document"'));
      expect(f.putBodies.single, [1, 2, 3, 4]);
      final attach = argsOf(f.calls('pos_settings_file_attach').single);
      expect(attach['kind'], 'document');
      expect(attach['path'], 'org/document/f1.png');
      expect(attach['name'], 'fssai');
      expect(attach['doc_type'], 'other');
    });

    testWidgets('documents: the list shows the masked number and a Pending pill, never the full number', (t) async {
      _docs = [
        {'id': 'd1', 'name': 'FSSAI licence', 'doc_type': 'food_safety', 'doc_no_masked': 'XXXXXXXXXX0123', 'expiry_date': '2027-03-31', 'review_status': 'pending', 'has_file': true}
      ];
      final f = Fake();
      String? opened;
      await openSettings(t, f, env: SettingsEnv(api: f.api, picker: FakePicker(null), onOpenLink: (u) => opened = u));
      await tapEdit(t, 'Documents');
      expect(find.text('FSSAI licence'), findsOneWidget);
      expect(find.text('Food safety · XXXXXXXXXX0123 · Expires 2027-03-31'), findsOneWidget);
      expect(find.text('Pending'), findsOneWidget);
      await tapText(t, 'Open');
      expect(opened, 'http://storage.test/signed');
      await tapText(t, 'Remove');
      expect(argsOf(f.calls('pos_settings_document_remove').single), {'id': 'd1'});
    });

    testWidgets('documents: a person who cannot edit sees the list without Upload or Remove', (t) async {
      _docs = [
        {'id': 'd1', 'name': 'FSSAI licence', 'doc_type': 'food_safety', 'doc_no_masked': null, 'review_status': 'verified', 'has_file': false}
      ];
      final f = Fake()..page = readOnly();
      await openSettings(t, f);
      await tapEdit(t, 'Documents');
      expect(find.text('Verified'), findsOneWidget);
      expect(find.text('Upload document'), findsNothing);
      expect(find.text('Remove'), findsNothing);
    });

    testWidgets('documents: the server refusing the list (403) is shown with a Try again', (t) async {
      final f = Fake((r) => fnOf(r) == 'pos_settings_documents' ? err(403, 'Your role cannot see store documents.', 'forbidden') : null);
      await openSettings(t, f);
      await tapEdit(t, 'Documents');
      expect(find.text('Your role cannot see store documents.'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('QR: Upload sends the file as store_qr; once uploaded, Replace and Remove appear and Remove calls the server', (t) async {
      final f = Fake();
      await openSettings(t, f);
      await tapEdit(t, 'Upload your QR');
      expect(find.text('No QR uploaded'), findsOneWidget);
      expect(find.text('Supported formats: JPG / PNG / PDF'), findsOneWidget);
      f.page = {...(fx['full'] as Map<String, dynamic>), 'qr': {'uploaded': true}};
      await tapText(t, 'Upload');
      expect(f.calls('pos_settings_file_slot').single.body, contains('"kind":"store_qr"'));
      expect(find.text('QR uploaded'), findsWidgets);
      expect(find.text('Replace'), findsOneWidget);
      f.page = fx['full'] as Map<String, dynamic>;
      await tapText(t, 'Remove');
      expect(f.calls('pos_settings_remove_qr'), hasLength(1));
      expect(find.text('No QR uploaded'), findsOneWidget);
    });

    testWidgets('upload failing to reach the bucket says so and attaches nothing', (t) async {
      final f = Fake((r) => r.method == 'PUT' ? http.Response('nope', 500) : null);
      await openSettings(t, f);
      await tapEdit(t, 'Documents');
      await tapText(t, 'Upload document');
      await tapText(t, 'Upload');
      expect(toast('The upload did not finish. Please try again.'), findsOneWidget);
      expect(f.calls('pos_settings_file_attach'), isEmpty);
    });
  });

  group('Support & Help', () {
    Future<void> openSupport(WidgetTester t, Fake f) async {
      await show(t, SupportScreen(env: SettingsEnv(api: f.api, picker: FakePicker(_png), newKey: () => 'key-1234567890')));
      await settle(t);
    }

    testWidgets('shows search, FAQ, categories, hours, Contact Support and my requests from the server', (t) async {
      final f = Fake();
      await openSupport(t, f);
      expect(find.text('Search help articles…'), findsOneWidget);
      expect(find.text('How do I accept a new order?'), findsOneWidget);
      expect(find.text('Payments'), findsOneWidget);
      expect(find.text('Need a hand? Our team is here, 9 AM–9 PM.'), findsOneWidget);
      expect(find.text('Contact Support'), findsOneWidget);
      await see(t, find.textContaining('#SUP-2004'));
      expect(find.text('1 request'), findsOneWidget);
      expect(find.textContaining('#SUP-2004'), findsOneWidget);
      expect(find.text('Payout not received in my bank'), findsOneWidget);
      expect(find.text('Open'), findsOneWidget);
    });

    testWidgets('search narrows the FAQ and categories; an FAQ opens its answer', (t) async {
      final f = Fake();
      await openSupport(t, f);
      await t.enterText(find.byType(TextField).first, 'payout');
      await settle(t);
      expect(find.text('How do I accept a new order?'), findsNothing);
      expect(find.text('When will my payout reach my bank?'), findsOneWidget);
      await tapText(t, 'When will my payout reach my bank?');
      expect(find.text('See Money > Settlements.'), findsOneWidget);
    });

    testWidgets('Contact Support sends the topic and message once, with a key so a retry makes no second request', (t) async {
      final f = Fake();
      await openSupport(t, f);
      await tapText(t, 'Payments', last: false);
      expect(find.text('Contact Support'), findsWidgets);
      await tapText(t, 'Send');
      expect(find.text('Tell us a little more (at least 5 characters).'), findsOneWidget);
      expect(f.calls('pos_support_create'), isEmpty);
      await t.enterText(field('Describe the problem'), 'Payout not received');
      await tapText(t, 'Send');
      final call = f.calls('pos_support_create').single;
      expect(argsOf(call), {'kind': 'support', 'topic': 'payments', 'message': 'Payout not received'});
      expect(call.headers['Idempotency-Key'], 'key-1234567890');
      expect(toast('Request SUP-2001 sent.'), findsOneWidget);
      expect(f.calls('pos_support_list').length, 2); // the list is read again
    });

    testWidgets('feedback: text plus an optional screenshot; submit files a feedback request with the stored path', (t) async {
      final f = Fake();
      await show(t, Builder(builder: (c) => Scaffold(body: TextButton(onPressed: () => openFeedbackSheet(c, SettingsEnv(api: f.api, picker: FakePicker(_png), newKey: () => 'key-abcdef123456')), child: const Text('go')))));
      await t.tap(find.text('go'));
      await settle(t);
      expect(find.text('Tell us what you think'), findsOneWidget);
      await t.enterText(field('Share your thought'), 'Please add dark mode');
      await t.tap(find.byKey(const Key('feedback-attach')));
      await settle(t);
      await tapText(t, 'Submit');
      final sent = argsOf(f.calls('pos_support_create').single);
      expect(sent['kind'], 'feedback');
      expect(sent['message'], 'Please add dark mode');
      expect(f.calls('pos_settings_file_slot'), hasLength(1));
      expect(f.calls('pos_settings_file_slot').single.body, contains('"kind":"feedback"'));
      expect(sent['attachment_path'], 'org/feedback/f1.png');
      expect(toast('Thank you. Your feedback (SUP-2001) was sent.'), findsOneWidget);
    });

    testWidgets('offline: the offline card with Try again', (t) async {
      var fail = true;
      final f = Fake((r) {
        if (fail) throw const SocketException('no route');
        return null;
      });
      await openSupport(t, f);
      expect(find.text('You’re offline'), findsOneWidget);
      fail = false;
      await tapText(t, 'Try again');
      expect(find.text('Contact Support'), findsOneWidget);
    });
  });

  group('pieces', () {
    test('clock12 reads 24-hour times the way the frames do', () {
      expect(clock12('00:00'), '12:00 AM');
      expect(clock12('09:05'), '9:05 AM');
      expect(clock12('12:00'), '12:00 PM');
      expect(clock12('22:30'), '10:30 PM');
      expect(clock12(null), 'Not set');
    });

    test('installRoutes plugs the Settings page and Support & Help; Team stays for section L', () {
      HomeNav.reset();
      installRoutes();
      expect(HomeNav.settings, isNotNull);
      expect(HomeNav.support, isNotNull);
      expect(HomeNav.team, isNull);
    });

    test('SettingsState hides bank details from a person who may not see them', () {
      final s = SettingsState({...(fx['full'] as Map<String, dynamic>), 'bank_visible': false, 'bank': null});
      expect(s.bankStatus, isNull);
      expect(s.canEdit, isTrue);
    });
  });
}
