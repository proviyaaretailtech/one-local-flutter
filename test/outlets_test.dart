import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/outlets/add_outlet_screen.dart';
import 'package:vinii_pos/outlets/outlet_header.dart';
import 'package:vinii_pos/outlets/outlet_status_screen.dart';
import 'package:vinii_pos/outlets/outlets_api.dart';

const _json = {'content-type': 'application/json; charset=utf-8'};
http.Response ok(Map<String, dynamic> j) => http.Response(jsonEncode(j), 200, headers: _json);

Map<String, dynamic> outlet(String id, String name, {String status = 'online', String verification = 'approved', bool accepting = true, bool rush = false, bool canToggle = true}) => {
      'id': id,
      'code': id == 'l1' ? 'MAIN' : 'OUT0${id.substring(1)}',
      'name': name,
      'locality': id == 'l1' ? 'Station Road' : 'Ausa Road',
      'verification': verification,
      'reference': verification == 'pending' ? 'OLO-1A2B3C4D' : null,
      'review_note': verification == 'rejected' ? 'Address could not be verified' : null,
      'accepting': accepting,
      'rush_mode': rush,
      'rush_extra_minutes': 15,
      'status': status,
      'status_label': switch (status) { 'online' => rush ? 'Online · Rush' : 'Online', 'offline' => 'Offline', 'paused' => 'Paused', 'pending' => 'Pending verification', _ => 'Rejected' },
      'delivery_label': accepting ? 'Receiving orders' : 'Not receiving orders',
      'can_toggle': canToggle,
      'toggle_note': canToggle ? null : 'Waiting for One Local to verify this outlet',
    };

Map<String, dynamic> overview({bool branchOn = false, bool withPending = true, bool canAdd = true}) {
  final outs = [
    outlet('l1', 'Niks Browni And Burger'),
    outlet('l2', 'Niks Ausa Road', status: branchOn ? 'online' : 'offline', accepting: branchOn),
    if (withPending) outlet('l3', 'Niks Barshi Road', status: 'pending', verification: 'pending', accepting: false, canToggle: false),
  ];
  return {
    'business': {'name': 'Niks', 'needs_fssai': true},
    'person': {'name': 'Nikhil Bansode'},
    'current': outs.first,
    'outlets': outs,
    'summary': {'chip': branchOn ? 'All online' : '1 of 2 online', 'pending': withPending ? 1 : 0},
    'can_add': canAdd,
  };
}

/// A fake gateway: answers outlet_list from [state], records every call and its Idempotency-Key.
class FakeOutlets {
  FakeOutlets({this.failSet});
  bool branchOn = false;
  bool added = false;
  final String? failSet;
  final calls = <(String, Map<String, dynamic>, String?)>[];
  late final api = OutletsApi(
    baseUrl: 'http://pos.test',
    accessToken: () => 'token-123',
    client: MockClient((r) async {
      final fn = r.url.pathSegments.last;
      final body = (jsonDecode(r.body) as Map).cast<String, dynamic>();
      calls.add((fn, body, r.headers['Idempotency-Key']));
      switch (fn) {
        case 'outlet_list':
          final o = overview(branchOn: branchOn);
          if (added) (o['outlets'] as List).add(outlet('l4', 'Niks Latur Highway', status: 'pending', verification: 'pending', accepting: false, canToggle: false));
          return ok(o);
        case 'outlet_set_channel':
          if (failSet != null) return http.Response(jsonEncode({'detail': failSet}), 409, headers: _json);
          if (body['accepting'] == true) branchOn = true;
          return ok({'outlet': outlet(body['location_id'] as String, 'x'), 'changed': true});
        case 'outlet_add':
          added = true;
          return ok({'outlet': outlet('l4', body['name'] as String, status: 'pending', verification: 'pending', accepting: false, canToggle: false), 'reference': 'OLO-9'});
      }
      return http.Response('{}', 404);
    }),
  );
}

Future<void> tall(WidgetTester t) async {
  t.view.physicalSize = const Size(430, 1400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

void main() {
  late FakeOutlets f;
  setUp(() {
    HomeNav.reset();
    f = FakeOutlets();
    OutletHeader.api = () => f.api;
    OutletHeader.refresh();
  });

  group('Outlet header', () {
    testWidgets('shows the outlet, its live status, the chip and the initials from the server', (t) async {
      await tall(t);
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: OutletHeader(title: 'Orders'))));
      expect(find.text('Orders'), findsOneWidget, reason: 'the screen title until the server answers');
      await t.pumpAndSettle();
      expect(find.text('Niks Browni And Burger'), findsOneWidget);
      expect(find.text('Online'), findsOneWidget);
      expect(find.text('1 of 2 online'), findsOneWidget);
      expect(find.text('NB'), findsOneWidget);
      expect(find.text('Orders'), findsNothing);
      expect(f.calls.single.$1, 'outlet_list');
    });

    testWidgets('a screen with its own outlet asks the server for that one', (t) async {
      await tall(t);
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: OutletHeader(title: 'Home', locationId: 'l2'))));
      await t.pumpAndSettle();
      expect(f.calls.single.$2['location_id'], 'l2');
    });

    testWidgets('when the server cannot answer it keeps the title and the initials the screen knows', (t) async {
      await tall(t);
      OutletHeader.api = () => OutletsApi(baseUrl: 'http://pos.test', accessToken: () => 't', client: MockClient((_) async => http.Response('{"detail":"down"}', 503)));
      OutletHeader.refresh();
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: OutletHeader(title: 'Stock', initials: 'RS'))));
      await t.pumpAndSettle();
      expect(find.text('Stock'), findsOneWidget);
      expect(find.text('RS'), findsOneWidget);
      expect(find.byKey(const ValueKey('outlet-header-chip')), findsNothing);
    });

    testWidgets('☰ runs the screen\'s menu; the chip opens Restaurant status', (t) async {
      await tall(t);
      var menu = 0;
      await t.pumpWidget(MaterialApp(home: Scaffold(body: OutletHeader(title: 'Orders', onMenu: () => menu++))));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('outlet-header-menu')));
      expect(menu, 1);
      await t.tap(find.byKey(const ValueKey('outlet-header-chip')));
      await t.pumpAndSettle();
      expect(find.text('Restaurant status'), findsOneWidget);
    });

    testWidgets('tapping the outlet name opens Restaurant status too, and the header reloads on return', (t) async {
      await tall(t);
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: OutletHeader(title: 'Orders'))));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('outlet-header-name')));
      await t.pumpAndSettle();
      expect(find.byType(OutletStatusScreen), findsOneWidget);
      final before = f.calls.length;
      await t.tap(find.byKey(const ValueKey('outlets-back')));
      await t.pumpAndSettle();
      expect(f.calls.length, greaterThan(before), reason: 'header reads again after Restaurant status closes');
    });
  });

  group('Restaurant status', () {
    Future<void> show(WidgetTester t, [FakeOutlets? x]) async {
      await tall(t);
      await t.pumpWidget(MaterialApp(home: OutletStatusScreen(api: (x ?? f).api)));
      await t.pumpAndSettle();
    }

    testWidgets('lists every outlet with ID, locality, status and the two switches', (t) async {
      await show(t);
      expect(find.text('Niks Browni And Burger'), findsOneWidget);
      expect(find.text('ID MAIN · Station Road'), findsOneWidget);
      expect(find.text('ID OUT02 · Ausa Road'), findsOneWidget);
      expect(find.text('Offline'), findsOneWidget);
      expect(find.text('Not receiving orders'), findsNWidgets(2), reason: 'the branch that is off and the pending outlet');
      expect(find.text('Delivery status'), findsNWidgets(3));
      expect(find.text('Rush mode'), findsNWidgets(3));
      expect(find.text('1 of 2 online'), findsOneWidget);
    });

    testWidgets('a pending outlet says so and its switches are disabled', (t) async {
      await show(t);
      expect(find.text('Pending verification'), findsOneWidget);
      expect(find.text('Waiting for One Local to verify this outlet (OLO-1A2B3C4D).'), findsOneWidget);
      final sw = t.widgetList<Switch>(find.descendant(of: find.byKey(const ValueKey('outlet-card-l3')), matching: find.byType(Switch)));
      expect(sw.length, 2);
      expect(sw.every((s) => s.onChanged == null), isTrue);
    });

    testWidgets('search narrows by name, ID or locality', (t) async {
      await show(t);
      await t.enterText(find.byKey(const ValueKey('outlets-search')), 'ausa');
      await t.pump();
      expect(find.text('Niks Ausa Road'), findsOneWidget);
      expect(find.text('Niks Browni And Burger'), findsNothing);
      await t.enterText(find.byKey(const ValueKey('outlets-search')), 'MAIN');
      await t.pump();
      expect(find.text('Niks Browni And Burger'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('outlets-search')), 'zzz');
      await t.pump();
      expect(find.text('No outlet matches “zzz”.'), findsOneWidget);
    });

    testWidgets('turning Delivery status on asks the server and redraws from its answer', (t) async {
      await show(t);
      await t.tap(find.descendant(of: find.byKey(const ValueKey('outlet-delivery-l2')), matching: find.byType(Switch)));
      await t.pumpAndSettle();
      final set = f.calls.firstWhere((c) => c.$1 == 'outlet_set_channel');
      expect(set.$2, {'location_id': 'l2', 'accepting': true});
      expect(find.text('All online'), findsOneWidget);
    });

    testWidgets('Rush mode sends only rush_mode', (t) async {
      await show(t);
      await t.tap(find.descendant(of: find.byKey(const ValueKey('outlet-rush-l1')), matching: find.byType(Switch)));
      await t.pumpAndSettle();
      expect(f.calls.firstWhere((c) => c.$1 == 'outlet_set_channel').$2, {'location_id': 'l1', 'rush_mode': true});
    });

    testWidgets('a refusal from the server is shown, nothing is assumed', (t) async {
      final x = FakeOutlets(failSet: 'Your role cannot change this outlet.');
      await show(t, x);
      await t.tap(find.descendant(of: find.byKey(const ValueKey('outlet-delivery-l2')), matching: find.byType(Switch)));
      await t.pumpAndSettle();
      expect(find.text('Your role cannot change this outlet.'), findsOneWidget);
      expect(find.text('Offline'), findsOneWidget);
    });

    testWidgets('the gear opens the outlet settings, or says it is not in this release', (t) async {
      await show(t);
      await t.tap(find.byKey(const ValueKey('outlet-gear-l1')));
      await t.pump();
      expect(find.text('Outlet settings opens in a later release.'), findsOneWidget);
    });

    testWidgets('Add another restaurant/store sends the form and shows the new outlet as pending', (t) async {
      await show(t);
      await t.ensureVisible(find.byKey(const ValueKey('outlets-add')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('outlets-add')));
      await t.pumpAndSettle();
      expect(find.byType(AddOutletScreen), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('outlet-name')), 'Niks Latur Highway');
      await t.enterText(find.byKey(const ValueKey('outlet-address')), '5 Latur Highway, near toll');
      await t.enterText(find.byKey(const ValueKey('outlet-pin')), '413512');
      await t.enterText(find.byKey(const ValueKey('outlet-lat')), '18.41');
      await t.enterText(find.byKey(const ValueKey('outlet-lng')), '76.57');
      await t.enterText(find.byKey(const ValueKey('outlet-fssai')), '12345678901234');
      await t.ensureVisible(find.byKey(const ValueKey('outlet-submit')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('outlet-submit')));
      await t.pumpAndSettle();
      final add = f.calls.firstWhere((c) => c.$1 == 'outlet_add');
      expect(add.$2['name'], 'Niks Latur Highway');
      expect(add.$2['hours'], {'opens': '09:00', 'closes': '23:00', 'days': ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun']});
      expect(add.$3, startsWith('outlet-'), reason: 'the form carries an Idempotency-Key');
      expect(find.byType(AddOutletScreen), findsNothing);
      expect(find.text('Niks Latur Highway'), findsOneWidget);
      expect(find.text('Pending verification'), findsNWidgets(2));
    });

    testWidgets('no add button for a person who may not add outlets', (t) async {
      final x = FakeOutlets();
      final api = OutletsApi(baseUrl: 'http://pos.test', accessToken: () => 't', client: MockClient((_) async => ok(overview(canAdd: false))));
      await tall(t);
      await t.pumpWidget(MaterialApp(home: OutletStatusScreen(api: api)));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('outlets-add')), findsNothing);
      expect(x.calls, isEmpty);
    });
  });

  group('Add outlet form', () {
    Future<void> show(WidgetTester t, {bool fssai = true, Locate? locate}) async {
      await tall(t);
      await t.pumpWidget(MaterialApp(home: AddOutletScreen(api: f.api, needsFssai: fssai, locate: locate)));
    }

    testWidgets('says what is missing before sending anything', (t) async {
      await show(t);
      await t.tap(find.byKey(const ValueKey('outlet-submit')));
      await t.pump();
      expect(find.text('Enter the outlet name.'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('outlet-name')), 'Niks Two');
      await t.enterText(find.byKey(const ValueKey('outlet-address')), '5 Latur Highway');
      await t.enterText(find.byKey(const ValueKey('outlet-pin')), '413512');
      await t.tap(find.byKey(const ValueKey('outlet-submit')));
      await t.pump();
      expect(find.text('Place the map pin on the outlet.'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('outlet-lat')), '18.4');
      await t.enterText(find.byKey(const ValueKey('outlet-lng')), '76.5');
      await t.tap(find.byKey(const ValueKey('outlet-submit')));
      await t.pump();
      expect(find.text('Enter the 14-digit FSSAI licence number.'), findsOneWidget);
      expect(f.calls, isEmpty);
    });

    testWidgets('a store does not need FSSAI; "use my location" fills the pin', (t) async {
      await show(t, fssai: false, locate: () async => (18.412345, 76.567891));
      expect(find.text('FSSAI licence number (optional)'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('outlet-pin-here')));
      await t.pumpAndSettle();
      expect(find.text('18.412345'), findsOneWidget);
      expect(find.text('76.567891'), findsOneWidget);
    });

    testWidgets('a day can be switched off and the server answer ends the form', (t) async {
      await show(t);
      await t.enterText(find.byKey(const ValueKey('outlet-name')), 'Niks Two');
      await t.enterText(find.byKey(const ValueKey('outlet-address')), '5 Latur Highway');
      await t.enterText(find.byKey(const ValueKey('outlet-pin')), '413512');
      await t.enterText(find.byKey(const ValueKey('outlet-lat')), '18.4');
      await t.enterText(find.byKey(const ValueKey('outlet-lng')), '76.5');
      await t.enterText(find.byKey(const ValueKey('outlet-fssai')), '12345678901234');
      await t.enterText(find.byKey(const ValueKey('outlet-gstin')), '27abcde1234f1z5');
      await t.ensureVisible(find.byKey(const ValueKey('outlet-day-sun')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('outlet-day-sun')));
      await t.pump();
      await t.ensureVisible(find.byKey(const ValueKey('outlet-submit')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('outlet-submit')));
      await t.pumpAndSettle();
      final add = f.calls.single;
      expect((add.$2['hours'] as Map)['days'], ['mon', 'tue', 'wed', 'thu', 'fri', 'sat']);
      expect(add.$2['gstin'], '27ABCDE1234F1Z5');
    });
  });
}
