import 'package:flutter/widgets.dart' show BuildContext;
import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';
import '../auth/partner_api.dart';
import '../onboarding/document_picker.dart';

/// The Settings page as the server describes it (`pos_settings_get`). Read-only: every value comes from the database and the app only draws it.
/// Bank and tax numbers are never part of it: only holder, bank name, last four digits, IFSC and the status.
class SettingsState {
  SettingsState(this.raw);
  final Map<String, dynamic> raw;

  Map<String, dynamic> _m(String k) => (raw[k] as Map?)?.cast<String, dynamic>() ?? const {};
  String? _s(Map<String, dynamic> m, String k) {
    final v = m[k];
    return v == null || v.toString().isEmpty ? null : v.toString();
  }

  bool get canEdit => raw['can_edit'] == true;
  bool get bankVisible => raw['bank_visible'] == true;
  String get businessName => _s(_m('organization'), 'name') ?? '';

  String? get opensAt => _s(_m('hours'), 'opens_at');
  String? get closesAt => _s(_m('hours'), 'closes_at');
  int? get prepMinutes => (_m('readiness')['prep_minutes'] as num?)?.toInt();
  String? get helpName => _s(_m('help'), 'name');
  String? get helpPhone => _s(_m('help'), 'phone');
  String? get helpInfo => _s(_m('help'), 'info');
  String? get ownerName => _s(_m('owner'), 'name');
  String? get ownerPhone => _s(_m('owner'), 'phone');
  String? get staffPhone => raw['staff_phone']?.toString();
  int get activeUsers => ((_m('users')['active']) as num?)?.toInt() ?? 0;
  bool get pickup => raw['pickup'] == true;
  bool get qrCheckout => raw['qr_checkout'] == true;
  int get documentCount => ((_m('documents')['count']) as num?)?.toInt() ?? 0;
  bool get qrUploaded => _m('qr')['uploaded'] == true;
  String? get address => _s(_m('location'), 'address');
  String get language => raw['language']?.toString() ?? 'en';
  int get openRequests => ((_m('support')['open']) as num?)?.toInt() ?? 0;

  /// `not_added`, `unverified` or `verified`; null when this person may not see bank details.
  String? get bankStatus => bankVisible ? _s(_m('bank'), 'status') : null;
  String? get bankHolder => _s(_m('bank'), 'holder_name');
  String? get bankName => _s(_m('bank'), 'bank_name');
  String? get bankLast4 => _s(_m('bank'), 'last4');
  String? get bankIfsc => _s(_m('bank'), 'ifsc');
}

/// One call per screen action, all through the one `/rpc/<name>` door ([RpcClient]). The database checks every rule and answers with the sentence.
class SettingsApi {
  SettingsApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc})
      : _http = client ?? http.Client(),
        _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);

  final http.Client _http;
  final RpcClient _rpc;

  Future<SettingsState> _state(String fn, [Map<String, dynamic> args = const {}]) async => SettingsState(await _rpc.callMap(fn, args));

  Future<SettingsState> get() => _state('pos_settings_get');
  Future<SettingsState> saveHours(String opensAt, String closesAt) => _state('pos_settings_save_hours', {'opens_at': opensAt, 'closes_at': closesAt});
  Future<SettingsState> saveReadiness(int minutes) => _state('pos_settings_save_readiness', {'prep_minutes': minutes});
  Future<SettingsState> saveHelp({required String name, required String phone, String? info}) => _state('pos_settings_save_help', {'name': name, 'phone': phone, 'info': info ?? ''});
  Future<SettingsState> saveOwner({required String name, required String phone}) => _state('pos_settings_save_owner', {'name': name, 'phone': phone});
  Future<SettingsState> saveStaffPhone(String phone) => _state('pos_settings_save_staff_phone', {'phone': phone});
  Future<SettingsState> setPickup(bool on) => _state('pos_settings_set_pickup', {'enabled': on});
  Future<SettingsState> setQrCheckout(bool on) => _state('pos_settings_set_qr_checkout', {'enabled': on});
  Future<SettingsState> saveLocation(String address) => _state('pos_settings_save_location', {'address': address});
  Future<SettingsState> saveLanguage(String code) => _state('pos_settings_save_language', {'language': code});

  /// Bank details go through the setup handler that holds the encryption key. An empty account number keeps the saved account.
  /// The status stays "unverified": marking an account verified is done by operations, never by the app.
  Future<void> saveBank({required String holder, String? accountNumber, String? ifsc}) =>
      _rpc.call('partner_setup_save_payment', {'holder_name': holder, if ((accountNumber ?? '').isNotEmpty) 'account_number': accountNumber, if ((ifsc ?? '').isNotEmpty) 'ifsc': ifsc});

  Future<List<Map<String, dynamic>>> documents() async {
    final r = await _rpc.callMap('pos_settings_documents');
    return ((r['documents'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
  }

  Future<void> removeDocument(String id) => _rpc.call('pos_settings_document_remove', {'id': id});
  Future<void> removeQr() => _rpc.call('pos_settings_remove_qr');

  /// Three steps, same as the setup images: ask for a private slot, send the bytes to it, confirm so the database attaches the file.
  /// [details] (name, doc_type, doc_no, expiry_date) only matter for a document. Returns the server's answer (for feedback: the stored path).
  Future<Map<String, dynamic>> uploadFile({required String kind, required PickedDocument file, Map<String, dynamic> details = const {}}) async {
    final slot = await _rpc.callMap('pos_settings_file_slot', {'kind': kind, 'content_type': file.contentType, 'size': file.bytes.length});
    final put = await _http.put(Uri.parse(slot['upload_url'] as String), headers: {'Content-Type': file.contentType, 'x-upsert': 'true'}, body: file.bytes).timeout(const Duration(seconds: 120));
    if (put.statusCode < 200 || put.statusCode >= 300) throw const PartnerApiException(502, 'The upload did not finish. Please try again.');
    final res = await _rpc.callMap('pos_settings_file_attach', {'kind': kind, 'content_type': file.contentType, 'size': file.bytes.length, 'path': slot['path'], ...details});
    return {...res, 'path': slot['path']};
  }

  /// A short-lived link to the store QR or one document.
  Future<String> fileLink(String kind, {String? id}) async => (await _rpc.callMap('pos_settings_file_link', {'kind': kind, 'id': ?id}))['url'] as String;

  Future<Map<String, dynamic>> help() => _rpc.callMap('pos_help_content');
  Future<Map<String, dynamic>> supportList() => _rpc.callMap('pos_support_list');
  Future<Map<String, dynamic>> supportCreate({required String message, String kind = 'support', String? topic, String? attachmentPath, required String idempotencyKey}) =>
      _rpc.callMap('pos_support_create', {'kind': kind, 'topic': ?topic, 'message': message, 'attachment_path': ?attachmentPath}, idempotencyKey);
}

/// What the screens may do beyond the server: pick a time, pick a file, open a link. Tests replace these.
class SettingsEnv {
  SettingsEnv({SettingsApi? api, this.pickTime, this.picker = const DevicePicker(), this.onOpenLink, this.newKey}) : api = api ?? SettingsApi();
  final SettingsApi api;
  /// Asks for a time and answers "HH:MM"; null means the person backed out. Default: the system time picker.
  final Future<String?> Function(BuildContext context, String? current)? pickTime;
  final DocumentPicker picker;
  final void Function(String url)? onOpenLink;
  /// A fresh key per support request, so a retry never makes a second one.
  final String Function()? newKey;
}

/// The app's three languages (founder, 26 Oct 2026); the database accepts only these codes.
const kLanguages = <String, String>{'en': 'English', 'hi': 'हिन्दी (Hindi)', 'hi-en': 'Hinglish'};

/// "09:00" -> "9:00 AM".
String clock12(String? hhmm) {
  if (hhmm == null || !RegExp(r'^\d{2}:\d{2}$').hasMatch(hhmm)) return 'Not set';
  final h = int.parse(hhmm.substring(0, 2)), m = hhmm.substring(3);
  final h12 = h % 12 == 0 ? 12 : h % 12;
  return '$h12:$m ${h < 12 ? 'AM' : 'PM'}';
}
