import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

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

/// One call per screen action, all through the One Local server (`/api/onboarding/*`). The server checks every rule again.
class OnboardingApi {
  OnboardingApi({http.Client? client, String? baseUrl, String? Function()? accessToken})
      : _http = client ?? http.Client(),
        _token = accessToken ?? (() => Supabase.instance.client.auth.currentSession?.accessToken),
        _base = (baseUrl ?? const String.fromEnvironment('PARTNER_API_BASE_URL')).replaceAll(RegExp(r'/+$'), '');

  final http.Client _http;
  final String? Function() _token;
  final String _base;

  Future<Map<String, dynamic>> _send(String method, String path, [Object? body]) async {
    final token = _token();
    if (token == null) throw const PartnerApiException(401, 'Sign in to continue.');
    final uri = Uri.parse('$_base/api/onboarding$path');
    final headers = {'Authorization': 'Bearer $token', if (body != null) 'Content-Type': 'application/json'};
    final res = await switch (method) {
      'GET' => _http.get(uri, headers: headers),
      'PUT' => _http.put(uri, headers: headers, body: jsonEncode(body ?? {})),
      _ => _http.post(uri, headers: headers, body: body == null ? null : jsonEncode(body)),
    }.timeout(const Duration(seconds: 30));
    final decoded = res.body.isEmpty ? <String, dynamic>{} : jsonDecode(res.body);
    final map = decoded is Map ? decoded.cast<String, dynamic>() : <String, dynamic>{};
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw PartnerApiException(res.statusCode, (map['detail'] as String?) ?? 'Something went wrong. Please try again.');
    }
    return map;
  }

  Future<Application> _state(String method, String path, [Object? body]) async => Application(await _send(method, path, body));

  Future<Application> get() => _state('GET', '/application');
  Future<Taxonomy> taxonomy() async => Taxonomy(await _send('GET', '/taxonomy'));

  Future<Application> saveProfile(Map<String, dynamic> body) => _state('PUT', '/profile', body);
  Future<Application> choosePlan(String plan) => _state('PUT', '/plan', {'plan': plan});
  Future<Application> saveAddress(Map<String, dynamic> body) => _state('PUT', '/address', body);
  Future<Application> saveTax(Map<String, dynamic> body) => _state('PUT', '/tax', body);
  Future<Application> saveIdentity(Map<String, dynamic> body) => _state('PUT', '/identity', body);
  Future<Application> saveBank(Map<String, dynamic> body) => _state('PUT', '/bank', body);
  Future<Application> saveConsents(Map<String, dynamic> body) => _state('PUT', '/consents', body);
  Future<Application> acceptAgreement(String version) => _state('PUT', '/agreement', {'version': version, 'acknowledged': true});
  Future<Application> submit() => _state('POST', '/submit');

  /// Two steps: ask for a private slot, send the bytes to it, then confirm so the server attaches the file.
  Future<Application> uploadDocument({required String kind, required Uint8List bytes, required String fileName, required String contentType}) async {
    final slot = await _send('POST', '/documents/upload', {'kind': kind, 'content_type': contentType, 'size': bytes.length, 'file_name': fileName});
    final put = await _http.put(Uri.parse(slot['upload_url'] as String), headers: {'Content-Type': contentType, 'x-upsert': 'true'}, body: bytes).timeout(const Duration(seconds: 120));
    if (put.statusCode < 200 || put.statusCode >= 300) throw const PartnerApiException(502, 'The upload did not finish. Please try again.');
    return _state('POST', '/documents', {'kind': kind, 'path': slot['path'], 'content_type': contentType, 'size': bytes.length, 'file_name': fileName});
  }

  Future<String> previewUrl(String kind) async => (await _send('GET', '/documents/$kind/preview'))['url'] as String;
}
