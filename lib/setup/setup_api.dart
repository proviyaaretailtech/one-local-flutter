import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

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
  Set<int> get tourSeen => ((raw['tour_seen'] as List?) ?? const []).map((e) => (e as num).toInt()).toSet();

  /// The checklist row for [key], or an empty map.
  Map<String, dynamic> row(String key) => checklist.firstWhere((r) => r['key'] == key, orElse: () => const {});
  bool isDone(String key) => row(key)['done'] == true;
}

/// One call per screen action, all through the One Local server (`/api/setup/*`). The server and the database check every rule.
class SetupApi {
  SetupApi({http.Client? client, String? baseUrl, String? Function()? accessToken})
      : _http = client ?? http.Client(),
        _token = accessToken ?? (() => Supabase.instance.client.auth.currentSession?.accessToken),
        _base = (baseUrl ?? const String.fromEnvironment('PARTNER_API_BASE_URL')).replaceAll(RegExp(r'/+$'), '');

  final http.Client _http;
  final String? Function() _token;
  final String _base;

  Future<Map<String, dynamic>> _send(String method, String path, [Object? body]) async {
    final token = _token();
    if (token == null) throw const PartnerApiException(401, 'Sign in to continue.');
    final uri = Uri.parse('$_base/api/setup$path');
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

  Future<SetupState> _state(String method, String path, [Object? body]) async => SetupState(await _send(method, path, body));

  Future<SetupState> get() => _state('GET', '/state');
  Future<SetupState> confirmPlan(String? planCode) => _state('PUT', '/plan', {'plan_code': planCode});
  Future<SetupState> savePayment(Map<String, dynamic> body) => _state('PUT', '/payment', body);
  Future<SetupState> saveTax(Map<String, dynamic> body) => _state('PUT', '/tax', body);
  Future<SetupState> registerPos(Map<String, dynamic> body) => _state('PUT', '/pos', body);
  Future<SetupState> inviteStaff(Map<String, dynamic> body) => _state('POST', '/staff', body);
  Future<SetupState> addItem(Map<String, dynamic> body) => _state('POST', '/items', body);
  Future<SetupState> saveListing(Map<String, dynamic> body) => _state('PUT', '/listing', body);
  Future<SetupState> saveFulfilment(Map<String, dynamic> body) => _state('PUT', '/fulfilment', body);
  Future<SetupState> tourSeen(int step) => _state('POST', '/tour', {'step': step});
  Future<SetupState> complete() => _state('POST', '/complete');

  /// Two steps: ask for a private slot, send the bytes to it, then confirm so the server attaches the image.
  Future<SetupState> uploadImage({required String kind, required Uint8List bytes, required String contentType}) async {
    final slot = await _send('POST', '/images/upload', {'kind': kind, 'content_type': contentType, 'size': bytes.length});
    final put = await _http.put(Uri.parse(slot['upload_url'] as String), headers: {'Content-Type': contentType, 'x-upsert': 'true'}, body: bytes).timeout(const Duration(seconds: 120));
    if (put.statusCode < 200 || put.statusCode >= 300) throw const PartnerApiException(502, 'The upload did not finish. Please try again.');
    return _state('POST', '/images', {'kind': kind, 'path': slot['path'], 'content_type': contentType, 'size': bytes.length});
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
