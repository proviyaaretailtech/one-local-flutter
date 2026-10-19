import 'dart:math';

import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';
import '../auth/partner_api.dart';
import '../inventory/inventory_api.dart' show Facts;

/// Team calls through the one generic door, `POST /rpc/<team_function>` ([RpcClient]); the database functions of migration 0440 do the work and
/// check the business, the place, the role and every rule (only an owner makes an owner or an admin; nobody changes their own access). The Supabase
/// session token is the only credential. Nothing here is a business rule: the app sends what the person typed and draws what the server answers.
class TeamApi {
  TeamApi({
    http.Client? client,
    String? baseUrl,
    String? Function()? accessToken,
    RpcClient? rpc,
    this.locationId,
  }) : _rpc =
           rpc ??
           RpcClient(
             client: client,
             baseUrl: baseUrl,
             accessToken: accessToken,
           );

  final RpcClient _rpc;

  /// The place the screens look at; null means every place the person may see.
  String? locationId;

  static final _rand = Random.secure();

  /// A fresh key for one intent (one tap). Keep it and send it again when retrying that same tap.
  static String newKey() =>
      'team-${List.generate(16, (_) => _rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  Future<Map<String, dynamic>> _call(
    String fn,
    Map<String, Object?> args, {
    String? key,
    bool scoped = true,
  }) async {
    final body = <String, dynamic>{
      if (scoped && locationId != null && locationId!.isNotEmpty)
        'location_id': locationId,
      ...args,
    }..removeWhere((_, v) => v == null);
    try {
      return await _rpc.callMap(fn, body, key);
    } on RpcException catch (e) {
      throw TeamApiException(e.status, e.message, e.code);
    }
  }

  Future<Facts> options() async =>
      Facts(await _call('team_options', {}, scoped: false));
  Future<Facts> dashboard() async => Facts(await _call('team_dashboard', {}));

  /// [filter]: all, active, invited, paused.
  Future<Facts> users({String filter = 'all', String q = ''}) async =>
      Facts(await _call('team_user_list', {'filter': filter, 'q': q.trim()}));
  Future<Facts> user(String id) async =>
      Facts(await _call('team_user_view', {'id': id}, scoped: false));
  Future<Facts> role(String slug) async =>
      Facts(await _call('team_role_view', {'slug': slug}, scoped: false));

  /// [range]: today or 7d.
  Future<Facts> activity({String range = 'today'}) async =>
      Facts(await _call('team_activity', {'range': range}));

  /// [filter]: all, in_progress, overdue, done.
  Future<Facts> tasks({String filter = 'all'}) async =>
      Facts(await _call('team_task_list', {'filter': filter}));
  Future<Facts> task(String id) async =>
      Facts(await _call('team_task_view', {'id': id}, scoped: false));

  /// Invites a person, or with [resend] sends the invitation that already exists for that number or email again.
  Future<Facts> invite({
    required String fullName,
    required String mobile,
    required String email,
    required String roleSlug,
    String? locationId,
    bool resend = false,
  }) async => Facts(
    await _call('team_invite', {
      'full_name': fullName,
      'mobile': mobile,
      'email': email,
      'role_slug': roleSlug,
      'location_id': locationId,
      'resend': resend ? true : null,
    }, scoped: false),
  );

  /// resend / revoke an invitation.
  Future<Facts> inviteAct(String id, String action) async => Facts(
    await _call('team_invite_act', {'id': id, 'action': action}, scoped: false),
  );

  /// set_role (with [roleSlug], and [locationIds] when the role is place-bound), set_locations, suspend, reactivate.
  Future<Facts> userAct(
    String id,
    String action, {
    String? roleSlug,
    List<String>? locationIds,
  }) async => Facts(
    await _call('team_user_act', {
      'id': id,
      'action': action,
      'role_slug': roleSlug,
      'location_ids': locationIds,
    }, scoped: false),
  );

  /// Creates a task (no [id]) or edits one the person opened at [version].
  Future<Facts> saveTask({
    String? id,
    int? version,
    required String title,
    String description = '',
    String priority = 'medium',
    String? assigneeStaffId,
    DateTime? dueAt,
    bool approvalRequired = false,
    String? key,
  }) async => Facts(
    await _call(
      'team_task_save',
      {
        'id': id,
        'version': version,
        'title': title,
        'description': description,
        'priority': priority,
        'assignee_staff_id': assigneeStaffId,
        'due_at': dueAt?.toUtc().toIso8601String(),
        'approval_required': approvalRequired,
      },
      key: id == null ? (key ?? newKey()) : null,
      scoped: false,
    ),
  );

  /// start / submit / complete / fail / reassign / cancel. [version] is the one the person saw.
  Future<Facts> taskAct(
    String id,
    String action, {
    required int version,
    String? note,
    String? assigneeStaffId,
  }) async => Facts(
    await _call('team_task_act', {
      'id': id,
      'action': action,
      'version': version,
      'note': note,
      'assignee_staff_id': assigneeStaffId,
    }, scoped: false),
  );
}

class TeamApiException extends PartnerApiException {
  const TeamApiException(super.status, super.message, this.code);
  final String? code;

  /// "This number already has an invitation." (Figma: Invite User, validation error)
  bool get duplicateMobile => code == 'duplicate_mobile';
  bool get duplicateEmail => code == 'duplicate_email';
  bool get stale => code == 'version_conflict';
}
