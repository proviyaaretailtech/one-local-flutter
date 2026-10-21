import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/outlets/add_outlet_screen.dart';
import 'package:vinii_pos/outlets/outlet_header.dart';
import 'package:vinii_pos/outlets/outlet_scope.dart';
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
  Map<String, dynamic>? draft;
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
          if (draft != null) o['draft'] = {'id': draft!['id'], 'name': draft!['name'], 'step': draft!['step']};
          if (added) (o['outlets'] as List).add(outlet('l4', 'Niks Latur Highway', status: 'pending', verification: 'pending', accepting: false, canToggle: false));
          return ok(o);
        case 'outlet_set_channel':
          if (failSet != null) return http.Response(jsonEncode({'detail': failSet}), 409, headers: _json);
          if (body['accepting'] == true) branchOn = true;
          return ok({'outlet': outlet(body['location_id'] as String, 'x'), 'changed': true});
        case 'outlet_draft_get':
          return ok({
            'draft': draft,
            'states': [
              {'code': '29', 'name': 'Karnataka'},
              {'code': '27', 'name': 'Maharashtra'},
            ],
            'home_state_code': '27',
            'home_state_name': 'Maharashtra',
            'needs_fssai': true,
          });
        case 'outlet_draft_save':
          final d = <String, dynamic>{...?draft, 'id': 'd1', 'status': 'draft'};
          for (final e in body.entries) {
            if (e.key == 'id' || e.key == 'idempotency_key') continue;
            d[e.key == 'step' ? 'step' : e.key] = e.value;
          }
          d['inter_state'] = d['state_code'] != null && d['state_code'] != '27';
          d['state_name'] = d['state_code'] == '29' ? 'Karnataka' : 'Maharashtra';
          d['missing'] = <String>[];
          draft = d;
          return ok({'draft': d, 'replayed': false});
        case 'outlet_draft_submit':
          added = true;
          final name = (draft?['name'] ?? 'x') as String;
          draft = null;
          return ok({'outlet': outlet('l4', name, status: 'pending', verification: 'pending', accepting: false, canToggle: false), 'reference': 'OLO-9'});
        case 'outlet_draft_discard':
          draft = null;
          return ok({'discarded': true});
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
    OutletScope.reset();
    f = FakeOutlets();
    OutletHeader.api = () => f.api;
    OutletHeader.refresh();
  });

  group('Outlet header', () {
    testWidgets('shows the outlet and its live status from the server', (t) async {
      await tall(t);
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: OutletHeader(title: 'Orders'))));
      expect(find.text('Orders'), findsOneWidget, reason: 'the screen title until the server answers');
      await t.pumpAndSettle();
      expect(find.text('Niks Browni And Burger'), findsOneWidget);
      expect(find.text('Online'), findsOneWidget);
      expect(find.text('NB'), findsNothing, reason: 'the shared banner has the bell and ☰ instead of initials');
      expect(find.text('Orders'), findsNothing);
      expect(f.calls.single.$1, 'outlet_list');
    });

    testWidgets('a screen with its own outlet asks the server for that one', (t) async {
      await tall(t);
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: OutletHeader(title: 'Home', locationId: 'l2'))));
      await t.pumpAndSettle();
      expect(f.calls.single.$2['location_id'], 'l2');
    });

    testWidgets('when the server cannot answer it keeps the title', (t) async {
      await tall(t);
      OutletHeader.api = () => OutletsApi(baseUrl: 'http://pos.test', accessToken: () => 't', client: MockClient((_) async => http.Response('{"detail":"down"}', 503)));
      OutletHeader.refresh();
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: OutletHeader(title: 'Stock', initials: 'RS'))));
      await t.pumpAndSettle();
      expect(find.text('Stock'), findsOneWidget);
      expect(find.text('RS'), findsNothing, reason: 'the shared banner has the bell and ☰ instead of initials');
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
      expect(find.text('Store status'), findsOneWidget); // a store's app says store, never restaurant
    });

    testWidgets('the outlet name opens the switcher; "Manage outlets" opens Restaurant status and the header reloads on return', (t) async {
      await tall(t);
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: OutletHeader(title: 'Orders'))));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('outlet-header-name')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('outlet-pick-manage')));
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

    testWidgets('a store says store: title, search, rush mode and "Add another store" never mention a restaurant or kitchen', (t) async {
      await show(t);
      expect(find.text('Store status'), findsOneWidget);
      expect(find.text('Add another store'), findsOneWidget);
      expect(find.textContaining('estaurant'), findsNothing);
      expect(find.textContaining('kitchen'), findsNothing);
      expect(find.textContaining('packing time'), findsWidgets);
    });

    test('the place word follows the kind of business', () {
      expect(outletNoun('restaurant'), 'restaurant');
      expect(outletNounTitle('restaurant'), 'Restaurant');
      expect(outletNoun('store'), 'store');
      expect(outletNoun(), 'store'); // outside the shell: never assume a restaurant
    });

    testWidgets('lists every outlet with ID, locality, status and the two switches', (t) async {
      await show(t);
      expect(find.text('Niks Browni And Burger'), findsOneWidget);
      expect(find.text('ID MAIN · Station Road'), findsOneWidget);
      expect(find.text('ID OUT02 · Ausa Road'), findsOneWidget);
      expect(find.text('Offline'), findsOneWidget);
      expect(find.text('Not receiving orders'), findsNWidgets(2), reason: 'the branch that is off and the pending outlet');
      expect(find.text('Delivery status'), findsNWidgets(3));
      expect(find.text('Rush mode'), findsNWidgets(3));
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

  group('Add another restaurant/store (stepped, saved as a draft)', () {
    Future<void> openForm(WidgetTester t, FakeOutlets x) async {
      await tall(t);
      await t.pumpWidget(MaterialApp(home: OutletStatusScreen(api: x.api)));
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const ValueKey('outlets-add')));
      await t.tap(find.byKey(const ValueKey('outlets-add')));
      await t.pumpAndSettle();
    }

    Future<void> chooseState(WidgetTester t, String name) async {
      await t.tap(find.byKey(const ValueKey('outlet-state')));
      await t.pumpAndSettle();
      await t.tap(find.text(name).last);
      await t.pumpAndSettle();
    }

    Future<void> next(WidgetTester t) async {
      await t.ensureVisible(find.byKey(const ValueKey('outlet-submit')));
      await t.tap(find.byKey(const ValueKey('outlet-submit')));
      await t.pumpAndSettle();
    }

    Future<void> details(WidgetTester t, String name) async {
      await t.enterText(find.byKey(const ValueKey('outlet-name')), name);
      await t.enterText(find.byKey(const ValueKey('outlet-address')), '5 Latur Highway, near toll');
      await t.enterText(find.byKey(const ValueKey('outlet-locality')), 'Highway');
      await t.enterText(find.byKey(const ValueKey('outlet-pin')), '413512');
      await t.enterText(find.byKey(const ValueKey('outlet-lat')), '18.41');
      await t.enterText(find.byKey(const ValueKey('outlet-lng')), '76.57');
    }

    List<Map<String, dynamic>> saves(FakeOutlets x) => [for (final c in x.calls) if (c.$1 == 'outlet_draft_save') c.$2];

    testWidgets('same state: four steps, the business GSTIN is used, the outlet is sent as pending', (t) async {
      await openForm(t, f);
      expect(find.text('Step 1 of 4 · Where is the new outlet?'), findsOneWidget);
      expect(find.text('Your business GSTIN is registered in Maharashtra.'), findsOneWidget);
      await next(t);
      expect(find.text('Choose the state the outlet is in.'), findsOneWidget, reason: 'nothing is sent before a state is chosen');
      expect(saves(f), isEmpty);
      await chooseState(t, 'Maharashtra');
      expect(find.textContaining('Same state: your business GSTIN is used'), findsOneWidget);
      await next(t);
      expect(saves(f).single, {'state_code': '27', 'step': 'details'});
      expect(f.calls.firstWhere((c) => c.$1 == 'outlet_draft_save').$3, startsWith('outlet-'), reason: 'a new draft carries an Idempotency-Key');
      await details(t, 'Niks Latur Highway');
      await next(t);
      expect(saves(f).last['step'], 'tax');
      expect(saves(f).last['hours'], {'opens': '09:00', 'closes': '23:00', 'days': ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun']});
      expect(find.byKey(const ValueKey('outlet-gstin')), findsNothing);
      expect(find.text('GSTIN: your business GSTIN (Maharashtra) is used.'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('outlet-fssai')), '12345678901234');
      await next(t);
      expect(find.text('Step 4 of 4 · Check and send'), findsOneWidget);
      await next(t);
      expect(f.calls.last.$1, 'outlet_list');
      expect(f.calls.any((c) => c.$1 == 'outlet_draft_submit'), isTrue);
      expect(find.byType(AddOutletScreen), findsNothing);
      expect(find.text('Niks Latur Highway'), findsOneWidget);
      expect(find.text('Pending verification'), findsNWidgets(2));
    });

    testWidgets('another state: its own GSTIN with that state code and a contact who will run it', (t) async {
      await openForm(t, f);
      await chooseState(t, 'Karnataka');
      expect(find.textContaining('Another state: this outlet needs its own GSTIN (starting 29)'), findsOneWidget);
      await next(t);
      expect(find.text('Step 2 of 5 · Outlet details'), findsOneWidget);
      await details(t, 'Niks Indiranagar');
      await next(t);
      await t.enterText(find.byKey(const ValueKey('outlet-gstin')), '27ABCDE1234F1Z5');
      await t.enterText(find.byKey(const ValueKey('outlet-fssai')), '12345678901234');
      await next(t);
      expect(find.text('A GSTIN for this state starts with 29.'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('outlet-gstin')), '29abcde1234f1z5');
      await next(t);
      expect(saves(f).last['gstin'], '29ABCDE1234F1Z5');
      expect(find.text('Step 4 of 5 · Who runs this outlet?'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('outlet-contact-name')), 'Ravi Kumar');
      await t.enterText(find.byKey(const ValueKey('outlet-contact-mobile')), '+91 98450 12345');
      await next(t);
      expect(find.text('Enter the contact\'s email: the invitation is sent there.'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('outlet-contact-email')), 'ravi@niks.in');
      await next(t);
      expect(saves(f).last, containsPair('contact_email', 'ravi@niks.in'));
      expect(find.text('Outlet admin'), findsOneWidget);
      expect(find.text('Step 5 of 5 · Check and send'), findsOneWidget);
    });

    testWidgets('save and continue later: the draft opens again at the same step with what was typed', (t) async {
      await openForm(t, f);
      await chooseState(t, 'Maharashtra');
      await next(t);
      await t.enterText(find.byKey(const ValueKey('outlet-name')), 'Niks Half Done');
      await t.ensureVisible(find.byKey(const ValueKey('outlet-save-later')));
      await t.tap(find.byKey(const ValueKey('outlet-save-later')));
      await t.pumpAndSettle();
      expect(find.byType(AddOutletScreen), findsNothing);
      expect(saves(f).last, containsPair('name', 'Niks Half Done'));
      expect(saves(f).last['step'], 'details', reason: 'the step the owner was on');
      expect(find.text('Continue: Niks Half Done'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('outlets-continue-draft')));
      await t.pumpAndSettle();
      expect(find.text('Step 2 of 4 · Outlet details'), findsOneWidget);
      expect(find.text('Niks Half Done'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('outlet-start-over')));
      await t.pumpAndSettle();
      expect(f.calls.last.$1, 'outlet_draft_discard');
      expect(find.text('Step 1 of 4 · Where is the new outlet?'), findsOneWidget);
    });

    testWidgets('a server refusal is shown on the step, nothing is assumed', (t) async {
      final api = OutletsApi(
        baseUrl: 'http://pos.test',
        accessToken: () => 't',
        client: MockClient((r) async => r.url.pathSegments.last == 'outlet_draft_save'
            ? http.Response(jsonEncode({'detail': 'Your business must be approved before it can add outlets.'}), 403, headers: _json)
            : ok({'draft': null, 'states': [{'code': '27', 'name': 'Maharashtra'}], 'home_state_code': '27', 'needs_fssai': false})),
      );
      await tall(t);
      await t.pumpWidget(MaterialApp(home: AddOutletScreen(api: api, needsFssai: false)));
      await t.pumpAndSettle();
      await chooseState(t, 'Maharashtra');
      await next(t);
      expect(find.text('Your business must be approved before it can add outlets.'), findsOneWidget);
      expect(find.text('Step 1 of 4 · Where is the new outlet?'), findsOneWidget, reason: 'stays on the step');
    });

    testWidgets('"use my location" fills the map pin', (t) async {
      await tall(t);
      await t.pumpWidget(MaterialApp(home: AddOutletScreen(api: f.api, needsFssai: true, locate: () async => (18.412345, 76.567891))));
      await t.pumpAndSettle();
      await chooseState(t, 'Maharashtra');
      await next(t);
      await t.tap(find.byKey(const ValueKey('outlet-pin-here')));
      await t.pumpAndSettle();
      expect(find.text('18.412345'), findsOneWidget);
      expect(find.text('76.567891'), findsOneWidget);
    });
  });

  group('Outlet switcher (header)', () {
    testWidgets('Home look: "SHOWING DATA FOR / All outlets (2)", bell and ☰; picking an outlet scopes the app', (t) async {
      await tall(t);
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: OutletHeader(title: 'Home', dashboard: true))));
      await t.pumpAndSettle();
      expect(find.text('ONELOCAL PARTNER'), findsOneWidget); // the banner's small line (founder, 22 Oct)
      expect(find.text('All outlets (2)'), findsOneWidget);
      expect(find.byKey(const ValueKey('outlet-header-bell')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('outlet-header-name')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('outlet-pick-all')), findsOneWidget);
      expect(find.byKey(const ValueKey('outlet-pick-l3')), findsNothing, reason: 'a pending outlet cannot be chosen');
      await t.tap(find.byKey(const ValueKey('outlet-pick-l2')));
      await t.pumpAndSettle();
      expect(OutletScope.selected.value, 'l2');
      expect(f.calls.last.$2['location_id'], 'l2', reason: 'the header reads the chosen outlet');
      await t.tap(find.byKey(const ValueKey('outlet-header-name')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('outlet-pick-all')));
      await t.pumpAndSettle();
      expect(OutletScope.selected.value, isNull);
    });

    testWidgets('a one-outlet screen (Orders, Bill) has no "All outlets" choice', (t) async {
      await tall(t);
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: OutletHeader(title: 'Orders'))));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('outlet-header-name')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('outlet-pick-all')), findsNothing);
      expect(find.byKey(const ValueKey('outlet-pick-l1')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('outlet-pick-manage')));
      await t.pumpAndSettle();
      expect(find.byType(OutletStatusScreen), findsOneWidget);
    });

    testWidgets('a screen that cannot sum shows its outlet even when "all" is chosen', (t) async {
      await tall(t);
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: OutletHeader(title: 'Home', dashboard: true, allowAll: false))));
      await t.pumpAndSettle();
      expect(find.text('Niks Browni And Burger'), findsOneWidget);
      expect(find.text('All outlets (2)'), findsNothing);
    });
  });
}
