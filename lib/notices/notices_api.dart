import 'dart:math';

import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';
import '../inventory/inventory_api.dart' show Facts;

/// Section N calls through the one generic door, `POST /rpc/<name>` ([RpcClient]); the database functions of migration 0460 do the work and
/// check the business, the place and the role. Customer messages are recorded and queued by the database; nothing is sent from here.
class NoticesApi {
  NoticesApi({
    http.Client? client,
    String? baseUrl,
    String? Function()? accessToken,
    RpcClient? rpc,
  }) : _rpc =
           rpc ??
           RpcClient(
             client: client,
             baseUrl: baseUrl,
             accessToken: accessToken,
           );

  final RpcClient _rpc;
  static final _rand = Random.secure();

  /// A fresh key for one tap on "Queue message"; keep it for a retry of that same tap.
  static String newKey() =>
      'msg-${List.generate(16, (_) => _rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  Future<Facts> notices({String? category, int limit = 50}) async => Facts(
    await _rpc.callMap('notice_list', {'category': ?category, 'limit': limit}),
  );
  Future<int> markNoticesRead({
    List<String>? ids,
    bool all = false,
    String? category,
  }) async =>
      (await _rpc.callMap('notice_mark_read', {
            'ids': ?ids,
            if (all) 'all': true,
            'category': ?category,
          }))['marked']
          as int? ??
      0;

  Future<Facts> announcements() async =>
      Facts(await _rpc.callMap('announce_list'));
  Future<void> markAnnouncementRead({String? id, bool all = false}) =>
      _rpc.callMap('announce_mark_read', {'id': ?id, if (all) 'all': true});

  Future<Facts> options() async => Facts(await _rpc.callMap('comm_options'));
  Future<Facts> audience(String segment, String channel) async => Facts(
    await _rpc.callMap('comm_audience', {
      'segment': segment,
      'channel': channel,
    }),
  );
  Future<Facts> queue({
    required String channel,
    required String segment,
    required String message,
    String title = '',
    required String key,
  }) async => Facts(
    await _rpc.callMap('comm_queue', {
      'channel': channel,
      'segment': segment,
      'message': message,
      if (title.trim().isNotEmpty) 'title': title.trim(),
    }, key),
  );
  Future<List<Facts>> campaigns() async =>
      Facts(await _rpc.callMap('comm_list')).l('items');
  Future<Facts> cancel(String id) async =>
      Facts(await _rpc.callMap('comm_cancel', {'id': id}));

  Future<Facts> feedback({String? status}) async =>
      Facts(await _rpc.callMap('comm_feedback_list', {'status': ?status}));
  Future<Facts> respond(
    String id,
    String status, [
    String response = '',
  ]) async => Facts(
    await _rpc.callMap('comm_feedback_respond', {
      'id': id,
      'status': status,
      'response': ?(response.trim().isEmpty ? null : response.trim()),
    }),
  );
}

/// "10:42 AM", "Yesterday · 6:30 PM", "8 Oct · 11:00 AM" (the notification rows).
String noticeTime(DateTime t, DateTime now) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final clock =
      '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
  final d = DateTime(t.year, t.month, t.day),
      today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(d).inDays;
  if (diff == 0) return clock;
  if (diff == 1) return 'Yesterday · $clock';
  return '${t.day} ${_months[t.month - 1]} · $clock';
}

/// "9 Oct 2026" (the announcement cards).
String noticeDate(DateTime t) => '${t.day} ${_months[t.month - 1]} ${t.year}';
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// A readable sentence for any failure.
String noticeError(Object e) => e is RpcException
    ? e.message
    : 'Could not reach the server. Check your connection and try again.';
