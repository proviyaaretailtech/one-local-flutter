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

  /// Asks to top up [coins], paid by [method] (gpay, phonepe, upi). {id, ref, coins, amount_minor, status, upi_id, payee_name}
  Future<Map<String, dynamic>> topUp(int coins, String method, {required String key}) => _call('ads_topup', {'coins': coins, 'method': method}, key: key);

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
