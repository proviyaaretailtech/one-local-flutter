import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';
import '../auth/partner_api.dart';
import '../onboarding/document_picker.dart';

/// Workspace setup as the server describes it (`GET /api/setup/state`). Read-only; every value the screens show comes from here.
class SetupState {
  SetupState(this.raw);
  final Map<String, dynamic> raw;

  Map<String, dynamic> _m(String k) => (raw[k] as Map?)?.cast<String, dynamic>() ?? const {};
  static List<Map<String, dynamic>> maps(Object? v) => ((v as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
  static List<String> strings(Object? v) => ((v as List?) ?? const []).map((e) => e.toString()).toList();

  Map<String, dynamic> get organization => _m('organization');
  Map<String, dynamic> get progress => _m('progress');
  Map<String, dynamic> get plan => _m('plan');
  Map<String, dynamic> get payment => _m('payment');
  Map<String, dynamic> get tax => _m('tax');
  Map<String, dynamic> get pos => _m('pos');
  Map<String, dynamic> get staff => _m('staff');
  Map<String, dynamic> get catalogue => _m('catalogue');
  Map<String, dynamic> get listing => _m('listing');
  Map<String, dynamic> get fulfilment => _m('fulfilment');
  List<Map<String, dynamic>> get checklist => maps(raw['checklist']);

  String get businessName => (organization['name'] ?? '') as String;
  String get partnerType => (organization['partner_type'] ?? 'store') as String;
  bool get isRestaurant => partnerType == 'restaurant';
  int get done => (progress['done'] ?? 0) as int;
  int get total => (progress['total'] ?? 0) as int;
  String? get next => progress['next'] as String?;
  bool get canComplete => progress['can_complete'] == true;
  bool get completed => progress['completed'] == true;
  bool get posRequired => pos['required'] != false;

  /// Listed on the OneLocal app: every plan but Purchase POS (pos_only), which has no listing and no delivery.
  bool get sellsOnline => plan['sell_plan'] != 'pos_only';
  Set<int> get tourSeen => ((raw['tour_seen'] as List?) ?? const []).map((e) => (e as num).toInt()).toSet();

  /// The checklist row for [key], or an empty map.
  Map<String, dynamic> row(String key) => checklist.firstWhere((r) => r['key'] == key, orElse: () => const {});
  bool isDone(String key) => row(key)['done'] == true;
}

/// One call per screen action, all through the one `/rpc/<name>` door ([RpcClient]). The database checks every rule.
class SetupApi {
  SetupApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc})
      : _http = client ?? http.Client(),
        _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);

  final http.Client _http;
  final RpcClient _rpc;

  Future<SetupState> _state(String fn, [Map<String, dynamic> args = const {}]) async => SetupState(await _rpc.callMap(fn, args));

  Future<SetupState> get() => _state('partner_setup_get');
  Future<SetupState> confirmPlan(String? planCode) => _state('partner_setup_confirm_plan', {'plan_code': planCode});
  Future<SetupState> savePayment(Map<String, dynamic> body) => _state('partner_setup_save_payment', body);
  Future<SetupState> saveTax(Map<String, dynamic> body) => _state('partner_setup_save_tax', body);
  Future<SetupState> registerPos(Map<String, dynamic> body) => _state('partner_setup_register_pos', body);
  Future<SetupState> inviteStaff(Map<String, dynamic> body) => _state('partner_setup_invite_staff', body);
  Future<SetupState> addItem(Map<String, dynamic> body) => _state('partner_setup_add_item', body);
  Future<SetupState> saveListing(Map<String, dynamic> body) => _state('partner_setup_save_listing', body);
  Future<SetupState> saveFulfilment(Map<String, dynamic> body) => _state('partner_setup_save_fulfilment', body);
  Future<SetupState> tourSeen(int step) => _state('partner_setup_tour_seen', {'step': step});
  Future<SetupState> complete() => _state('partner_setup_complete');

  /// Two steps: ask for a private slot, send the bytes to it, then confirm so the server attaches the image.
  Future<SetupState> uploadImage({required String kind, required Uint8List bytes, required String contentType}) async {
    final slot = await _rpc.callMap('partner_setup_image_slot', {'kind': kind, 'content_type': contentType, 'size': bytes.length});
    final put = await _http.put(Uri.parse(slot['upload_url'] as String), headers: {'Content-Type': contentType, 'x-upsert': 'true'}, body: bytes).timeout(const Duration(seconds: 120));
    if (put.statusCode < 200 || put.statusCode >= 300) throw const PartnerApiException(502, 'The upload did not finish. Please try again.');
    return _state('partner_setup_image_attach', {'kind': kind, 'path': slot['path'], 'content_type': contentType, 'size': bytes.length});
  }
}

/// Chooses a JPG or PNG for the listing logo or cover.
class ImagePicker extends DocumentPicker {
  const ImagePicker();
  @override
  Future<PickedDocument?> pick() async {
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['jpg', 'jpeg', 'png']);
    if (f == null) return null;
    final type = f.name.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';
    return PickedDocument(name: f.name, bytes: await f.readAsBytes(), contentType: type);
  }
}
