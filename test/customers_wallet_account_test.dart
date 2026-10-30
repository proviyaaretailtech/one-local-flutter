// Customer (and S5.5 on the bill), One Local Wallet and Manage account: screens against a fake /rpc server.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/settings/settings_api.dart';
import 'package:vinii_pos/account/account_api.dart';
import 'package:vinii_pos/account/delete_account_screen.dart' show cancelAccountDeletionOnSignIn;
import 'package:vinii_pos/account/account_screen.dart';
import 'package:vinii_pos/account/wallet_api.dart';
import 'package:vinii_pos/account/wallet_screen.dart';
import 'package:vinii_pos/customers/customer_picker.dart';
import 'package:vinii_pos/customers/customers_api.dart';
import 'package:vinii_pos/customers/customers_screen.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/home/side_nav.dart';
import 'package:vinii_pos/orders/cart_screen.dart';
import 'package:vinii_pos/orders/orders_api.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart' show ignoreOverflow;
import 'order_fixtures.dart';

const _json = {'content-type': 'application/json; charset=utf-8'};
http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: _json);
http.Response err(int status, String detail) => http.Response(jsonEncode({'detail': detail}), status, headers: _json);

/// A fake POS server: records each /rpc call (name, body) and answers from [answer].
class FakeRpc {
  FakeRpc(this.answer);
  final http.Response Function(String fn, Map<String, dynamic> body) answer;
  final calls = <(String, Map<String, dynamic>)>[];
  late final client = MockClient((r) async {
    final fn = r.url.pathSegments.last;
    final body = r.body.isEmpty ? <String, dynamic>{} : (jsonDecode(r.body) as Map).cast<String, dynamic>();
    calls.add((fn, body));
    return answer(fn, body);
  });
  late final customers = CustomersApi(baseUrl: 'http://pos.test', accessToken: () => 't', client: client);
  late final wallet = WalletApi(baseUrl: 'http://pos.test', accessToken: () => 't', client: client);
  late final account = AccountApi(baseUrl: 'http://pos.test', accessToken: () => 't', client: client);
  late final settings = SettingsApi(baseUrl: 'http://pos.test', accessToken: () => 't', client: client);
  Iterable<Map<String, dynamic>> bodies(String fn) => calls.where((c) => c.$1 == fn).map((c) => c.$2);
}

Map<String, dynamic> cust(String id, String name, {String phone = '••••••3210', int visits = 2, num spent = 540}) =>
    {'id': id, 'name': name, 'first_name': name.split(' ').first, 'last_name': '', 'phone': phone, 'email': null, 'visits': visits, 'spent': spent, 'last_visit': '2026-10-19T10:00:00Z'};

Map<String, dynamic> detail({bool full = false, bool manage = false}) => {
      ...cust('c1', 'Asha Rao', phone: full ? '9876543210' : '••••••3210'),
      'full_contact': full,
      'can_manage': manage,
      'gst_number': full ? '27ABCDE1234F1Z5' : null,
      'date_of_birth': full ? '1990-05-01' : null,
      'address': full ? 'MG Road, Latur' : '',
      'notes': 'Likes masala dosa',
      'preferred_dining': 'takeaway',
      'location_name': 'Latur Main',
      'wallet_balance': 150,
      'loyalty_points': 42,
      'orders': [
        {'id': 'o1', 'display_no': 'S-1001', 'channel': 'pickup', 'status': 'paid', 'total': 300, 'paid': true, 'created_at': '2026-10-19T10:00:00Z'},
      ],
    };

Future<void> show(WidgetTester t, Widget screen) async {
  ignoreOverflow();
  t.view.physicalSize = const Size(780, 3200);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(key: UniqueKey(), theme: posTheme(), home: screen));
  await t.pumpAndSettle();
}

class FakeAccountAuth implements AccountAuth {
  final calls = <String>[];
  @override
  Future<void> setDisplayName(String name) async => calls.add('name $name');
  @override
  Future<void> changeEmail(String email) async => calls.add('email $email');
  @override
  Future<void> changePhone(String e164) async => calls.add('phone $e164');
  @override
  Future<void> confirmPhone(String e164, String code) async => calls.add('confirm $e164 $code');
  @override
  Future<void> signOutEverywhere() async => calls.add('signOutEverywhere');

  /// When true, the first password change is answered "send a code first", like Supabase's secure password change.
  bool wantsCode = false;
  @override
  Future<void> setPassword(String password, {String? nonce}) async {
    if (wantsCode && nonce == null) throw const PasswordNeedsCode();
    calls.add('password $password${nonce == null ? '' : ' $nonce'}');
  }

  @override
  Future<void> reauthenticate() async => calls.add('reauthenticate');
}

Map<String, dynamic> wallet({bool owed = false, bool legacy = false}) => {
      'business': 'Satya Stores',
      'unsettled': {'due': 700, 'commission': 120, 'orders': 1, 'note': 'GST on commission is charged when the week is settled.'},
      'on_the_way': {'amount': 1000},
      'paid': {'amount': 500, 'failed_transfers': 0},
      'owed_to_onelocal': {'amount': owed ? 80 : 0},
      'settled_without_transfer_record': legacy ? 1 : 0,
      'movements': {
        'items': [
          {'kind': 'payout', 'id': 'p1', 'at': '2026-10-15T10:00:00Z', 'label': 'Paid to your bank', 'direction': 'out', 'amount': 500, 'status': 'paid', 'settlement_id': 's1', 'reference': 'UTR511', 'no_transfer_record': false},
          {'kind': 'settlement', 'id': 's2', 'at': '2026-10-13T10:00:00Z', 'label': 'Settlement 05 Oct – 11 Oct 2026', 'direction': 'in', 'amount': 1000, 'status': 'approved', 'settlement_id': 's2', 'reference': null, 'no_transfer_record': false},
        ],
        'total': 2,
        'next_offset': null,
      },
    };

Map<String, dynamic> quote() => {
      'subtotal': 640, 'gst_pct': 5, 'gst_amount': 32, 'service_charge': 0, 'discount': 0, 'round_off': 0, 'total': 672,
      'lines': [{'menu_item_id': 'm1', 'amount': 640}],
    };

void main() {
  setUp(HomeNav.reset);

  group('Customers', () {
    testWidgets('list: masked phones, search goes to the server, add a customer', (t) async {
      final s = FakeRpc((fn, b) => switch (fn) {
            'cust_list' => ok({'items': [cust('c1', 'Asha Rao')], 'total': 1, 'full_contact': false, 'can_manage': false, 'next_offset': null}),
            'cust_save' => ok({'customer_id': 'c2', 'created': true, 'duplicate': false, 'customer': cust('c2', 'Ravi K', visits: 0, spent: 0)}),
            _ => err(404, 'nope'),
          });
      await show(t, CustomersScreen(api: s.customers));
      expect(find.text('Asha Rao'), findsOneWidget);
      expect(find.text('••••••3210'), findsOneWidget);
      expect(find.text('Contact details hidden for your role'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('customer-search')), 'asha');
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      expect(s.bodies('cust_list').last, {'q': 'asha'});

      await t.tap(find.text('Add customer'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('cust-first')), 'Ravi');
      await t.enterText(find.byKey(const ValueKey('cust-last')), 'K');
      await t.enterText(find.byKey(const ValueKey('cust-phone')), '98765 43211');
      await t.tap(find.byKey(const ValueKey('cust-save')));
      await t.pumpAndSettle();
      final saved = s.bodies('cust_save').single;
      expect(saved['first_name'], 'Ravi');
      expect(saved['phone'], '9876543211', reason: 'the box keeps the 10 digits after +91');
      expect(saved.containsKey('id'), isFalse);
      expect(find.text('Customers'), findsOneWidget); // back on the list, which reloads
    });

    testWidgets('form refuses a missing name or short phone before calling the server', (t) async {
      final s = FakeRpc((fn, b) => ok({}));
      await show(t, CustomerFormScreen(api: s.customers));
      await t.enterText(find.byKey(const ValueKey('cust-first')), 'X');
      await t.enterText(find.byKey(const ValueKey('cust-phone')), '123');
      await t.tap(find.byKey(const ValueKey('cust-save')));
      await t.pump();
      expect(find.text('Enter the name and a 10-digit mobile number.'), findsOneWidget);
      expect(s.calls, isEmpty);
    });

    testWidgets('detail for a counter role: masked contact, no Edit, stats and bills', (t) async {
      final s = FakeRpc((fn, b) => ok(detail()));
      await show(t, CustomerDetailScreen(api: s.customers, id: 'c1'));
      expect(s.bodies('cust_view').single, {'id': 'c1'});
      expect(find.text('••••••3210'), findsOneWidget);
      expect(find.byKey(const ValueKey('customer-edit')), findsNothing);
      expect(find.text('Contact details, dates and address are shown to managers only.'), findsOneWidget);
      expect(find.text('S-1001'), findsOneWidget);
      expect(find.text('42'), findsOneWidget);
      expect(find.text('Takeaway'), findsOneWidget);
    });

    testWidgets('detail for a manager: full contact and Edit', (t) async {
      final s = FakeRpc((fn, b) => ok(detail(full: true, manage: true)));
      await show(t, CustomerDetailScreen(api: s.customers, id: 'c1'));
      expect(find.text('9876543210'), findsOneWidget);
      expect(find.text('27ABCDE1234F1Z5'), findsOneWidget);
      expect(find.byKey(const ValueKey('customer-edit')), findsOneWidget);
    });

    testWidgets('a refusal is shown with a retry, nothing invented', (t) async {
      final s = FakeRpc((fn, b) => err(403, 'Your role cannot look up customers.'));
      await show(t, CustomersScreen(api: s.customers));
      expect(find.text('Your role cannot look up customers.'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });
  });

  group('S5.5 customer on the bill', () {
    testWidgets('picker: walk-in, or a full mobile number looked up across the business', (t) async {
      final s = FakeRpc((fn, b) => switch (fn) {
            'cust_list' => ok({'items': <Object>[], 'total': 0}),
            'cust_lookup' => ok({'found': true, 'customer': cust('c1', 'Asha Rao')}),
            _ => err(404, 'nope'),
          });
      CustomerChoice? picked;
      await show(t, Builder(builder: (c) => TextButton(onPressed: () async => picked = await showCustomerPicker(c, api: s.customers), child: const Text('open'))));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.text('Existing, walk-in or new customer.'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('pick-walk-in')));
      await t.pumpAndSettle();
      expect(picked!.walkIn, isTrue);

      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('pick-search')), '9876543210');
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      expect(s.bodies('cust_lookup').single, {'phone': '9876543210'});
      await t.tap(find.text('Asha Rao'));
      await t.pumpAndSettle();
      expect(picked!.customer!.id, 'c1');
    });

    testWidgets('cart: choose a customer, pay, and the bill is linked to them', (t) async {
      final orders = <http.Request>[];
      final ordersApi = OrdersApi(
        baseUrl: 'http://pos.test',
        accessToken: () => 't',
        client: MockClient((r) async {
          orders.add(r);
          return r.url.path.endsWith('/quote') ? ok(quote()) : ok(view('pending'));
        }),
      );
      final s = FakeRpc((fn, b) => switch (fn) {
            'cust_list' => ok({'items': [cust('c1', 'Asha Rao')], 'total': 1}),
            'cust_attach_order' => ok({'order_id': b['order_id'], 'customer_id': 'c1', 'walk_in': false, 'replayed': false}),
            _ => err(404, 'nope'),
          });
      await show(t, CartScreen(api: ordersApi, customersApi: s.customers, initialLines: [CartLine(menuItemId: 'm1', name: 'Amul Butter 500g', qty: 2)]));
      expect(find.textContaining('Customer: Guest'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('cart-customer')));
      await t.pumpAndSettle();
      await t.tap(find.text('Asha Rao'));
      await t.pumpAndSettle();
      expect(find.textContaining('Customer: Asha Rao'), findsOneWidget);
      await t.tap(find.textContaining('Proceed to Checkout'));
      await t.pumpAndSettle();
      await t.tap(find.text('UPI / QR'));
      await t.pumpAndSettle();
      await t.tap(find.textContaining('Complete Payment'));
      await t.pumpAndSettle();
      expect(orders.where((r) => r.url.path.endsWith('/checkout')), hasLength(1));
      expect(s.bodies('cust_attach_order').single, {'order_id': orderId, 'customer_id': 'c1'});
      expect(find.text('Order Confirmation'), findsOneWidget);
    });

    testWidgets('cart: no customer chosen means no link call (a guest bill)', (t) async {
      final ordersApi = OrdersApi(baseUrl: 'http://pos.test', accessToken: () => 't',
          client: MockClient((r) async => r.url.path.endsWith('/quote') ? ok(quote()) : ok(view('pending'))));
      final s = FakeRpc((fn, b) => err(500, 'should not be called'));
      await show(t, CartScreen(api: ordersApi, customersApi: s.customers, initialLines: [CartLine(menuItemId: 'm1', name: 'Amul Butter 500g')]));
      await t.tap(find.textContaining('Proceed to Checkout'));
      await t.pumpAndSettle();
      await t.tap(find.text('UPI / QR'));
      await t.pumpAndSettle();
      await t.tap(find.textContaining('Complete Payment'));
      await t.pumpAndSettle();
      expect(s.calls, isEmpty);
    });
  });

  group('One Local Wallet', () {
    testWidgets('figures are the server\'s; movements open their settlement', (t) async {
      final s = FakeRpc((fn, b) => switch (fn) {
            'wallet_overview' => ok(wallet()),
            'wallet_settlement_view' => ok({
                'id': 's2', 'status': 'approved', 'period_start': '2026-10-05', 'period_end': '2026-10-11',
                'figures': {'food_due': 900, 'clawback': 0, 'commission': 100, 'commission_gst': 18, 'debt_in': 0, 'net': 782, 'debt_out': 0},
                'payouts': [{'status': 'pending', 'amount': 782, 'reference': null}],
                'lines': [{'display_no': 'OL-5111', 'payment_mode': 'online', 'gross': 1000, 'food_due': 900, 'commission': 100}],
              }),
            _ => err(404, 'nope'),
          });
      await show(t, WalletScreen(api: s.wallet));
      expect(find.text('₹1,000'), findsWidgets);
      expect(find.text('₹700'), findsOneWidget);
      expect(find.text('₹500'), findsOneWidget);
      expect(find.text('1 order · commission ₹120'), findsOneWidget);
      expect(find.text('₹1,700'), findsOneWidget); // available: not yet settled + on the way
      expect(find.byKey(const ValueKey('wallet-owed')), findsNothing);
      // Settlements first; the payout is under Withdrawals, and both are in the Ledger
      expect(find.textContaining('Paid · UTR511'), findsNothing);
      await t.ensureVisible(find.byKey(const ValueKey('wallet-tab-withdrawals')));
      await t.tap(find.byKey(const ValueKey('wallet-tab-withdrawals')));
      await t.pumpAndSettle();
      expect(find.textContaining('Paid · UTR511'), findsOneWidget);
      expect(find.text('Settlement 05 Oct – 11 Oct 2026'), findsNothing);
      await t.ensureVisible(find.byKey(const ValueKey('wallet-tab-ledger')));
      await t.tap(find.byKey(const ValueKey('wallet-tab-ledger')));
      await t.pumpAndSettle();
      expect(find.text('credit'), findsOneWidget);
      expect(find.text('debit'), findsOneWidget);
      await t.ensureVisible(find.byKey(const ValueKey('wallet-tab-settlements')));
      await t.tap(find.byKey(const ValueKey('wallet-tab-settlements')));
      await t.pumpAndSettle();
      await t.tap(find.text('Settlement 05 Oct – 11 Oct 2026'));
      await t.pumpAndSettle();
      expect(s.bodies('wallet_settlement_view').single, {'id': 's2'});
      expect(find.text('OL-5111'), findsOneWidget);
      expect(find.text('₹782'), findsWidgets);
    });

    testWidgets('Request withdrawal asks the One Local team for an early payout of what is available', (t) async {
      final s = FakeRpc((fn, b) => switch (fn) {
            'wallet_overview' => ok(wallet()),
            'pos_support_create' => ok({'reference': 'SR-0042'}),
            _ => err(404, 'nope'),
          });
      await show(t, WalletScreen(api: s.wallet, settings: s.settings));
      await t.tap(find.byKey(const ValueKey('wallet-withdraw')));
      await t.pumpAndSettle();
      expect(find.text('Available: ₹1,700'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('wallet-withdraw-note')), 'Need it for rent');
      await t.tap(find.byKey(const ValueKey('wallet-withdraw-send')));
      await t.pumpAndSettle();
      final b = s.bodies('pos_support_create').single;
      expect(b['topic'], 'account');
      expect(b['message'], allOf(contains('₹1,700'), contains('Satya Stores'), contains('Need it for rent')));
      expect(find.textContaining('SR-0042'), findsOneWidget);
    });

    testWidgets('the store name shows in full when it fits, as initials when it does not (on a phone)', (t) async {
      t.view.physicalSize = const Size(390 * 2, 844 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      var name = 'Sharma General Store';
      final s = FakeRpc((fn, b) => ok({...wallet(), 'business': name}));
      await t.pumpWidget(MaterialApp(theme: posTheme(), home: WalletScreen(api: s.wallet)));
      await t.pumpAndSettle();
      expect(t.widget<Text>(find.byKey(const ValueKey('wallet-business'))).data, 'Sharma General Store');
      name = 'Sharma General Store Wholesale and Retail Supermarket Mart';
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(MaterialApp(theme: posTheme(), home: WalletScreen(api: s.wallet)));
      await t.pumpAndSettle();
      expect(t.widget<Text>(find.byKey(const ValueKey('wallet-business'))).data, 'SGSWRSM');
    });

    testWidgets('debt to One Local and a settlement without a transfer record are said plainly', (t) async {
      final s = FakeRpc((fn, b) => ok(wallet(owed: true, legacy: true)));
      await show(t, WalletScreen(api: s.wallet));
      expect(find.byKey(const ValueKey('wallet-owed')), findsOneWidget);
      expect(find.byKey(const ValueKey('wallet-no-record')), findsOneWidget);
    });

    testWidgets('a role without access sees the server\'s reason', (t) async {
      final s = FakeRpc((fn, b) => err(403, 'Only the owner and finance roles can see the One Local Wallet.'));
      await show(t, WalletScreen(api: s.wallet));
      expect(find.text('Only the owner and finance roles can see the One Local Wallet.'), findsOneWidget);
    });
  });

  group('Manage account', () {
    Map<String, dynamic> acct() => {
          'name': 'Priya Sharma', 'email': 'priya@example.com', 'email_confirmed': true, 'pending_email': null, 'phone': '919876500512', 'phone_confirmed': true,
          'sign_in_methods': [
            {'method': 'password', 'label': 'Email and password', 'enabled': true},
            {'method': 'google', 'label': 'Google', 'enabled': false},
            {'method': 'partner_code', 'label': 'Partner code', 'enabled': true, 'code': 'OLP-••••1234', 'valid_until': '2026-11-01T00:00:00Z'},
          ],
          'devices': [
            {'id': 'd1', 'device': 'VINII Partner Android', 'last_active_at': '2026-10-19T10:00:00Z', 'this_device': true},
            {'id': 'd2', 'device': 'Chrome on Mac', 'last_active_at': '2026-10-18T10:00:00Z', 'this_device': false},
          ],
          'memberships': [
            {'organization': 'Satya Stores', 'role': 'org_owner', 'role_name': 'Owner', 'location': null, 'current': true},
          ],
        };

    testWidgets('profile, sign-in methods and devices; rename goes to the database and the login', (t) async {
      final auth = FakeAccountAuth();
      final s = FakeRpc((fn, b) => switch (fn) {
            'acct_get' => ok(acct()),
            _ => ok({}),
          });
      await show(t, ManageAccountScreen(api: s.account, auth: auth));
      expect(s.calls.first.$1, 'acct_sync_contact');
      expect(find.text('Priya Sharma'), findsNWidgets(2));   // the profile card and the Name row
      expect(find.text('+919876500512'), findsOneWidget);
      expect(find.text('Email and password'), findsOneWidget);
      expect(find.textContaining('OLP-••••1234'), findsOneWidget);
      expect(find.text('This device'), findsOneWidget);
      expect(find.text('Chrome on Mac'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('acct-edit-name')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('acct-ask')), 'Priya S');
      await t.tap(find.byKey(const ValueKey('acct-ask-ok')));
      await t.pumpAndSettle();
      expect(s.bodies('acct_save_name').single, {'name': 'Priya S'});
      expect(auth.calls, ['name Priya S']);
    });

    testWidgets('email change asks Supabase to confirm; a bad email is refused locally', (t) async {
      final auth = FakeAccountAuth();
      final s = FakeRpc((fn, b) => fn == 'acct_get' ? ok(acct()) : ok({}));
      await show(t, ManageAccountScreen(api: s.account, auth: auth));
      await t.tap(find.byKey(const ValueKey('acct-edit-email')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('acct-ask')), 'not-an-email');
      await t.tap(find.byKey(const ValueKey('acct-ask-ok')));
      await t.pumpAndSettle();
      expect(auth.calls, isEmpty);
      await t.tap(find.byKey(const ValueKey('acct-edit-email')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const ValueKey('acct-ask')), 'new@example.com');
      await t.tap(find.byKey(const ValueKey('acct-ask-ok')));
      await t.pumpAndSettle();
      expect(auth.calls, ['email new@example.com']);
    });

    testWidgets('no password yet: Set a password (checked here: 8+ characters, letters and numbers, typed twice the same)', (t) async {
      final auth = FakeAccountAuth();
      final noPassword = acct()..['sign_in_methods'] = [{'method': 'password', 'label': 'Email and password', 'enabled': false}];
      final s = FakeRpc((fn, b) => fn == 'acct_get' ? ok(noPassword) : ok({}));
      await show(t, ManageAccountScreen(api: s.account, auth: auth));
      expect(find.text('Set'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('acct-password')));
      await t.pumpAndSettle();
      expect(find.text('Set a password'), findsOneWidget);
      Future<void> tryPassword(String a, String b) async {
        await t.enterText(find.byKey(const ValueKey('acct-password-new')), a);
        await t.enterText(find.byKey(const ValueKey('acct-password-again')), b);
        await t.tap(find.byKey(const ValueKey('acct-password-save')));
        await t.pumpAndSettle();
      }

      await tryPassword('short1', 'short1');
      expect(find.text('Use at least 8 characters.'), findsOneWidget);
      await tryPassword('onlyletters', 'onlyletters');
      expect(find.text('Use letters and numbers.'), findsOneWidget);
      await tryPassword('Sharma2026', 'Sharma2025');
      expect(find.text('The two passwords are not the same.'), findsOneWidget);
      expect(auth.calls, isEmpty);
      await tryPassword('Sharma2026', 'Sharma2026');
      expect(auth.calls, ['password Sharma2026']);
      expect(find.text('Password set. You can now sign in with priya@example.com or +919876500512 and this password.'), findsOneWidget);
    });

    testWidgets('a password: Change; when the server wants proof, a code goes to the email and is asked for', (t) async {
      final auth = FakeAccountAuth()..wantsCode = true;
      final s = FakeRpc((fn, b) => fn == 'acct_get' ? ok(acct()) : ok({}));
      await show(t, ManageAccountScreen(api: s.account, auth: auth));
      await t.tap(find.byKey(const ValueKey('acct-password')));
      await t.pumpAndSettle();
      expect(find.text('Change password'), findsWidgets);
      await t.enterText(find.byKey(const ValueKey('acct-password-new')), 'NewPass99');
      await t.enterText(find.byKey(const ValueKey('acct-password-again')), 'NewPass99');
      await t.tap(find.byKey(const ValueKey('acct-password-save')));
      await t.pumpAndSettle();
      expect(auth.calls, ['reauthenticate']);
      expect(find.text('Code sent to priya@example.com'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('acct-ask')), '123456');
      await t.tap(find.byKey(const ValueKey('acct-ask-ok')));
      await t.pumpAndSettle();
      expect(auth.calls, ['reauthenticate', 'password NewPass99 123456']);
      expect(find.text('Password changed.'), findsOneWidget);
    });

    testWidgets('sign out of all devices: confirm, record, revoke, leave', (t) async {
      final auth = FakeAccountAuth();
      final s = FakeRpc((fn, b) => fn == 'acct_get' ? ok(acct()) : ok({'sessions': 2, 'recorded': true}));
      var left = 0;
      await show(t, ManageAccountScreen(api: s.account, auth: auth, onSignedOut: (_) => left++));
      await t.tap(find.byKey(const ValueKey('acct-signout-all')));
      await t.pumpAndSettle();
      expect(find.text('Sign out of all devices?'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('acct-signout-all-yes')));
      await t.pumpAndSettle();
      expect(s.calls.map((c) => c.$1), contains('acct_signed_out_everywhere'));
      expect(auth.calls, ['signOutEverywhere']);
      expect(left, 1);
    });

    Future<void> tapDown(WidgetTester t, String key) async {
      await t.ensureVisible(find.byKey(ValueKey(key)));
      await t.pumpAndSettle();
      await t.tap(find.byKey(ValueKey(key)));
      await t.pumpAndSettle();
    }

    testWidgets('Delete account: at the very end, apart; warnings, are you sure, type DELETE; then the request and every device signs out', (t) async {
      final auth = FakeAccountAuth();
      final s = FakeRpc((fn, b) => switch (fn) {
            'acct_get' => ok(acct()),
            'acct_delete_preview' => ok({'memberships': 1, 'sole_owner_of': ['Satya Stores'], 'pending': null}),
            'acct_delete_request' => ok({'reference': 'AD-261031-ABC123', 'due_at': '2026-11-30T10:00:00Z', 'replayed': false}),
            _ => ok({'sessions': 2, 'recorded': true}),
          });
      var left = 0;
      await show(t, ManageAccountScreen(api: s.account, auth: auth, onSignedOut: (_) => left++));
      // the last thing on the page, below Sign out of all devices
      expect(t.getTopLeft(find.byKey(const ValueKey('acct-danger'))).dy, greaterThan(t.getTopLeft(find.byKey(const ValueKey('acct-signout-all'))).dy));
      await tapDown(t, 'acct-delete');
      // warning one: what happens, and the business nobody else can run
      expect(find.textContaining('You are the only owner of Satya Stores'), findsOneWidget);
      expect(t.widget<FilledButton>(find.byKey(const ValueKey('del-continue'))).onPressed, isNull); // tick first
      await tapDown(t, 'del-understand');
      await tapDown(t, 'del-continue');
      // warning two
      expect(find.text('Are you really sure?'), findsOneWidget);
      await tapDown(t, 'del-sure-no');
      expect(find.byKey(const ValueKey('del-type')), findsNothing);
      await tapDown(t, 'del-continue');
      await tapDown(t, 'del-sure-yes');
      // warning three: the typed word, exactly
      FilledButton last() => t.widget<FilledButton>(find.byKey(const ValueKey('del-final')));
      expect(last().onPressed, isNull);
      await t.enterText(find.byKey(const ValueKey('del-confirm')), 'delete');
      await t.pump();
      expect(last().onPressed, isNull);
      await t.enterText(find.byKey(const ValueKey('del-confirm')), 'DELETE');
      await t.pump();
      expect(s.calls.map((c) => c.$1), isNot(contains('acct_delete_request'))); // nothing asked yet
      await tapDown(t, 'del-final');
      expect(s.bodies('acct_delete_request').single, {'confirm': 'DELETE'});
      expect(auth.calls, ['signOutEverywhere']);
      expect(left, 1);
    });

    testWidgets('Keep my account at any step: nothing is asked for', (t) async {
      final auth = FakeAccountAuth();
      final s = FakeRpc((fn, b) => switch (fn) {
            'acct_get' => ok(acct()),
            'acct_delete_preview' => ok({'memberships': 1, 'sole_owner_of': [], 'pending': null}),
            _ => ok({}),
          });
      await show(t, ManageAccountScreen(api: s.account, auth: auth));
      await tapDown(t, 'acct-delete');
      expect(find.textContaining('only owner'), findsNothing);
      await tapDown(t, 'del-keep');
      expect(find.byType(ManageAccountScreen), findsOneWidget);
      expect(s.calls.map((c) => c.$1), isNot(contains('acct_delete_request')));
      expect(auth.calls, isEmpty);
    });

    testWidgets('signing in again within 30 days cancels the deletion, and says so', (t) async {
      final s = FakeRpc((fn, b) => ok({'cancelled': fn == 'acct_delete_cancel', 'reference': 'AD-261031-ABC123'}));
      await show(t, Builder(builder: (c) => Scaffold(body: TextButton(onPressed: () => cancelAccountDeletionOnSignIn(c, s.account), child: const Text('signed in')))));
      await t.tap(find.text('signed in'));
      await t.pumpAndSettle();
      expect(s.calls.single.$1, 'acct_delete_cancel');
      expect(find.text('Welcome back. You signed in, so your account will not be deleted.'), findsOneWidget);
    });
  });

  group('Side nav', () {
    Future<int> soonCount(WidgetTester t) async {
      await show(t, Builder(builder: (c) => TextButton(onPressed: () => showStoreSideNav(c, name: 'Priya', onReports: () {}, onSignOut: () {}), child: const Text('menu'))));
      await t.tap(find.text('menu'));
      await t.pumpAndSettle();
      final n = find.text('Soon').evaluate().length;
      await t.tapAt(const Offset(385, 100)); // outside the panel closes it
      await t.pumpAndSettle();
      return n;
    }

    testWidgets('Customer, One Local Wallet and Manage account lose "Soon" and open their screens once plugged in', (t) async {
      final unplugged = await soonCount(t);
      final opened = <String>[];
      HomeNav.customers = (_) => opened.add('customers');
      HomeNav.wallet = (_) => opened.add('wallet');
      HomeNav.account = (_) => opened.add('account');
      expect(await soonCount(t), unplugged - 2);   // Manage account is the profile header now, not a "Soon" row
      for (final (label, hook) in [('Customer', 'customers'), ('One Local Wallet', 'wallet'), ('Manage account', 'account')]) {
        await t.tap(find.text('menu'));
        await t.pumpAndSettle();
        await t.tap(label == 'Manage account' ? find.bySemanticsLabel(label) : find.text(label));   // the account is the profile block
        await t.pumpAndSettle();
        expect(opened.last, hook);
        expect(find.byKey(const ValueKey('side-nav')), findsNothing);
      }
    });
  });
}
