import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';
import '../auth/partner_api.dart';
import '../onboarding/document_picker.dart';
import '../ui/i18n.dart';

/// Ads with OneLocal coins (founder's sketch and the Advertising & Partner Growth spec, 29 Oct 2026): the dashboard, campaigns (format,
/// objective, a 9:16 photo or video, dates, a price only once OneLocal has approved and switched it on), accepting a price, holding coins,
/// pausing, cancelling, change requests, disputes, reports, and topping up coins (1 coin = ₹10; paid over UPI, pending until seen).
class AdsApi {
  AdsApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc})
      : _http = client ?? http.Client(),
        _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);
  final http.Client _http;
  final RpcClient _rpc;
  static final _rand = Random.secure();
  static String newKey() => 'ad-${List.generate(16, (_) => _rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  Future<Map<String, dynamic>> _call(String fn, Map<String, Object?> args, {String? key}) async {
    try {
      return await _rpc.callMap(fn, {...args}..removeWhere((_, v) => v == null), key);
    } on RpcException catch (e) {
      throw PartnerApiException(e.status, e.message);
    }
  }

  /// balances {available, promotional, reserved, consumed, expired, pending, disputed}, coins (available), pending_coins, coin_rupees,
  /// upi_id, payee_name, formats [{id, name, blurb, media, models, rules: [active rules]}], counts {live, upcoming, review, draft, ended},
  /// tracking, series [{day, views, clicks, valid_clicks, leads, visits, spent}] (14 days), ads [...], disputes [...], ledger [...].
  Future<Map<String, dynamic>> home() => _call('ads_home', {});

  /// A new campaign or an edit of a draft (draft: true saves without sending). With an active price the shop accepts it here and the
  /// coins are held if it has them; without one OneLocal sends a price. {ad, balances}
  Future<Map<String, dynamic>> save(Map<String, Object?> body, {required String key}) => _call('ads_save', body, key: key);

  /// Cancels a campaign: days already started are spent, the rest of its held coins come back. {ad, refunded, coins, balances}
  Future<Map<String, dynamic>> stop(String id) => _call('ads_stop', {'id': id});

  /// The active price for a format and pricing model. {rule (null: OneLocal sends a price), cost, available}
  Future<Map<String, dynamic>> quote(Map<String, Object?> body) => _call('ads_quote', body);

  /// Accepts the price OneLocal sent. {ad, balances}
  Future<Map<String, dynamic>> accept(String id) => _call('ads_accept', {'id': id, 'agree': true});

  /// Holds the coins for a campaign waiting for them. {ad, balances}
  Future<Map<String, dynamic>> fund(String id) => _call('ads_fund', {'id': id});

  /// Pauses ([pause] true) or resumes a click, view or lead campaign. {ad, balances}
  Future<Map<String, dynamic>> pause(String id, {required bool pause}) => _call('ads_pause', {'id': id, 'pause': pause});

  /// Asks OneLocal to change a campaign that is already with them. {ad}
  Future<Map<String, dynamic>> changeRequest(String id, String note) => _call('ads_change_request', {'id': id, 'note': note});

  /// Disputes a campaign's charges or asks for an invalid-click check. {dispute, balances}
  Future<Map<String, dynamic>> dispute(String adId, {required String kind, required String reason, num? coins}) =>
      _call('ads_dispute', {'ad_id': adId, 'kind': kind, 'reason': reason, 'coins': coins});

  /// One campaign's numbers day by day. {ad, days: [{day, views, clicks, valid_clicks, visits, leads, spent}]}
  Future<Map<String, dynamic>> report(String id) => _call('ads_report', {'id': id});

  /// Ad credits are rupees (0635): no top-ups. The OneLocal wallet: {unsettled: {due_minor}, owed_to_onelocal: {amount_minor}, ad_credits_moved}.
  Future<Map<String, dynamic>> walletOverview() => _call('wallet_overview', {});

  /// Moves [amountMinor] (whole rupees, at least ₹100) from the OneLocal wallet into ad credits; it comes off the next weekly settlement.
  Future<Map<String, dynamic>> walletMove(int amountMinor, {required String key}) => _call('ads_wallet_move', {'amount_minor': amountMinor}, key: key);

  // ---- OneLocal's side: platform admins only (the database checks)

  /// {admin: true} for a OneLocal platform admin.
  Future<bool> adminMe() async => (await _call('ol_admin_me', {}))['admin'] == true;

  /// {review: [ads waiting for OneLocal, each with business], businesses: [{id, name, credits}] matching [q], grants: [{business, amount, note, created_at}]}.
  Future<Map<String, dynamic>> adminQueue({String q = ''}) => _call('ads_admin_queue', {'q': q.trim().isEmpty ? null : q.trim()});

  /// The check of an ad: approved, changes_requested or rejected, with a note.
  Future<Map<String, dynamic>> adminReview(String id, String decision, {String note = ''}) =>
      _call('ads_admin_review', {'id': id, 'decision': decision, 'note': note.trim().isEmpty ? null : note.trim()});

  /// The price OneLocal offers: an active rule, or a rate (₹) for a pricing model; budget for per-click/view/lead.
  Future<Map<String, dynamic>> adminOffer(String id, {String? ruleId, String? model, num? rate, num? budget}) =>
      _call('ads_admin_offer', {'id': id, 'rule_id': ruleId, 'pricing_model': model, 'rate_coins': rate, 'budget_coins': budget});

  /// Gives a business [rupees] of ad credits from OneLocal.
  Future<Map<String, dynamic>> grant(String organizationId, num rupees, {String note = ''}) =>
      _call('ads_grant', {'organization_id': organizationId, 'coins': rupees, 'note': note.trim().isEmpty ? null : note.trim()});

  /// Sends the ad's photo or video to a signed slot under the shop's folder. (path, media_kind)
  Future<({String path, String kind})> uploadMedia(PickedDocument d) async {
    final slot = await _call('ads_media_slot', {'content_type': d.contentType, 'size': d.bytes.length});
    final put = await _http
        .put(Uri.parse(slot['upload_url'] as String), headers: {'Content-Type': d.contentType, 'x-upsert': 'true'}, body: d.bytes)
        .timeout(const Duration(minutes: 5));
    if (put.statusCode >= 300) throw PartnerApiException(put.statusCode, tr('Could not upload. Try again.'));
    return (path: slot['path'] as String, kind: slot['media_kind'] as String? ?? 'image');
  }

  /// A 10-minute link to an ad's photo or video.
  Future<String> mediaLink(String id) async => (await _call('ads_media_link', {'id': id}))['url'] as String;
}

const _photoExt = {'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png', 'webp': 'image/webp'};
const _videoExt = {'mp4': 'video/mp4', 'mov': 'video/quicktime', 'webm': 'video/webm'};

/// Picks the ad's photo ([video] false) or video from the device. Tests replace it.
Future<PickedDocument?> Function({required bool video}) pickAdMedia = ({required bool video}) async {
  final ext = video ? _videoExt : _photoExt;
  final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ext.keys.toList());
  if (f == null) return null;
  final type = ext[f.name.split('.').last.toLowerCase()];
  if (type == null) return null;
  return PickedDocument(name: f.name, bytes: await f.readAsBytes(), contentType: type);
};
