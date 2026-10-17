import 'dart:math';

import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';
import '../auth/partner_api.dart';

/// Error from the service functions: the server's own message plus its code (`version_conflict` = changed on another device).
class ServiceApiException extends PartnerApiException {
  const ServiceApiException(super.status, super.message, this.code);
  final String? code;
  bool get stale => code == 'version_conflict';
}

Map<String, dynamic> _map(Object? v) => (v as Map?)?.cast<String, dynamic>() ?? const {};
List<Map<String, dynamic>> _list(Object? v) => ((v as List?) ?? const []).whereType<Map>().map(_map).toList();
String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();
num _n(Object? v) => v is num ? v : (num.tryParse('${v ?? 0}') ?? 0);

/// A server answer read as typed fields. Every number, label, status and permission comes from the server; the app only draws them.
class SvcData {
  const SvcData(this.raw);
  final Map<String, dynamic> raw;
  String s(String k) => _s(raw, k);
  String? so(String k) => raw[k] == null ? null : '${raw[k]}';
  num n(String k) => _n(raw[k]);
  int i(String k) => _n(raw[k]).toInt();
  bool b(String k) => raw[k] == true;
  SvcData m(String k) => SvcData(_map(raw[k]));
  List<SvcData> l(String k) => _list(raw[k]).map(SvcData.new).toList();
  List<String> ls(String k) => ((raw[k] as List?) ?? const []).map((e) => '$e').toList();
}

/// One appointment as the server describes it. The status, labels, bill and allowed actions all come from the server; the app only draws them.
class AppointmentView extends SvcData {
  const AppointmentView(super.raw);
  String get id => s('id');
  String get displayNo => s('display_no');
  String get status => s('status');
  String get statusLabel => s('status_label');
  String get tone => s('tone');
  String get timeLabel => s('time_label');
  String get dateLabel => s('date_label');
  String get title => s('title');
  String get fulfilment => raw['fulfilment'] == null ? 'appointment' : s('fulfilment');
  bool get onLocation => fulfilment == 'on_location';
  String get customer => raw['customer'] is Map ? _s(_map(raw['customer']), 'name') : s('customer');
  String get customerPhone => raw['customer'] is Map ? _s(_map(raw['customer']), 'phone') : '';
  String get provider => raw['provider'] is Map ? _s(_map(raw['provider']), 'name') : s('provider');
  String? get resource => raw['resource'] is Map ? _s(_map(raw['resource']), 'name') : (raw['resource'] as String?);
  String get location => m('location').s('name');
  int get version => raw['version'] == null ? 1 : i('version');
  int get durationMin => i('duration_min');
  int get bufferMin => i('buffer_min');
  Map<String, dynamic> get bill => _map(raw['bill']);
  SvcData get billData => m('bill');
  List<SvcData> get lines => l('lines');
  List<SvcData> get extras => l('extras');
  List<SvcData> get checklist => l('checklist');
  List<SvcData> get payments => l('payments');
  List<SvcData> get events => l('events');
  List<SvcData> get credits => l('credits');
  String? get arrivalCode => so('arrival_code');
  List<String> get actions => ls('actions');
  bool can(String action) => actions.contains(action);
  bool get replayed => b('replayed');
}

/// One day or week of the calendar (`svc_calendar`).
class CalendarData {
  CalendarData(this.raw);
  final Map<String, dynamic> raw;
  String get dateLabel => _s(raw, 'date_label');
  String get locationName => _s(_map(raw['location']), 'name');
  String get city => _s(_map(raw['location']), 'city');
  String get business => _s(raw, 'business');
  String? get closed => raw['closed'] as String?;
  int get appointments => (_map(raw['counts'])['appointments'] as num?)?.toInt() ?? 0;
  int get availableSlots => (_map(raw['counts'])['available_slots'] as num?)?.toInt() ?? 0;
  int get providerCount => (_map(raw['counts'])['providers'] as num?)?.toInt() ?? 0;
  List<Map<String, dynamic>> get week => _list(raw['week']);
  List<Map<String, dynamic>> get providers => _list(raw['providers']);
  List<AppointmentView> get items => _list(raw['appointments']).map(AppointmentView.new).toList();
}

/// A service the booking form can pick (`svc_catalogue`).
class ServiceOption {
  ServiceOption(this.raw);
  final Map<String, dynamic> raw;
  String get id => _s(raw, 'id');
  String get name => _s(raw, 'name');
  num get price => _n(raw['price']);
  int get durationMin => (raw['duration_min'] as num?)?.toInt() ?? 0;
  String get fulfilment => raw['fulfilment'] == null ? 'appointment' : _s(raw, 'fulfilment');
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
  /// Catalogue items that can be added to a visit as materials or charges (not services, not packages).
  List<SvcData> get extras => _list(raw['extras']).map(SvcData.new).toList();
  num get deposit => _n(_map(raw['settings'])['deposit_amount']);
  int get freeCancelHours => (_map(raw['settings'])['free_cancel_hours'] as num?)?.toInt() ?? 12;
}

/// Server totals for a booking that is not made yet (`svc_quote`).
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

/// Frame 108: the filtered list plus its count (`svc_history`).
class HistoryData extends SvcData {
  const HistoryData(super.raw);
  int get total => i('total');
  String get monthLabel => s('month_label');
  List<AppointmentView> get items => _list(raw['appointments']).map(AppointmentView.new).toList();
  List<SvcData> get providers => l('providers');
}

/// Frame 83 (`svc_service_list`).
class ServiceListData extends SvcData {
  const ServiceListData(super.raw);
  int get total => i('total');
  int get shown => i('shown');
  List<String> get categories => ls('categories');
  int count(String status) => m('counts').i(status);
  List<SvcData> get services => l('services');
}

/// Frame 84 (`svc_service_detail`).
class ServiceDetail extends SvcData {
  const ServiceDetail(super.raw);
  String get id => s('id');
  String get name => s('name');
  num get price => n('price');
  bool get active => s('status') == 'active';
  String get fulfilment => s('fulfilment');
  List<SvcData> get staff => l('staff');
  List<SvcData> get addons => l('addons');
  List<String> get locations => ls('locations');
  List<String> get checklist => ls('checklist');
  bool get canEdit => b('can_edit');
}

/// Frame 87 (`svc_staff_list`).
class StaffData extends SvcData {
  const StaffData(super.raw);
  int count(String filter) => m('counts').i(filter);
  List<SvcData> get providers => l('providers');
  List<SvcData> get candidates => l('candidates');
  List<SvcData> get services => l('services');
  List<SvcData> get locations => l('locations');
  bool get canEdit => b('can_edit');
}

/// Frame 89 (`svc_schedule`).
class ScheduleData extends SvcData {
  const ScheduleData(super.raw);
  String get locationId => m('location').s('id');
  String get locationName => m('location').s('name');
  List<SvcData> get hours => l('hours');
  List<SvcData> get hoursRows => l('hours_rows');
  List<SvcData> get providers => l('providers');
  int get availableToday => i('available_today');
  SvcData get slot => m('slot');
  List<SvcData> get exceptions => l('exceptions');
  bool get canEdit => b('can_edit');
}

/// Frames 85 and 86 (`svc_plan_list`).
class PlanListData extends SvcData {
  const PlanListData(super.raw);
  List<SvcData> get plans => l('plans');
  int count(String status) => m('counts').i(status);
  int get activeMembers => i('active_members');
  int get joinedThisMonth => i('joined_this_month');
  num get monthlyRecurring => n('monthly_recurring');
  List<SvcData> get services => l('services');
  bool get canEdit => b('can_edit');
}

/// A package or membership sold to one customer, with the credits left.
class EntitlementView extends SvcData {
  const EntitlementView(super.raw);
  String get id => s('id');
  String get name => s('name');
  String get kind => s('kind');
  List<SvcData> get credits => l('credits');
}

/// The Service POS functions, all through the one generic endpoint (`POST /rpc/<name>`, lib/api/rpc_client.dart). The Supabase session
/// token is the only credential; the database checks the business, the role, the time and every rule again. Writes carry an
/// Idempotency-Key so a retried tap never books, charges or saves twice.
class ServiceApi {
  ServiceApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc})
      : _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);

  final RpcClient _rpc;
  static final _rand = Random.secure();

  /// A fresh key for one intent (one tap). Keep it and send it again when retrying that same tap.
  static String newKey() => 'svc-${List.generate(16, (_) => _rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  Future<Map<String, dynamic>> _call(String fn, Map<String, Object?> args, {String? key}) async {
    final body = <String, dynamic>{...args}..removeWhere((_, v) => v == null);
    try {
      return await _rpc.callMap(fn, body, key);
    } on RpcException catch (e) {
      throw ServiceApiException(e.status, e.message, e.code);
    }
  }

  Future<Catalogue> catalogue({String? locationId}) async => Catalogue(await _call('svc_catalogue', {'location_id': locationId}));

  Future<CalendarData> calendar({required String date, String view = 'day', String? locationId, String? staffId}) async =>
      CalendarData(await _call('svc_calendar', {'date': date, 'view': view, 'location_id': locationId, 'staff_id': staffId}));

  Future<ServiceQuote> quote({required String serviceId, List<String> addonIds = const [], String? staffId}) async =>
      ServiceQuote(await _call('svc_quote', {'service_id': serviceId, 'addon_ids': addonIds, 'staff_id': staffId}));

  Future<List<SlotProvider>> slots({required String date, required String serviceId, List<String> addonIds = const [], String? staffId}) async {
    final r = await _call('svc_slots', {'date': date, 'service_id': serviceId, 'addon_ids': addonIds, 'staff_id': staffId});
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
    String? entitlementId,
    String? serviceAddress,
    String? accessNote,
  }) async =>
      AppointmentView(await _call('svc_book', key: key, {
        'customer_name': customerName,
        if (customerPhone != null && customerPhone.isNotEmpty) 'customer_phone': customerPhone,
        'service_id': serviceId,
        'addon_ids': addonIds,
        'staff_id': staffId,
        'resource_id': resourceId,
        'starts_at': startsAt,
        'entitlement_id': entitlementId,
        if (serviceAddress != null && serviceAddress.trim().isNotEmpty) 'service_address': serviceAddress.trim(),
        if (accessNote != null && accessNote.trim().isNotEmpty) 'access_note': accessNote.trim(),
        if (depositMethod != null) 'deposit': {'method': depositMethod, 'tendered': ?tendered},
      }));

  Future<HistoryData> history({String filter = 'all', String q = '', String? before, String? fulfilment, String? staffId, String period = 'all'}) async =>
      HistoryData(await _call('svc_history', {
        'filter': filter,
        if (q.trim().isNotEmpty) 'q': q.trim(),
        'before': before,
        'fulfilment': fulfilment,
        'staff_id': staffId,
        if (period != 'all') 'period': period,
      }));

  Future<AppointmentView> get(String id) async => AppointmentView(await _call('svc_appointment_view', {'id': id}));

  Future<AppointmentView> act(String id, String action, {required int version, String? key, Map<String, Object?> extra = const {}}) async =>
      AppointmentView(await _call('svc_appointment_act', key: key ?? newKey(), {'id': id, 'action': action, 'expected_version': version, ...extra}));

  Future<AppointmentView> bill(String id, {String? method, num? tendered, required int version, required String key}) async =>
      AppointmentView(await _call('svc_bill', key: key, {'id': id, 'method': method, 'tendered': tendered, 'expected_version': version}));

  /// During the visit: ticks checklist items, keeps the provider's notes, adds customer-approved materials, or asks for the arrival confirmation.
  Future<AppointmentView> jobUpdate(String id,
          {required int version, required String key, List<String>? done, String? providerNotes, List<Map<String, Object?>>? extras, bool requestConfirmation = false}) async =>
      AppointmentView(await _call('svc_job_update', key: key, {
        'id': id,
        'expected_version': version,
        'done': done,
        'provider_notes': providerNotes,
        'extras': extras,
        if (requestConfirmation) 'request_confirmation': true,
      }));

  Future<ServiceListData> serviceList({String q = '', String? category, String? type, String? status}) async =>
      ServiceListData(await _call('svc_service_list', {if (q.trim().isNotEmpty) 'q': q.trim(), 'category': category, 'type': type, 'status': status}));

  Future<ServiceDetail> serviceDetail(String id) async => ServiceDetail(await _call('svc_service_detail', {'id': id}));

  Future<ServiceDetail> saveService(Map<String, Object?> fields, {required String key}) async => ServiceDetail(await _call('svc_service_save', fields, key: key));

  Future<StaffData> staff({String q = '', String filter = 'all'}) async =>
      StaffData(await _call('svc_staff_list', {if (q.trim().isNotEmpty) 'q': q.trim(), 'filter': filter}));

  Future<StaffData> saveProvider(Map<String, Object?> fields, {required String key}) async => StaffData(await _call('svc_provider_save', fields, key: key));

  Future<ScheduleData> schedule({String? locationId}) async => ScheduleData(await _call('svc_schedule', {'location_id': locationId}));

  Future<ScheduleData> saveSchedule(Map<String, Object?> fields, {required String key}) async => ScheduleData(await _call('svc_schedule_save', fields, key: key));

  Future<PlanListData> plans(String kind, {String q = '', String? status}) async =>
      PlanListData(await _call('svc_plan_list', {'kind': kind, if (q.trim().isNotEmpty) 'q': q.trim(), 'status': status}));

  Future<SvcData> savePlan(Map<String, Object?> fields, {required String key}) async => SvcData(await _call('svc_plan_save', fields, key: key));

  /// Sells a package or membership to one customer: an ordinary order paid in full now, then the credits.
  Future<EntitlementView> sell({required String key, required String planId, required String customerName, required String customerPhone, required String method, num? tendered}) async =>
      EntitlementView(await _call('svc_entitlement_sell', key: key,
          {'plan_id': planId, 'customer_name': customerName, 'customer_phone': customerPhone, 'method': method, 'tendered': tendered}));

  Future<List<EntitlementView>> entitlementsFor(String phone) async =>
      _list((await _call('svc_entitlements_for', {'customer_phone': phone}))['entitlements']).map(EntitlementView.new).toList();
}
