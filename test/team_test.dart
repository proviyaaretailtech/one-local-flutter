import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/app_routes.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/team/activity_tasks_screens.dart';
import 'package:vinii_pos/team/roles_screen.dart';
import 'package:vinii_pos/team/team_api.dart';
import 'package:vinii_pos/team/team_screens.dart';
import 'package:vinii_pos/team/team_widgets.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart';

/// Answers captured from the real local database (database/tests/440_team.sql story): the app is built against what the server sends.
final Map<String, dynamic> fx = jsonDecode(File('test/fixtures/team_server.json').readAsStringSync()) as Map<String, dynamic>;

http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});
http.Response err(int status, String detail, [String? code]) => http.Response(jsonEncode({'detail': detail, 'code': ?code}), status, headers: {'content-type': 'application/json; charset=utf-8'});
String fnOf(http.Request r) => r.url.path.split('/').last;
Map<String, dynamic> argsOf(http.Request r) => jsonDecode(r.body) as Map<String, dynamic>;

/// Fake server: records each request and answers from [handler], falling back to the captured fixtures for reads.
class Fake {
  Fake([http.Response? Function(http.Request r)? handler]) : _handler = handler;
  final http.Response? Function(http.Request r)? _handler;
  final requests = <http.Request>[];

  late final api = TeamApi(
    baseUrl: 'http://team.test',
    accessToken: () => 'token-123',
    client: MockClient((r) async {
      requests.add(r);
      final custom = _handler?.call(r);
      if (custom != null) return custom;
      return switch (fnOf(r)) {
        'team_options' => ok(fx['options']),
        'team_dashboard' => ok(fx['dashboard']),
        'team_user_list' => ok(fx['user_list']),
        'team_user_view' => ok(fx['member']),
        'team_role_view' => ok(fx['role']),
        'team_activity' => ok(fx['activity']),
        'team_task_list' => ok(fx['tasks']),
        'team_task_view' => ok(fx['task']),
        _ => err(404, 'not found: ${fnOf(r)}'),
      };
    }),
  );
  List<http.Request> calls(String fn) => requests.where((r) => fnOf(r) == fn).toList();
}

Future<void> show(WidgetTester t, Widget screen) async {
  ignoreOverflow();
  t.view.physicalSize = const Size(780, 3600);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: screen));
  await t.pumpAndSettle();
}

Map<String, dynamic> with_(String key, Map<String, dynamic> patch) => {...(fx[key] as Map<String, dynamic>), ...patch};

void main() {
  tearDown(HomeNav.reset);

  group('TeamApi', () {
    test('reads send the token and parse the server facts', () async {
      final s = Fake();
      final d = await s.api.dashboard();
      final r = s.requests.single;
      expect(r.method, 'POST');
      expect(r.url.toString(), 'http://team.test/rpc/team_dashboard');
      expect(r.headers['Authorization'], 'Bearer token-123');
      expect(d.n('members'), 6);
      expect(d.n('active_now'), 2);
    });

    test('the place filter is sent to the lists, not to a single record', () async {
      final s = Fake();
      s.api.locationId = 'loc-1';
      await s.api.users(filter: 'invited', q: ' pooja ');
      await s.api.user('p1');
      expect(argsOf(s.requests[0]), {'location_id': 'loc-1', 'filter': 'invited', 'q': 'pooja'});
      expect(argsOf(s.requests[1]), {'id': 'p1'});
    });

    test('invite sends what was typed and the resend flag only when asked', () async {
      final s = Fake((r) => ok(fx['invite']));
      await s.api.invite(fullName: 'Pooja Nair', mobile: '98765 43210', email: 'p@x.com', roleSlug: 'biller', locationId: 'loc-1');
      expect(argsOf(s.requests.last), {'full_name': 'Pooja Nair', 'mobile': '98765 43210', 'email': 'p@x.com', 'role_slug': 'biller', 'location_id': 'loc-1'});
      await s.api.invite(fullName: 'Pooja Nair', mobile: '98765 43210', email: 'p@x.com', roleSlug: 'biller', resend: true);
      expect(argsOf(s.requests.last)['resend'], true);
    });

    test('creating a task carries an Idempotency-Key; editing carries the version and no key', () async {
      final s = Fake((r) => ok(fx['task']));
      await s.api.saveTask(title: 'Restock', key: 'team-k1', dueAt: DateTime.utc(2026, 10, 17, 10));
      expect(s.requests.last.headers['Idempotency-Key'], 'team-k1');
      expect(argsOf(s.requests.last)['due_at'], '2026-10-17T10:00:00.000Z');
      await s.api.saveTask(id: 't1', version: 3, title: 'Restock!');
      expect(s.requests.last.headers['Idempotency-Key'], isNull);
      expect(argsOf(s.requests.last)['version'], 3);
      expect(TeamApi.newKey(), startsWith('team-'));
    });

    test('the server sentences and codes come through (duplicate number, stale version)', () async {
      final s = Fake((r) => err(409, 'This number already has an invitation.', 'duplicate_mobile'));
      await expectLater(s.api.invite(fullName: 'A B', mobile: '9', email: 'a@b.c', roleSlug: 'biller'),
          throwsA(isA<TeamApiException>().having((e) => e.duplicateMobile, 'duplicateMobile', true).having((e) => e.message, 'message', 'This number already has an invitation.')));
      final s2 = Fake((r) => err(409, 'Someone changed this task.', 'version_conflict'));
      await expectLater(s2.api.taskAct('t', 'start', version: 1), throwsA(isA<TeamApiException>().having((e) => e.stale, 'stale', true)));
    });
  });

  group('Team dashboard (Figma 118)', () {
    testWidgets('shows the counts, the quick actions and who is on shift', (t) async {
      final s = Fake();
      await show(t, TeamDashboardScreen(env: TeamEnv(api: s.api)));
      expect(find.text('Team dashboard'), findsOneWidget);
      expect(find.text('6 staff · 2 locations · Hollow Center'), findsOneWidget);
      expect(find.text('LIVE · 2 ACTIVE NOW'), findsOneWidget);
      for (final l in ['Team members', 'Active now', 'Invitations', 'Tasks due']) {
        expect(find.text(l), findsOneWidget);
      }
      expect(find.text('Invite team member'), findsOneWidget);
      expect(find.text('Team on shift'), findsOneWidget);
      expect(find.text('Ankit Verma'), findsOneWidget);
      expect(find.text('Cashier · Central Market'), findsOneWidget);
      expect(find.text('View all 6 members →'), findsOneWidget);
    });

    testWidgets('a person who may not invite does not see the invite button', (t) async {
      final s = Fake((r) => fnOf(r) == 'team_dashboard' ? ok(with_('dashboard', {'can_invite': false})) : null);
      await show(t, TeamDashboardScreen(env: TeamEnv(api: s.api)));
      expect(find.text('Invite team member'), findsNothing);
      expect(find.text('Staff tasks'), findsOneWidget);
    });

    testWidgets('a refused or failed load says so and offers Try again', (t) async {
      var fail = true;
      final s = Fake((r) => fnOf(r) == 'team_dashboard' && fail ? err(403, 'Your role cannot open the team.', 'forbidden') : null);
      await show(t, TeamDashboardScreen(env: TeamEnv(api: s.api)));
      expect(find.text('Could not load this'), findsOneWidget);
      expect(find.text('Your role cannot open the team.'), findsOneWidget);
      fail = false;
      await t.tap(find.text('Try again'));
      await t.pumpAndSettle();
      expect(find.text('LIVE · 2 ACTIVE NOW'), findsOneWidget);
    });

    testWidgets('the tiles open the lists they count', (t) async {
      final s = Fake();
      await show(t, TeamDashboardScreen(env: TeamEnv(api: s.api)));
      await t.tap(find.text('Invitations'));
      await t.pumpAndSettle();
      expect(find.text('Users'), findsOneWidget);
      expect(argsOf(s.calls('team_user_list').last)['filter'], 'invited');
    });
  });

  group('Users (Figma 119)', () {
    testWidgets('lists people with role, place and status; the chips carry the counts', (t) async {
      final s = Fake();
      await show(t, UsersScreen(env: TeamEnv(api: s.api)));
      expect(find.text('Users'), findsOneWidget);
      expect(find.text('All 7'), findsOneWidget);
      expect(find.text('Active 6'), findsOneWidget);
      expect(find.text('Invited 1'), findsOneWidget);
      expect(find.text('Paused 0'), findsOneWidget);
      expect(find.text('Bina Biller'), findsOneWidget);
      expect(find.text('Cashier · Hollow Center'), findsWidgets);
      expect(find.text('Invite user'), findsOneWidget);
    });

    testWidgets('choosing Invited asks the server for invited people; search sends the text', (t) async {
      final s = Fake();
      await show(t, UsersScreen(env: TeamEnv(api: s.api)));
      await t.tap(find.text('Invited 1'));
      await t.pumpAndSettle();
      expect(argsOf(s.calls('team_user_list').last)['filter'], 'invited');
      await t.enterText(find.byType(TextField), 'bina');
      await t.testTextInput.receiveAction(TextInputAction.search);
      await t.pumpAndSettle();
      expect(argsOf(s.calls('team_user_list').last)['q'], 'bina');
    });

    testWidgets('an empty answer says nobody matches', (t) async {
      final s = Fake((r) => fnOf(r) == 'team_user_list' ? ok({'items': [], 'counts': {'all': 0, 'active': 0, 'invited': 0, 'paused': 0}, 'can_invite': false}) : null);
      await show(t, UsersScreen(env: TeamEnv(api: s.api)));
      expect(find.text('Nobody here yet.'), findsOneWidget);
      expect(find.text('Invite user'), findsNothing);
    });
  });

  group('Role picker', () {
    Future<void> open(WidgetTester t, String? kind) async {
      final s = Fake();
      await show(t, Navigator(onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => InviteScreen(env: TeamEnv(api: s.api, kind: kind)))));
      await t.tap(find.text('Choose').first);
      await t.pumpAndSettle();
    }

    testWidgets('a store is not offered restaurant roles; the usual roles come first, the rest under More roles', (t) async {
      await open(t, 'store');
      expect(find.text('COMMON ROLES'), findsOneWidget);
      expect(find.text('MORE ROLES'), findsOneWidget);
      expect(find.text('Kitchen'), findsNothing);
      expect(find.text('Captain'), findsNothing);
      expect(find.text('Cashier'), findsOneWidget);
      // the usual roles are above the heading for the rest
      expect(t.getTopLeft(find.text('Inventory')).dy, lessThan(t.getTopLeft(find.text('MORE ROLES')).dy));
      expect(t.getTopLeft(find.text('Viewer')).dy, greaterThan(t.getTopLeft(find.text('MORE ROLES')).dy));
    });

    testWidgets('a restaurant is offered Kitchen and Captain', (t) async {
      await open(t, 'restaurant');
      expect(find.text('Kitchen'), findsOneWidget);
      expect(find.text('Captain'), findsOneWidget);
    });

    testWidgets('a role without a description shows how many permissions it has instead of a blank line', (t) async {
      await open(t, 'store');
      final inventory = ((fx['options'] as Map)['roles'] as List).cast<Map>().firstWhere((r) => r['slug'] == 'inventory_manager');
      expect(find.text('${inventory['permission_count']} permissions'), findsWidgets);
    });
  });

  group('Invite user (Figma 120)', () {
    testWidgets('the form has name, mobile with +91, email and role; the server decides the rest', (t) async {
      final s = Fake((r) => fnOf(r) == 'team_invite' ? ok(fx['invite']) : null);
      await show(t, Navigator(onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => InviteScreen(env: TeamEnv(api: s.api)))));
      expect(find.text('Full name'), findsOneWidget);
      expect(find.text('Mobile number'), findsOneWidget);
      expect(find.text('+91'), findsOneWidget);
      expect(find.text('Email address'), findsOneWidget);
      expect(find.text('Role'), findsOneWidget);
      await t.enterText(find.byType(TextField).at(0), 'Pooja Nair');
      await t.enterText(find.byType(TextField).at(1), '9876543210');
      await t.enterText(find.byType(TextField).at(2), 'pooja.nair@example.com');
      await t.tap(find.text('Choose').first);
      await t.pumpAndSettle();
      await t.tap(find.text('Cashier').last);
      await t.pumpAndSettle();
      await t.tap(find.text('Choose'));
      await t.pumpAndSettle();
      await t.tap(find.text('Hollow Center').last);
      await t.pumpAndSettle();
      await t.tap(find.text('Send invitation'));
      await t.pumpAndSettle();
      final sent = argsOf(s.calls('team_invite').single);
      expect(sent['full_name'], 'Pooja Nair');
      expect(sent['mobile'], '9876543210');
      expect(sent['email'], 'pooja.nair@example.com');
      expect(sent['role_slug'], 'biller');
      expect(sent['location_id'], '44000000-0000-0000-0000-00000000010a');
      expect(sent.containsKey('resend'), false);
    });

    testWidgets('a number that already has an invitation shows the red banner, the field message and Resend invitation', (t) async {
      var resend = false;
      final s = Fake((r) {
        if (fnOf(r) != 'team_invite') return null;
        if (argsOf(r)['resend'] == true) {
          resend = true;
          return ok(with_('invite', {'resent': true, 'created': false}));
        }
        return err(409, 'This number already has an invitation.', 'duplicate_mobile');
      });
      await show(t, Navigator(onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => InviteScreen(env: TeamEnv(api: s.api)))));
      await t.enterText(find.byType(TextField).at(0), 'Pooja Nair');
      await t.enterText(find.byType(TextField).at(1), '9876543210');
      await t.enterText(find.byType(TextField).at(2), 'pooja.nair@example.com');
      await t.tap(find.text('Choose').first);
      await t.pumpAndSettle();
      await t.tap(find.text('Cashier').last);
      await t.pumpAndSettle();
      await t.tap(find.text('Choose'));
      await t.pumpAndSettle();
      await t.tap(find.text('Hollow Center').last);
      await t.pumpAndSettle();
      await t.tap(find.text('Send invitation'));
      await t.pumpAndSettle();
      expect(find.text('Invitation couldn\'t be sent'), findsOneWidget);
      expect(find.text('This number already has an invitation. Resend it or use another number.'), findsOneWidget); // the banner says what to do next
      expect(find.text('This number already has an invitation.'), findsOneWidget); // under the mobile field
      expect(find.text('Fix the details and try again'), findsOneWidget);
      expect(find.text('Resend invitation'), findsOneWidget);
      expect(find.text('Send invitation'), findsNothing);
      await t.tap(find.text('Resend invitation'));
      await t.pumpAndSettle();
      expect(resend, true);
    });

    testWidgets('another kind of refusal shows only the banner (the ceiling, a bad email)', (t) async {
      final s = Fake((r) => fnOf(r) == 'team_invite' ? err(403, 'Only an owner can invite an owner or an admin.', 'ceiling') : null);
      await show(t, Navigator(onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => InviteScreen(env: TeamEnv(api: s.api)))));
      await t.tap(find.text('Send invitation'));
      await t.pumpAndSettle();
      expect(find.text('Invitation couldn\'t be sent'), findsOneWidget);
      expect(find.text('Only an owner can invite an owner or an admin.'), findsOneWidget);
      expect(find.text('Resend invitation'), findsNothing);
    });
  });

  group('Team member (Figma 121)', () {
    testWidgets('shows contact, places, role and the actions the server allows', (t) async {
      final s = Fake();
      await show(t, UserDetailScreen(env: TeamEnv(api: s.api), id: 'x'));
      expect(find.text('Team member'), findsOneWidget);
      expect(find.text('Bina Biller'), findsOneWidget);
      expect(find.text('ACTIVE'), findsOneWidget);
      expect(find.text('+91 90000 11111'), findsOneWidget);
      expect(find.text('Location access'), findsOneWidget);
      expect(find.text('Hollow Center'), findsOneWidget);
      expect(find.text('Cashier · 6 permissions enabled'), findsOneWidget);
      expect(find.text('Edit role'), findsOneWidget);
      expect(find.text('Suspend access'), findsOneWidget);
    });

    testWidgets('no actions from the server means no buttons', (t) async {
      final s = Fake((r) => fnOf(r) == 'team_user_view' ? ok(with_('member', {'allowed_actions': []})) : null);
      await show(t, UserDetailScreen(env: TeamEnv(api: s.api), id: 'x'));
      expect(find.text('Edit role'), findsNothing);
      expect(find.text('Suspend access'), findsNothing);
    });

    testWidgets('suspending asks first, then sends the action and shows the new state', (t) async {
      final s = Fake((r) => fnOf(r) == 'team_user_act' ? ok(with_('member', {'status': 'paused', 'allowed_actions': ['reactivate']})) : null);
      await show(t, UserDetailScreen(env: TeamEnv(api: s.api), id: 'x'));
      await t.tap(find.text('Suspend access'));
      await t.pumpAndSettle();
      expect(find.text('Suspend Bina Biller?'), findsOneWidget);
      expect(s.calls('team_user_act'), isEmpty);
      await t.tap(find.text('Suspend access').last);
      await t.pumpAndSettle();
      expect(argsOf(s.calls('team_user_act').single)['action'], 'suspend');
      expect(find.text('PAUSED'), findsOneWidget);
      expect(find.text('Restore access'), findsOneWidget);
    });

    testWidgets('a refusal from the server is shown as it is', (t) async {
      final s = Fake((r) => fnOf(r) == 'team_user_act' ? err(403, 'Only an owner can change an owner or an admin.', 'ceiling') : null);
      await show(t, UserDetailScreen(env: TeamEnv(api: s.api), id: 'x'));
      await t.tap(find.text('Suspend access'));
      await t.pumpAndSettle();
      await t.tap(find.text('Suspend access').last);
      await t.pumpAndSettle();
      expect(find.text('Only an owner can change an owner or an admin.'), findsOneWidget);
      expect(find.text('ACTIVE'), findsOneWidget);
    });

    testWidgets('edit role picks from the roles the server says are assignable and sends the slug', (t) async {
      final s = Fake((r) => fnOf(r) == 'team_user_act' ? ok(with_('member', {'role': {'slug': 'manager', 'name': 'Manager'}})) : null);
      await show(t, UserDetailScreen(env: TeamEnv(api: s.api), id: 'x'));
      await t.tap(find.text('Edit role'));
      await t.pumpAndSettle();
      await t.tap(find.text('Manager').last);
      await t.pumpAndSettle();
      final a = argsOf(s.calls('team_user_act').single);
      expect(a['action'], 'set_role');
      expect(a['role_slug'], 'manager');
    });

    testWidgets('an invitation shows resend and withdraw', (t) async {
      final s = Fake((r) => fnOf(r) == 'team_user_view' ? ok(fx['invitation']) : (fnOf(r) == 'team_invite_act' ? ok(fx['invitation']) : null));
      await show(t, UserDetailScreen(env: TeamEnv(api: s.api), id: 'x'));
      expect(find.text('Invitation'), findsOneWidget);
      expect(find.text('INVITED'), findsOneWidget);
      await t.tap(find.text('Resend invitation'));
      await t.pumpAndSettle();
      expect(argsOf(s.calls('team_invite_act').single)['action'], 'resend');
      expect(find.text('Withdraw invitation'), findsOneWidget);
    });
  });

  group('Roles & permissions (Figma 122)', () {
    testWidgets('shows the role and its switches, read only, with no Save changes', (t) async {
      final s = Fake();
      await show(t, RolesScreen(env: TeamEnv(api: s.api)));
      expect(find.text('Roles & permissions'), findsOneWidget);
      expect(find.text('Choose a role to review access'), findsOneWidget);
      for (final l in ['View orders', 'Accept orders', 'Manage catalogue', 'Manage team', 'View finance']) {
        expect(find.text(l), findsOneWidget);
      }
      final switches = t.widgetList<Switch>(find.byType(Switch)).toList();
      expect(switches, hasLength(5));
      expect(switches.every((w) => w.onChanged == null), true);
      expect(find.text('Save changes'), findsNothing);
      expect(find.textContaining('set by Proviyaa'), findsNothing); // the support note is not shown
      // the count matches the switches (4 of the 5 areas are on), not the raw permission total
      expect(find.text('4 of 5 areas switched on'), findsOneWidget);
      expect(find.textContaining(RegExp(r'\d+ permissions')), findsNothing);
    });

    testWidgets('switches follow what the server says the role has', (t) async {
      final s = Fake();
      await show(t, RolesScreen(env: TeamEnv(api: s.api)));
      final on = {for (final c in (fx['role']['capabilities'] as List)) c['title'] as String: c['enabled'] as bool};
      final switches = t.widgetList<Switch>(find.byType(Switch)).map((w) => w.value).toList();
      expect(switches, on.values.toList());
      expect(on['Manage team'], false);
    });

    testWidgets('choosing another role asks the server for that role', (t) async {
      final s = Fake();
      await show(t, RolesScreen(env: TeamEnv(api: s.api)));
      await t.tap(find.text('Role')); // the full-width role field
      await t.pumpAndSettle();
      await t.tap(find.text('Cashier').last);
      await t.pumpAndSettle();
      expect(argsOf(s.calls('team_role_view').last)['slug'], 'biller');
    });

    testWidgets('a store starts on Manager and its role list has no Kitchen or Captain', (t) async {
      final s = Fake();
      await show(t, RolesScreen(env: TeamEnv(api: s.api, kind: 'store')));
      expect(argsOf(s.calls('team_role_view').first)['slug'], 'manager');
      await t.tap(find.text('Role')); // the full-width role field
      await t.pumpAndSettle();
      expect(find.text('Choose a role'), findsOneWidget);
      expect(find.text('Kitchen'), findsNothing);
      expect(find.text('Captain'), findsNothing);
      expect(find.text('Owner'), findsOneWidget); // every role can be reviewed, under More roles
    });
  });

  group('Staff activity (Figma 123)', () {
    testWidgets('lists who did what, with the area and place, newest first', (t) async {
      final s = Fake();
      await show(t, ActivityScreen(env: TeamEnv(api: s.api)));
      expect(find.text('Staff activity'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('7 days'), findsOneWidget);
      expect(find.text('All locations'), findsWidgets);
      final first = (fx['activity']['items'] as List).first as Map;
      expect(find.text(first['text'] as String), findsOneWidget);
      expect(find.text('Team · All locations'), findsWidgets);
    });

    testWidgets('7 days asks for the longer range', (t) async {
      final s = Fake();
      await show(t, ActivityScreen(env: TeamEnv(api: s.api)));
      await t.tap(find.text('7 days'));
      await t.pumpAndSettle();
      expect(argsOf(s.calls('team_activity').last)['range'], '7d');
    });

    testWidgets('a person without access is told so', (t) async {
      final s = Fake((r) => err(403, 'Your role cannot see staff activity.', 'forbidden'));
      await show(t, ActivityScreen(env: TeamEnv(api: s.api)));
      expect(find.text('Your role cannot see staff activity.'), findsOneWidget);
    });
  });

  group('Staff tasks (Figma 124)', () {
    testWidgets('lists tasks with person, due time and status; chips carry counts', (t) async {
      final s = Fake();
      await show(t, TasksScreen(env: TeamEnv(api: s.api)));
      expect(find.text('Staff tasks'), findsOneWidget);
      expect(find.text('All 2'), findsOneWidget);
      expect(find.text('In progress 0'), findsOneWidget);
      expect(find.text('Overdue 1'), findsOneWidget);
      expect(find.text('Restock dairy shelf'), findsOneWidget);
      expect(find.text('Bina Biller · Cashier'), findsOneWidget);
      expect(find.text('Cycle count - beverages'), findsOneWidget);
      expect(find.textContaining('Overdue · '), findsOneWidget);
      expect(find.text('Overdue'), findsOneWidget);
      expect(find.text('Assigned'), findsOneWidget);
      expect(find.text('Create task'), findsOneWidget);
    });

    testWidgets('Overdue filters on the server', (t) async {
      final s = Fake();
      await show(t, TasksScreen(env: TeamEnv(api: s.api)));
      await t.tap(find.text('Overdue 1'));
      await t.pumpAndSettle();
      expect(argsOf(s.calls('team_task_list').last)['filter'], 'overdue');
    });

    testWidgets('a person who cannot create tasks has no Create task button', (t) async {
      final s = Fake((r) => fnOf(r) == 'team_task_list' ? ok(with_('tasks', {'can_create': false})) : null);
      await show(t, TasksScreen(env: TeamEnv(api: s.api)));
      expect(find.text('Create task'), findsNothing);
    });

    testWidgets('create task sends the title, the person, a key and shows server errors', (t) async {
      var first = true;
      final s = Fake((r) {
        if (fnOf(r) != 'team_task_save') return null;
        if (first) {
          first = false;
          return err(400, 'Give the task a short title.', 'bad_request');
        }
        return ok(fx['task']);
      });
      await show(t, Navigator(onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => TaskFormScreen(env: TeamEnv(api: s.api)))));
      await t.tap(find.text('Create task').last);
      await t.pumpAndSettle();
      expect(find.text('Task couldn\'t be saved'), findsOneWidget);
      expect(find.text('Give the task a short title.'), findsOneWidget);
      await t.enterText(find.byType(TextField).first, 'Restock dairy shelf');
      await t.tap(find.text('Choose a person'));
      await t.pumpAndSettle();
      await t.tap(find.text('Bina Biller').last);
      await t.pumpAndSettle();
      await t.tap(find.text('Create task').last);
      await t.pumpAndSettle();
      final calls = s.calls('team_task_save');
      expect(calls, hasLength(2));
      expect(argsOf(calls.last)['title'], 'Restock dairy shelf');
      expect(argsOf(calls.last)['assignee_staff_id'], '44a00000-0000-0000-0000-000000000001');
      // a retry of the same tap carries the same key
      expect(calls.last.headers['Idempotency-Key'], calls.first.headers['Idempotency-Key']);
    });

    testWidgets('task detail shows the story and only the buttons the server allows; start sends the version', (t) async {
      final s = Fake((r) => fnOf(r) == 'team_task_act' ? ok(with_('task', {'status': 'in_progress', 'display_status': 'in_progress', 'allowed_actions': ['submit'], 'version': 2})) : null);
      await show(t, TaskDetailScreen(env: TeamEnv(api: s.api), id: 'x'));
      expect(find.text('Restock dairy shelf'), findsOneWidget);
      expect(find.text('History'), findsOneWidget);
      expect(find.text('Start task'), findsOneWidget);
      expect(find.text('Approve'), findsNothing);
      await t.tap(find.text('Start task'));
      await t.pumpAndSettle();
      final a = argsOf(s.calls('team_task_act').single);
      expect(a['action'], 'start');
      expect(a['version'], fx['task']['version']);
      expect(find.text('Mark as done'), findsOneWidget);
      expect(find.text('Start task'), findsNothing);
    });

    testWidgets('a stale task reloads and says so', (t) async {
      final s = Fake((r) => fnOf(r) == 'team_task_act' ? err(409, 'Someone changed this task since you opened it.', 'version_conflict') : null);
      await show(t, TaskDetailScreen(env: TeamEnv(api: s.api), id: 'x'));
      await t.tap(find.text('Start task'));
      await t.pumpAndSettle();
      expect(find.text('Someone changed this task. Showing the latest.'), findsOneWidget);
      expect(s.calls('team_task_view'), hasLength(2));
    });
  });

  group('wiring', () {
    test('the team opens from the control centre once the routes are installed', () {
      expect(HomeNav.team, isNull);
      installRoutes();
      expect(HomeNav.team, isNotNull);
    });

    test('time labels', () {
      expect(clock12(DateTime(2026, 10, 17, 10, 42)), '10:42 AM');
      expect(clock12(DateTime(2026, 10, 17, 0, 5)), '12:05 AM');
      expect(clock12(DateTime(2026, 10, 17, 18, 18)), '6:18 PM');
      final now = DateTime(2026, 10, 17, 12);
      expect(whenLabel(DateTime(2026, 10, 17, 9, 56), now), '9:56 AM');
      expect(whenLabel(DateTime(2026, 10, 16, 18, 18), now), 'Yesterday · 6:18 PM');
      expect(whenLabel(DateTime(2026, 10, 5, 18, 18), now), '05 Oct · 6:18 PM');
    });
  });
}
