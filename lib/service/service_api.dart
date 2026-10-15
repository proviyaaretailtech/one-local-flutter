import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/partner_api.dart';

/// Error from the service endpoints: the server's own message plus its code (`version_conflict` = changed on another device).
class ServiceApiException extends PartnerApiException {
  const ServiceApiException(super.status, super.message, this.code);
  final String? code;
  bool get stale => code == 'version_conflict';
}

Map<String, dynamic> _map(Object? v) => (v as Map?)?.cast<String, dynamic>() ?? const {};
List<Map<String, dynamic>> _list(Object? v) => ((v as List?) ?? const []).map(_map).toList();
String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();
num _n(Object? v) => num.tryParse('${v ?? 0}') ?? 0;

/// One appointment as the server describes it. The status, labels, bill and allowed actions all come from the server; the app only draws them.
class AppointmentView {
  AppointmentView(this.raw);
  final Map<String, dynamic> raw;
  String get id => _s(raw, 'id');
  String get displayNo => _s(raw, 'display_no');
  String get status => _s(raw, 'status');
  String get statusLabel => _s(raw, 'status_label');
  String get tone => _s(raw, 'tone');
  String get timeLabel => _s(raw, 'time_label');
  String get title => _s(raw, 'title');
  String get customer => raw['customer'] is Map ? _s(_map(raw['customer']), 'name') : _s(raw, 'customer');
  String get provider => raw['provider'] is Map ? _s(_map(raw['provider']), 'name') : _s(raw, 'provider');
  String? get resource => raw['resource'] is Map ? _s(_map(raw['resource']), 'name') : (raw['resource'] as String?);
  int get version => (raw['version'] as num?)?.toInt() ?? 1;
  Map<String, dynamic> get bill => _map(raw['bill']);
  List<String> get actions => ((raw['actions'] as List?) ?? const []).map((e) => '$e').toList();
}

/// One day or week of the calendar (`GET /calendar`).
class CalendarData {
  CalendarData(this.raw);
  final Map<String, dynamic> raw;
  String get dateLabel => _s(raw, 'date_label');
  String get locationName => _s(_map(raw['location']), 'name');
  String get city => _s(_map(raw['location']), 'city');
  String get business => _s(raw, 'business');
  int get appointments => (_map(raw['counts'])['appointments'] as num?)?.toInt() ?? 0;
  int get availableSlots => (_map(raw['counts'])['available_slots'] as num?)?.toInt() ?? 0;
  int get providerCount => (_map(raw['counts'])['providers'] as num?)?.toInt() ?? 0;
  List<Map<String, dynamic>> get week => _list(raw['week']);
  List<Map<String, dynamic>> get providers => _list(raw['providers']);
  List<AppointmentView> get items => _list(raw['appointments']).map(AppointmentView.new).toList();
}

/// A service the booking form can pick (`GET /catalogue`).
class ServiceOption {
  ServiceOption(this.raw);
  final Map<String, dynamic> raw;
  String get id => _s(raw, 'id');
  String get name => _s(raw, 'name');
  num get price => _n(raw['price']);
  int get durationMin => (raw['duration_min'] as num?)?.toInt() ?? 0;
  List<Map<String, dynamic>> get addons => _list(raw['addons']);
  List<String> get staffIds => ((raw['staff_ids'] as List?) ?? const []).map((e) => '$e').toList();
}

class ProviderOption {
  ProviderOption(this.raw);
  final Map<String, dynamic> raw;
  String get id => _s(raw, 'staff_id');
  String get name => _s(raw, 'name');
  String get title => _s(raw, 'title');
  String get locationId => _s(raw, 'location_id');
}

class Catalogue {
  Catalogue(this.raw);
  final Map<String, dynamic> raw;
  List<ServiceOption> get services => _list(raw['services']).map(ServiceOption.new).toList();
  List<ProviderOption> get providers => _list(raw['providers']).map(ProviderOption.new).toList();
  List<Map<String, dynamic>> get resources => _list(raw['resources']);
  num get deposit => _n(_map(raw['settings'])['deposit_amount']);
  int get freeCancelHours => (_map(raw['settings'])['free_cancel_hours'] as num?)?.toInt() ?? 12;
}

/// Server totals for a booking that is not made yet (`POST /quote`).
class ServiceQuote {
  ServiceQuote(this.raw);
  final Map<String, dynamic> raw;
  num get subtotal => _n(raw['subtotal']);
  num get gstPct => _n(raw['gst_pct']);
  num get gst => _n(raw['gst_amount']);
  num get roundOff => _n(raw['round_off']);
  num get total => _n(raw['total']);
  num get deposit => _n(raw['deposit']);
  num get dueAtStudio => _n(raw['due_at_studio']);
  int get durationMin => (raw['duration_min'] as num?)?.toInt() ?? 0;
  int get bufferMin => (raw['buffer_min'] as num?)?.toInt() ?? 0;
  int get freeCancelHours => (raw['free_cancel_hours'] as num?)?.toInt() ?? 12;
  List<Map<String, dynamic>> get lines => _list(raw['lines']);
}

class SlotProvider {
  SlotProvider(this.raw);
  final Map<String, dynamic> raw;
  String get id => _s(raw, 'staff_id');
  String get name => _s(raw, 'name');
  List<Map<String, dynamic>> get slots => _list(raw['slots']);
}

/// Calls One Local's server (`/api/partner/service/*`). The Supabase session token is the only credential; the database checks the business, the
/// role, the time and every rule again. Writes carry an Idempotency-Key so a retried tap never books twice.
/// The server routes are not written yet: the contract is in specs/pos-section-i/spec.md.
class ServiceApi {
  ServiceApi({http.Client? client, String? baseUrl, String? Function()? accessToken})
      : _http = client ?? http.Client(),
        _token = accessToken ?? (() => Supabase.instance.client.auth.currentSession?.accessToken),
        _base = (baseUrl ?? const String.fromEnvironment('PARTNER_API_BASE_URL')).replaceAll(RegExp(r'/+$'), '');

  final http.Client _http;
  final String? Function() _token;
  final String _base;
  static final _rand = Random.secure();

  /// A fresh key for one intent (one tap). Keep it and send it again when retrying that same tap.
  static String newKey() => 'svc-${List.generate(16, (_) => _rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  Future<Map<String, dynamic>> _send(String method, String path, {Object? body, String? key, Map<String, String>? query}) async {
    final token = _token();
    if (token == null) throw const PartnerApiException(401, 'Sign in to continue.');
    var uri = Uri.parse('$_base/api/partner/service$path');
    if (query != null && query.isNotEmpty) uri = uri.replace(queryParameters: query);
    final headers = {
      'Authorization': 'Bearer $token',
      if (body != null) 'Content-Type': 'application/json',
      'Idempotency-Key': ?key,
    };
    final res = await (method == 'GET' ? _http.get(uri, headers: headers) : _http.post(uri, headers: headers, body: body == null ? null : jsonEncode(body)))
        .timeout(const Duration(seconds: 30));
    final decoded = res.body.isEmpty ? <String, dynamic>{} : jsonDecode(res.body);
    final map = decoded is Map ? decoded.cast<String, dynamic>() : <String, dynamic>{};
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ServiceApiException(res.statusCode, (map['detail'] as String?) ?? 'Something went wrong. Please try again.', map['code'] as String?);
    }
    return map;
  }

  Future<Catalogue> catalogue({String? locationId}) async =>
      Catalogue(await _send('GET', '/catalogue', query: {'location_id': ?locationId}));

  Future<CalendarData> calendar({required String date, String view = 'day', String? locationId, String? staffId}) async =>
      CalendarData(await _send('GET', '/calendar', query: {'date': date, 'view': view, 'location_id': ?locationId, 'staff_id': ?staffId}));

  Future<ServiceQuote> quote({required String serviceId, List<String> addonIds = const [], String? staffId}) async =>
      ServiceQuote(await _send('POST', '/quote', body: {'service_id': serviceId, 'addon_ids': addonIds, 'staff_id': ?staffId}));

  Future<List<SlotProvider>> slots({required String date, required String serviceId, List<String> addonIds = const [], String? staffId}) async {
    final r = await _send('POST', '/slots', body: {'date': date, 'service_id': serviceId, 'addon_ids': addonIds, 'staff_id': ?staffId});
    return _list(r['providers']).map(SlotProvider.new).toList();
  }

  /// Books the visit: the order is placed and, when [depositMethod] is given, the advance is taken. Without it the booking waits for its advance.
  Future<AppointmentView> book({
    required String key,
    required String customerName,
    String? customerPhone,
    required String serviceId,
    List<String> addonIds = const [],
    required String staffId,
    String? resourceId,
    required String startsAt,
    String? depositMethod,
    num? tendered,
  }) async =>
      AppointmentView(await _send('POST', '/appointments', key: key, body: {
        'customer_name': customerName,
        if (customerPhone != null && customerPhone.isNotEmpty) 'customer_phone': customerPhone,
        'service_id': serviceId,
        'addon_ids': addonIds,
        'staff_id': staffId,
        'resource_id': ?resourceId,
        'starts_at': startsAt,
        if (depositMethod != null) 'deposit': {'method': depositMethod, 'tendered': ?tendered},
      }));

  Future<List<AppointmentView>> history({String filter = 'all', String q = '', String? before}) async {
    final r = await _send('GET', '/appointments', query: {'filter': filter, if (q.trim().isNotEmpty) 'q': q.trim(), 'before': ?before});
    return _list(r['appointments']).map(AppointmentView.new).toList();
  }

  Future<AppointmentView> get(String id) async => AppointmentView(await _send('GET', '/appointments/$id'));

  Future<AppointmentView> act(String id, String action, {required int version, String? key, Map<String, Object?> extra = const {}}) async =>
      AppointmentView(await _send('POST', '/appointments/$id/act', key: key ?? newKey(), body: {'action': action, 'expected_version': version, ...extra}));

  Future<AppointmentView> bill(String id, {required String method, num? tendered, required int version, required String key}) async =>
      AppointmentView(await _send('POST', '/appointments/$id/bill', key: key, body: {'method': method, 'tendered': ?tendered, 'expected_version': version}));
}
