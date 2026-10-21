// Exports the built section L (Team) screens as phone frame PNGs (405 pt wide, 2x, real Inter and Lucide fonts) for side-by-side review
// with assets/figma_ref_l. Uses the answers captured from the real database (test/fixtures/team_server.json). Skipped unless EXPORT_FRAMES=1:
//   EXPORT_FRAMES=1 flutter test --update-goldens test/team_frames_test.dart   -> test/frames_l/*.png
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/team/activity_tasks_screens.dart';
import 'package:vinii_pos/team/roles_screen.dart';
import 'package:vinii_pos/team/team_api.dart';
import 'package:vinii_pos/team/team_screens.dart';
import 'package:vinii_pos/team/team_widgets.dart';
import 'package:vinii_pos/ui/theme.dart';

final Map<String, dynamic> _fx = jsonDecode(File('test/fixtures/team_server.json').readAsStringSync()) as Map<String, dynamic>;

Future<void> _font(String family, String asset) async {
  final loader = FontLoader(family)..addFont(rootBundle.load(asset));
  await loader.load();
}

http.Response _json(Object body, [int status = 200]) => http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

TeamEnv _env() => TeamEnv(
      api: TeamApi(
        baseUrl: 'http://frames.local',
        accessToken: () => 'frames',
        client: MockClient((r) async => switch (r.url.path.split('/').last) {
              'team_options' => _json(_fx['options']),
              'team_dashboard' => _json(_fx['dashboard']),
              'team_user_list' => _json(_fx['user_list']),
              'team_user_view' => _json(_fx['member']),
              'team_role_view' => _json(_fx['role']),
              'team_activity' => _json(_fx['activity']),
              'team_task_list' => _json(_fx['tasks']),
              'team_task_view' => _json(_fx['task']),
              'team_invite' => _json({'detail': 'This number already has an invitation.', 'code': 'duplicate_mobile'}, 409),
              _ => _json({'detail': 'not found'}, 404),
            }),
      ),
    );

void main() {
  final on = Platform.environment['EXPORT_FRAMES'] == '1';
  setUpAll(() async {
    if (!on) return;
    await _font('Inter', 'fonts/Inter.ttf');
    await _font('packages/lucide_icons_flutter/Lucide', 'packages/lucide_icons_flutter/assets/lucide.ttf');
  });

  Future<void> frame(WidgetTester t, String file, Widget screen, {double height = 1700, Future<void> Function()? then}) async {
    t.view.physicalSize = Size(810, height * 2);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(RepaintBoundary(
        key: const ValueKey('frame'),
        child: MaterialApp(debugShowCheckedModeBanner: false, theme: posTheme(), home: Navigator(onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => screen)))));
    await t.pumpAndSettle();
    if (then != null) await then();
    await expectLater(find.byKey(const ValueKey('frame')), matchesGoldenFile('frames_l/$file.png'));
  }

  testWidgets('frames', (t) async {
    await frame(t, 'dashboard', TeamDashboardScreen(env: _env()));
    await frame(t, 'users', UsersScreen(env: _env()));
    await frame(t, 'invite', InviteScreen(env: _env()), height: 1300);
    await frame(t, 'invite_role_picker', InviteScreen(env: _env()), height: 844, then: () async {
      await t.tap(find.text('Choose').first);
      await t.pumpAndSettle();
    });
    await frame(t, 'invite_error', InviteScreen(env: _env()), height: 1500, then: () async {
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
    });
    final memberId = ((_fx['member'] as Map)['member'] as Map?)?['id']?.toString() ?? (_fx['member'] as Map)['id']?.toString() ?? 'm1';
    await frame(t, 'user_detail', UserDetailScreen(env: _env(), id: memberId), height: 1900);
    await frame(t, 'roles', RolesScreen(env: _env()), height: 1900);
    await frame(t, 'activity', ActivityScreen(env: _env()));
    await frame(t, 'tasks', TasksScreen(env: _env()));
  }, skip: !on);
}
