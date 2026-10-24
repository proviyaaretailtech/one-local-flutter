import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/settings/integrations_api.dart';
import 'package:vinii_pos/settings/integrations_screen.dart';
import 'package:vinii_pos/settings/settings_api.dart';
import 'package:vinii_pos/settings/settings_screen.dart';

import 'helpers.dart';

/// Settings -> Integrations (Petpooja, GoFrugal) against a fake server that behaves like db/migrations/pos_integrations.sql: every provider is
/// listed, keys never come back (only the last four characters), switches need a connection, a read-only person gets no account fields.
final Map<String, dynamic> fx = jsonDecode(File('test/fixtures/settings_server.json').readAsStringSync()) as Map<String, dynamic>;
const _json = {'content-type': 'application/json; charset=utf-8'};
http.Response ok(Object? body) => http.Response(jsonEncode(body), 200, headers: _json);
http.Response err(int status, String detail, [String? code]) => http.Response(jsonEncode({'detail': detail, 'code': ?code}), status, headers: _json);
String fnOf(http.Request r) => r.url.path.split('/').last;
Map<String, dynamic> argsOf(http.Request r) => r.body.isEmpty ? {} : jsonDecode(r.body) as Map<String, dynamic>;

class SavedRow {
  String status = 'disconnected';
  Map<String, dynamic> account = {};
  String? hint;
  bool menu = false, orders = false, stock = false;
  Map<String, dynamic>? check;
}

class Fake {
  Fake({this.canEdit = true, this.handler});
  bool canEdit;
  final http.Response? Function(http.Request r)? handler;
  final requests = <http.Request>[];
  final rows = {'petpooja': SavedRow(), 'gofrugal': SavedRow()};
  ({bool ok, String message}) nextCheck = (ok: true, message: 'Connected to Cafe A on Petpooja. 12 items on the menu.');

  List<http.Request> calls(String fn) => requests.where((r) => fnOf(r) == fn).toList();

  Map<String, dynamic> page([Map<String, dynamic>? extra]) => {
        'can_edit': canEdit,
        'integrations': [
          for (final e in rows.entries)
            {
              'provider': e.key,
              'status': e.value.status,
              'account': canEdit ? e.value.account : <String, dynamic>{},
              'key_hint': canEdit ? e.value.hint : null,
              'sync': {'menu': e.value.menu, 'orders': e.value.orders, 'stock': e.value.stock},
              'last_check': e.value.check,
              'connected_at': e.value.status == 'disconnected' ? null : '2026-10-23T10:00:00Z',
            },
        ],
        ...?extra,
      };

  late final client = MockClient((r) async {
    requests.add(r);
    final custom = handler?.call(r);
    if (custom != null) return custom;
    final a = argsOf(r);
    final row = rows[a['provider']];
    switch (fnOf(r)) {
      case 'pos_settings_get':
        return ok(fx['full']);
      case 'pos_integrations_get':
        return ok(page());
      case 'pos_integration_connect':
        row!
          ..status = 'connected'
          ..account = a['provider'] == 'petpooja' ? {'restaurant_id': a['restaurant_id']} : {'store_url': a['store_url'], 'outlet_id': ?a['outlet_id']}
          ..hint = (a['access_token'] ?? a['api_key'] as String).substring((a['access_token'] ?? a['api_key'] as String).length - 4)
          ..check = {'at': '2026-10-23T10:00:00Z', 'ok': true, 'message': nextCheck.message};
        return ok(page());
      case 'pos_integration_test':
        row!
          ..status = nextCheck.ok ? 'connected' : 'error'
          ..check = {'at': '2026-10-23T11:00:00Z', 'ok': nextCheck.ok, 'message': nextCheck.message};
        return ok(page({'check': {'provider': a['provider'], 'ok': nextCheck.ok, 'message': nextCheck.message}}));
      case 'pos_integration_set_sync':
        if (row!.status == 'disconnected') return err(409, 'Connect Petpooja first.', 'wrong_state');
        row
          ..menu = a['menu'] as bool? ?? row.menu
          ..orders = a['orders'] as bool? ?? row.orders
          ..stock = a['stock'] as bool? ?? row.stock;
        return ok(page());
      case 'pos_integration_disconnect':
        rows[a['provider'] as String] = SavedRow();
        return ok(page());
      default:
        return err(404, 'not found: ${fnOf(r)}');
    }
  });

  late final env = SettingsEnv(
    api: SettingsApi(client: client, baseUrl: 'http://pos.test', accessToken: () => 'token-123'),
    integrations: IntegrationsApi(client: client, baseUrl: 'http://pos.test', accessToken: () => 'token-123'),
  );

  void connected(String provider) {
    rows[provider]!
      ..status = 'connected'
      ..account = provider == 'petpooja' ? {'restaurant_id': 'r4512'} : {'store_url': 'http://store.example.com/WebReporter'}
      ..hint = '9876'
      ..check = {'at': '2026-10-23T10:00:00Z', 'ok': true, 'message': 'Connected to Cafe A on Petpooja.'};
  }
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 60));
  }
}

Future<void> openIntegrations(WidgetTester t, Fake f) async {
  await show(t, IntegrationsScreen(env: f.env));
  await settle(t);
}

Finder card(String provider) => find.byKey(ValueKey('integration-$provider'));
Finder inCard(String provider, Finder f) => find.descendant(of: card(provider), matching: f);
Finder field(String hint) => find.widgetWithText(TextField, hint).first;
Finder toast(String text) => find.descendant(of: find.byType(SnackBar), matching: find.text(text));

Future<void> tap(WidgetTester t, Finder f) async {
  await t.ensureVisible(f.first);
  await t.pump();
  await t.tap(f.first, warnIfMissed: false);
  await settle(t);
}

void main() {
  tearDown(HomeNav.reset);

  testWidgets('Settings has an Integrations row that opens the page; both providers start not connected', (t) async {
    final f = Fake();
    await show(t, SettingsScreen(env: f.env));
    await settle(t);
    final row = find.text('POS & billing software');
    await t.scrollUntilVisible(row, 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('Connect Petpooja or GoFrugal'), findsOneWidget);
    await tap(t, row);
    expect(find.text('Integrations'), findsWidgets);
    expect(inCard('petpooja', find.text('Not connected')), findsOneWidget);
    expect(inCard('gofrugal', find.text('Not connected')), findsOneWidget);
    expect(find.text('Connect Petpooja'), findsOneWidget);
    expect(find.text('Connect GoFrugal'), findsOneWidget);
    expect(find.text('WHAT TO SYNC'), findsNothing, reason: 'no switches before a connection');
    expect(f.calls('pos_integrations_get'), hasLength(1));
    expect(f.calls('pos_integrations_get').single.headers['Authorization'], 'Bearer token-123');
  });

  testWidgets('connect Petpooja: empty fields are named before any call; the four values go once; the page shows the key hint, never the keys', (t) async {
    final f = Fake();
    await openIntegrations(t, f);
    await tap(t, find.text('Connect Petpooja'));
    expect(find.text('Connect Petpooja'), findsWidgets); // the sheet title
    await tap(t, find.text('Check & connect'));
    expect(find.text('Enter the restaurant ID.'), findsOneWidget);
    expect(f.calls('pos_integration_connect'), isEmpty);

    await t.enterText(field('restID from Petpooja'), ' r4512 ');
    await t.enterText(field('Paste the app key'), 'appkey-1');
    await t.enterText(field('Paste the app secret'), 'secret-22');
    await tap(t, find.text('Check & connect'));
    expect(find.text('Enter the access token.'), findsOneWidget);
    await t.enterText(field('Paste the access token'), 'token-9876');
    await tap(t, find.text('Check & connect'));

    final sent = f.calls('pos_integration_connect');
    expect(sent, hasLength(1));
    expect(argsOf(sent.single), {'provider': 'petpooja', 'restaurant_id': 'r4512', 'app_key': 'appkey-1', 'app_secret': 'secret-22', 'access_token': 'token-9876'});
    expect(find.text('Check & connect'), findsNothing, reason: 'the sheet closed');
    expect(toast('Petpooja connected.'), findsOneWidget);
    expect(inCard('petpooja', find.text('Connected')), findsOneWidget);
    expect(inCard('petpooja', find.text('r4512')), findsOneWidget);
    expect(inCard('petpooja', find.text('•••• 9876')), findsOneWidget);
    expect(inCard('petpooja', find.text('Connected to Cafe A on Petpooja. 12 items on the menu.')), findsOneWidget);
    expect(inCard('petpooja', find.text('WHAT TO SYNC')), findsOneWidget);
    expect(find.textContaining('token-9876'), findsNothing);
    expect(find.textContaining('secret-22'), findsNothing);
  });

  testWidgets('the key fields hide what is typed', (t) async {
    final f = Fake();
    await openIntegrations(t, f);
    await tap(t, find.text('Connect Petpooja'));
    for (final hint in ['Paste the app key', 'Paste the app secret', 'Paste the access token']) {
      expect(t.widget<TextField>(field(hint)).obscureText, isTrue, reason: hint);
    }
    expect(t.widget<TextField>(field('restID from Petpooja')).obscureText, isFalse);
  });

  testWidgets('a refusal from the provider stays in the sheet with its sentence, and nothing is connected', (t) async {
    final f = Fake(handler: (r) => fnOf(r) == 'pos_integration_connect' ? err(422, 'Petpooja refused these details: Invalid restaurant id', 'integration_refused') : null);
    await openIntegrations(t, f);
    await tap(t, find.text('Connect Petpooja'));
    await t.enterText(field('restID from Petpooja'), 'r1');
    await t.enterText(field('Paste the app key'), 'appkey-1');
    await t.enterText(field('Paste the app secret'), 'secret-22');
    await t.enterText(field('Paste the access token'), 'token-9876');
    await tap(t, find.text('Check & connect'));
    expect(find.text('Petpooja refused these details: Invalid restaurant id'), findsOneWidget);
    expect(find.text('Check & connect'), findsOneWidget, reason: 'the sheet stays open with what was typed');
    expect(t.widget<TextField>(field('restID from Petpooja')).controller!.text, 'r1');
  });

  testWidgets('connect GoFrugal: store URL and API key; an empty outlet is not sent', (t) async {
    final f = Fake();
    await openIntegrations(t, f);
    await tap(t, find.text('Connect GoFrugal'));
    expect(find.textContaining('Ends in /WebReporter'), findsOneWidget);
    await t.enterText(field('http://yourstore.example.com/WebReporter'), 'store.example.com/WebReporter');
    await t.enterText(field('Paste the X-Auth-Token'), 'gk-abcd1111');
    await tap(t, find.text('Check & connect'));
    expect(argsOf(f.calls('pos_integration_connect').single), {'provider': 'gofrugal', 'store_url': 'store.example.com/WebReporter', 'api_key': 'gk-abcd1111'});
    expect(inCard('gofrugal', find.text('Connected')), findsOneWidget);
    expect(inCard('gofrugal', find.text('•••• 1111')), findsOneWidget);
    expect(inCard('petpooja', find.text('Not connected')), findsOneWidget);
  });

  testWidgets('a sync switch saves one choice for that provider and shows the answer', (t) async {
    final f = Fake()..connected('petpooja');
    await openIntegrations(t, f);
    expect(inCard('petpooja', find.text('Import categories, items and prices from Petpooja')), findsOneWidget);
    final menu = inCard('petpooja', find.byType(Switch)).first;
    expect(t.widget<Switch>(menu).value, isFalse);
    await tap(t, menu);
    expect(argsOf(f.calls('pos_integration_set_sync').single), {'provider': 'petpooja', 'menu': true});
    expect(t.widget<Switch>(inCard('petpooja', find.byType(Switch)).first).value, isTrue);
  });

  testWidgets('Test connection shows the provider\'s answer; a failed check marks the card "Needs attention"', (t) async {
    final f = Fake()..connected('petpooja');
    f.nextCheck = (ok: false, message: 'Petpooja refused these keys. Check the app key, app secret and access token.');
    await openIntegrations(t, f);
    await tap(t, inCard('petpooja', find.text('Test connection')));
    expect(argsOf(f.calls('pos_integration_test').single), {'provider': 'petpooja'});
    expect(toast('Petpooja refused these keys. Check the app key, app secret and access token.'), findsOneWidget);
    expect(inCard('petpooja', find.text('Needs attention')), findsOneWidget);
  });

  testWidgets('Update keys reopens the sheet with the saved restaurant ID and empty key fields', (t) async {
    final f = Fake()..connected('petpooja');
    await openIntegrations(t, f);
    await tap(t, inCard('petpooja', find.text('Update keys')));
    expect(find.text('Update Petpooja keys'), findsOneWidget);
    expect(t.widget<TextField>(field('restID from Petpooja')).controller!.text, 'r4512');
    expect(t.widget<TextField>(field('Paste the access token')).controller!.text, isEmpty);
    expect(find.text('Saved keys are never shown. Enter them again to replace them.'), findsOneWidget);
    expect(find.text('Check & save'), findsOneWidget);
  });

  testWidgets('Disconnect asks first; Cancel changes nothing, Disconnect deletes the connection', (t) async {
    final f = Fake()..connected('gofrugal');
    await openIntegrations(t, f);
    await tap(t, inCard('gofrugal', find.text('Disconnect')));
    expect(find.text('Disconnect GoFrugal?'), findsOneWidget);
    await tap(t, find.text('Cancel'));
    expect(f.calls('pos_integration_disconnect'), isEmpty);
    await tap(t, inCard('gofrugal', find.text('Disconnect')));
    await tap(t, find.byKey(const ValueKey('integration-disconnect-yes-gofrugal')));
    expect(argsOf(f.calls('pos_integration_disconnect').single), {'provider': 'gofrugal'});
    expect(toast('GoFrugal disconnected.'), findsOneWidget);
    expect(inCard('gofrugal', find.text('Not connected')), findsOneWidget);
    expect(inCard('gofrugal', find.text('WHAT TO SYNC')), findsNothing);
  });

  testWidgets('a person who may not change integrations sees status only: no buttons, no account fields, switches locked', (t) async {
    final f = Fake(canEdit: false)..connected('petpooja');
    await openIntegrations(t, f);
    expect(find.text('Only the owner or a manager can connect or change integrations.'), findsOneWidget);
    expect(inCard('petpooja', find.text('Connected')), findsOneWidget);
    for (final label in ['Connect Petpooja', 'Connect GoFrugal', 'Test connection', 'Update keys', 'Disconnect']) {
      expect(find.text(label), findsNothing, reason: label);
    }
    expect(find.text('r4512'), findsNothing);
    expect(find.textContaining('••••'), findsNothing);
    for (final s in t.widgetList<Switch>(inCard('petpooja', find.byType(Switch)))) {
      expect(s.onChanged, isNull);
    }
  });

  testWidgets('a server failure gets its own card, and Try again loads the page', (t) async {
    var fail = true;
    final f = Fake(handler: (r) => fail ? err(500, 'Something went wrong. Please try again.') : null);
    await openIntegrations(t, f);
    expect(find.text('Could not open Integrations'), findsOneWidget);
    fail = false;
    await tap(t, find.text('Try again'));
    expect(find.text('Connect Petpooja'), findsOneWidget);
  });

  testWidgets('no connection: the offline card', (t) async {
    final f = Fake(handler: (r) => throw http.ClientException('no route'));
    await openIntegrations(t, f);
    expect(find.text('You’re offline'), findsOneWidget);
    expect(find.text('Could not reach the server. Check your connection and try again.'), findsOneWidget);
  });

  test('IntegrationsState reads the page; an unknown provider is still drawn by its id', () {
    final s = IntegrationsState({
      'can_edit': true,
      'integrations': [
        {'provider': 'gofrugal', 'status': 'error', 'account': {'store_url': 'http://s/WebReporter', 'outlet_id': 'O1'}, 'key_hint': '1111', 'sync': {'stock': true}, 'last_check': {'at': '2026-10-23T10:00:00Z', 'ok': false, 'message': 'x'}},
        {'provider': 'tally', 'status': 'disconnected'},
      ],
      'check': {'ok': false, 'message': 'x'},
    });
    final g = s.of('gofrugal')!;
    expect([g.isConnected, g.needsAttention, g.storeUrl, g.outletId, g.keyHint, g.syncStock, g.syncMenu, g.lastCheckOk], [true, true, 'http://s/WebReporter', 'O1', '1111', true, false, false]);
    expect(g.lastCheckAt, isNotNull);
    expect(s.check, (ok: false, message: 'x'));
    expect(providerInfo('tally').name, 'tally');
    expect(s.of('tally')!.isConnected, isFalse);
    expect(IntegrationsState({}).integrations, isEmpty);
  });
}
