import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';
import '../auth/partner_api.dart';

/// The application as the server describes it. Read-only; every field the screens show comes from here.
class Application {
  Application(this.raw);
  final Map<String, dynamic> raw;

  Map<String, dynamic> _m(String k) => (raw[k] as Map?)?.cast<String, dynamic>() ?? const {};
  List<Map<String, dynamic>> _list(String k) => ((raw[k] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();

  bool get exists => raw['exists'] == true;
  Map<String, dynamic> get app => _m('application');
  Map<String, dynamic> get address => _m('address');
  Map<String, dynamic> get tax => _m('tax');
  Map<String, dynamic> get identity => _m('identity');
  Map<String, dynamic>? get bank => raw['bank'] == null ? null : _m('bank');
  Map<String, dynamic> get consents => _m('consents');
  Map<String, dynamic> get progress => _m('progress');
  List<Map<String, dynamic>> get sections => _list('sections');
  List<Map<String, dynamic>> get checks => _list('checks');
  List<Map<String, dynamic>> get documents => _list('documents');
  List<Map<String, dynamic>> get timeline => _list('timeline');

  String? get status => app['status'] as String?;
  String get reference => (app['reference'] ?? '') as String;
  String get businessName => (app['business_name'] ?? '') as String;
  String get ownerName => (app['owner_name'] ?? '') as String;
  String get phone => (app['phone'] ?? '') as String;
  String? get partnerType => app['partner_type'] as String?;
  String? get sellPlan => app['sell_plan'] as String?;
  String? get reviewNote => app['review_note'] as String?;
  String? get submittedAt => app['submitted_at'] as String?;

  Map<String, dynamic>? document(String kind) {
    for (final d in documents) {
      if (d['kind'] == kind) return d;
    }
    return null;
  }

  Map<String, dynamic>? check(String kind) {
    for (final c in checks) {
      if (c['kind'] == kind) return c;
    }
    return null;
  }

  int get done => (progress['done'] ?? 0) as int;
  int get total => (progress['total'] ?? 7) as int;
  int get percent => ((progress['percent'] ?? 0) as num).round();
  bool get canSubmit => progress['can_submit'] == true;
}

/// The lists the screens show (categories, states, banks).
class Taxonomy {
  Taxonomy(this.raw);
  final Map<String, dynamic> raw;

  List<String> _strings(Object? v) => ((v as List?) ?? const []).map((e) => e.toString()).toList();
  List<({String name, List<String> subs})> _cats(Object? v) =>
      ((v as List?) ?? const []).map((e) => (name: (e as Map)['name'] as String, subs: _strings(e['subcategories']))).toList();
  List<String> get states => _strings(raw['states']);
  List<String> get banks => _strings(raw['banks']);
  List<String> get restaurantCategories => _strings((raw['restaurant'] as Map?)?['categories']);
  List<({String name, List<String> subs})> get storeCategories => _cats(raw['store']);
  List<({String name, List<String> subs})> get serviceCategories => _cats((raw['service'] as Map?)?['categories']);
}

/// One call per screen action, all through the one `/rpc/<name>` door ([RpcClient]). The database checks every rule.
class OnboardingApi {
  OnboardingApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc})
      : _http = client ?? http.Client(),
        _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);

  final http.Client _http;
  final RpcClient _rpc;

  Future<Application> _state(String fn, [Map<String, dynamic> args = const {}]) async => Application(await _rpc.callMap(fn, args));

  Future<Application> get() => _state('partner_app_get');
  Future<Taxonomy> taxonomy() async => Taxonomy(await _rpc.callMap('static_taxonomy'));

  Future<Application> saveProfile(Map<String, dynamic> body) => _state('partner_app_save_profile', body);
  Future<Application> choosePlan(String plan) => _state('partner_app_choose_plan', {'plan': plan});
  Future<Application> saveAddress(Map<String, dynamic> body) => _state('partner_app_save_address', body);
  Future<Application> saveTax(Map<String, dynamic> body) => _state('partner_app_save_tax', body);
  Future<Application> saveIdentity(Map<String, dynamic> body) => _state('partner_app_save_identity', body);
  Future<Application> saveBank(Map<String, dynamic> body) => _state('partner_app_save_bank', body);
  Future<Application> saveConsents(Map<String, dynamic> body) => _state('partner_app_save_consents', body);
  Future<Application> acceptAgreement(String version) => _state('partner_app_accept_agreement', {'version': version, 'acknowledged': true});
  Future<Application> submit() => _state('partner_app_submit');

  /// Two steps: ask for a private slot, send the bytes to it, then confirm so the server attaches the file.
  Future<Application> uploadDocument({required String kind, required Uint8List bytes, required String fileName, required String contentType}) async {
    final slot = await _rpc.callMap('partner_app_document_slot', {'kind': kind, 'content_type': contentType, 'size': bytes.length, 'file_name': fileName});
    final put = await _http.put(Uri.parse(slot['upload_url'] as String), headers: {'Content-Type': contentType, 'x-upsert': 'true'}, body: bytes).timeout(const Duration(seconds: 120));
    if (put.statusCode < 200 || put.statusCode >= 300) throw const PartnerApiException(502, 'The upload did not finish. Please try again.');
    return _state('partner_app_document_attach', {'kind': kind, 'path': slot['path'], 'content_type': contentType, 'size': bytes.length, 'file_name': fileName});
  }

  Future<String> previewUrl(String kind) async => (await _rpc.callMap('partner_app_document_preview', {'kind': kind}))['url'] as String;
}
