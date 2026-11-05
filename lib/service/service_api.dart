import 'dart:math';

import 'package:http/http.dart' as http;

import '../api/app_env.dart';
import '../api/rpc_client.dart';
import '../auth/partner_api.dart';
import '../onboarding/document_picker.dart' show PickedDocument;

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
  String get customerPhone => raw['customer'] is Map ? _s(_map(raw['customer']), 'phone') : s('customer_phone');
  String get serviceAddress => s('service_address');
  /// Calendar rows (svc_calendar, 2 Nov 2026): the order total and what is paid so far; the local day it starts.
  num get amount => n('amount');
  num get paid => n('paid');
  String get day => s('date');
  /// Booked online in the customer app ('app') or logged offline in the POS ('pos'), 2 Nov 2026.
  bool get online => s('source') == 'app';
  DateTime? get startsAt => DateTime.tryParse(s('starts_at'))?.toLocal();
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
  /// Bookings and job visits in the shown range logged offline (POS) and booked online (customer app).
  int get offlineCount => (_map(raw['counts'])['offline'] as num?)?.toInt() ?? 0;
  int get onlineCount => (_map(raw['counts'])['online'] as num?)?.toInt() ?? 0;
  List<Map<String, dynamic>> get week => _list(raw['week']);
  /// View 'month': every day of the month with its booking count (isodow 1 = Monday).
  List<Map<String, dynamic>> get month => _list(raw['month']);
  String get monthLabel => _s(raw, 'month_label');
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

  /// The listing has rules or limits about who is coming, or prices per person (4 Nov 2026): ask before booking.
  bool get partyAsks => raw['party_asks'] == true;

  /// Why this party cannot book, in the listing's words ("Not allowed: Under 8"); null when it can.
  String? get notAllowed => raw['not_allowed'] as String?;

  /// A rule says this booking needs the owner's approval.
  String? get needsApproval => raw['needs_approval'] as String?;
}

class SlotProvider {
  SlotProvider(this.raw);
  final Map<String, dynamic> raw;
  String get id => _s(raw, 'staff_id');
  String get name => _s(raw, 'name');
  List<Map<String, dynamic>> get slots => _list(raw['slots']);
}

/// The service business home screen (`svc_dashboard`): today's visits, money, free slots, what needs attention, the next visits.
class ServiceDashboardData extends SvcData {
  const ServiceDashboardData(super.raw);
  String get business => s('business');
  String get locationName => m('location').s('name');
  String get dateLabel => s('date_label');
  String? get closed => so('closed');
  SvcData get today => m('today');
  SvcData get money => m('money');
  SvcData get attention => m('attention');
  SvcData get providers => m('providers');
  SvcData get month => m('month');
  SvcData get plans => m('plans');
  int get availableSlots => i('available_slots');
  /// The people free right now, by name (founder, 2 Nov 2026: the Free slots tile says who).
  List<String> get freeNow => ls('free_now');
  /// Today's bookings and job visits: logged offline in the POS and booked online in the customer app.
  int get todayOffline => m('today_sources').i('offline');
  int get todayOnline => m('today_sources').i('online');
  List<AppointmentView> get nextUp => l('next_up').map((e) => AppointmentView(e.raw)).toList();
  List<SvcData> get topServices => l('top_services');
}


/// Free slots today (`svc_free_slots`, 2 Nov 2026): for each bookable person, whether they are free now, busy (till when) or off, and their
/// free start times.
class FreeSlotsData extends SvcData {
  const FreeSlotsData(super.raw);
  String get dateLabel => s('date_label');
  String? get closed => so('closed');
  int get total => i('total');
  int get slotMinutes => i('slot_minutes');
  List<String> get freeNow => ls('free_now');
  List<SvcData> get people => l('people');
}

/// Money from services (`svc_money_split`): taken today and this month, net of refunds, by bookings, jobs, bills made here and packages, by
/// offline / online and by how it was paid; and what customers still owe.
class MoneySplitData extends SvcData {
  const MoneySplitData(super.raw);
  SvcData get today => m('today');
  SvcData get month => m('month');
  num get due => n('due');
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

/// A saved template (`svc_templates`, 3 Nov 2026): what a service needs and its rules, under a name such as "Manicure".
class ServiceTemplate extends SvcData {
  const ServiceTemplate(super.raw);
  String get id => s('id');
  String get name => s('name');
  String? get category => so('category');
  String? get subcategory => so('subcategory');
  int? get durationMin => raw['duration_min'] == null ? null : i('duration_min');
  List<Map<String, dynamic>> get requirements => _list(raw['requirements']);
  List<Map<String, dynamic>> get rules => _list(raw['rules']);
  String get notes => s('notes');
  int get usedBy => i('used_by');
}

/// The business's templates (`svc_template_list`).
class TemplateListData extends SvcData {
  const TemplateListData(super.raw);
  bool get canEdit => b('can_edit');
  int get total => i('total');
  List<ServiceTemplate> get templates => l('templates').map((t) => ServiceTemplate(t.raw)).toList();
  ServiceTemplate? get saved => raw['saved'] == null ? null : ServiceTemplate(m('saved').raw);
  int get added => i('added');
  int get updated => i('updated');
}

/// A listing form's answers and what it picks from (`svc_listing_view`, 3 Nov 2026).
class ListingData extends SvcData {
  const ListingData(super.raw);
  String? get category => so('category');
  Map<String, dynamic> get listing => (raw['listing'] as Map?)?.cast<String, dynamic>() ?? {};
  bool get canEdit => b('can_edit');
  List<SvcData> get places => l('places');
  List<SvcData> get tools => l('tools');
  List<SvcData> get materials => l('materials');
  List<SvcData> get team => l('team');
  List<SvcData> get branches => l('branches');
}

/// The catalogue's Inventory tab (`svc_inventory`, 3 Nov 2026): places, tools, materials, customers' items in care, and what needs doing.
class InventoryData extends SvcData {
  const InventoryData(super.raw);
  bool get canEdit => b('can_edit');
  int count(String section) => m('counts').i(section);
  List<SvcData> section(String name) => l(name);
  List<SvcData> get alerts => l('alerts');
  List<SvcData> get services => l('services');
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

/// Service management's slot table (`svc_slot_table`, founder's sketch, 2 Nov 2026): one weekday's slots worked out from the saved hours,
/// how many people work each slot, every day's hours, and the word for workers (from the kind of service chosen at sign-up).
class SlotTableData extends SvcData {
  const SlotTableData(super.raw);
  String get locationId => m('location').s('id');
  String get locationName => m('location').s('name');
  int get weekday => i('weekday');
  String get workerOne => m('worker_word').s('one');
  String get workerMany => m('worker_word').s('many');
  int get slotMinutes => i('slot_minutes');
  List<int> get slotChoices => ls('slot_choices').map(int.parse).toList();
  SvcData get hours => m('hours');
  bool get closed => b('closed');
  List<SvcData> get days => l('days');
  List<SvcData> get slots => l('slots');
  List<SvcData> get staff => l('staff');
  bool get canEdit => b('can_edit');
}

/// One bill of the Bill tab (`svc_bill_view`, 2 Nov 2026): from a booking or made in the tab; lines, totals, payments.
class BillView extends SvcData {
  const BillView(super.raw);
  String get id => s('id');
  String get displayNo => s('display_no');
  String get status => s('status');
  String get statusLabel => s('status_label');
  String get tone => s('tone');
  String get title => s('title');
  String get customer => s('customer');
  String get customerPhone => s('customer_phone');
  String get address => s('address');
  String get message => s('message');
  String get dateLabel => s('date_label');
  bool get fromBooking => s('source') == 'booking';
  bool get fromJob => s('source') == 'job';
  SvcData get job => m('job');
  SvcData get booking => m('booking');
  List<SvcData> get lines => l('lines');
  List<SvcData> get payments => l('payments');
  num get subtotal => n('subtotal');
  num get discount => n('discount');
  num get gstPct => n('gst_pct');
  num get gst => n('gst_amount');
  num get roundOff => n('round_off');
  num get total => n('total');
  num get paid => n('paid');
  num get due => n('due');
  num get change => n('change');
  bool get canCollect => b('can_collect');
  bool get canOpenBooking => b('can_open_booking');
}

/// A job (`svc_job_view`, New job, 2 Nov 2026): several services, a team, its visits (one or a repeating series), its bill.
class JobView extends SvcData {
  const JobView(super.raw);
  String get id => s('id');
  String get displayNo => s('display_no');
  String get title => s('title');
  String get instructions => s('instructions');
  String get status => s('status');
  String get statusLabel => s('status_label');
  String get tone => s('tone');
  String get customer => s('customer');
  String get customerPhone => s('customer_phone');
  String get address => s('address');
  String get repeatLabel => s('repeat_label');
  bool get online => s('source') == 'app';
  bool get remindInvoice => b('remind_invoice');
  List<SvcData> get team => l('team');
  List<SvcData> get visits => l('visits');
  BillView get bill => BillView(m('bill').raw);
  List<String> get actions => ls('actions');
  bool can(String action) => actions.contains(action);
  /// After Close: the job asks to be billed now (its "remind me to bill" is on and money is due).
  bool get billNow => b('bill_now');
  int get visitsCancelled => i('visits_cancelled');
}

/// The Bill tab (`svc_bill_list`): the bills for one filter, counts per filter, what is due now and paid this month.
class BillListData extends SvcData {
  const BillListData(super.raw);
  int count(String filter) => m('counts').i(filter);
  num get dueAmount => n('due_amount');
  num get paidThisMonth => n('paid_this_month');
  /// Money taken today, less refunds today (the dashboard's "Money · today").
  num get paidToday => n('paid_today');
  List<BillView> get bills => l('bills').map((b) => BillView(b.raw)).toList();
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
      : _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken),
        _http = client;

  final RpcClient _rpc;
  final http.Client? _http; // the upload of a banner photo or video straight to storage

  /// A banner photo or video for a service (founder, 4 Nov 2026): a signed slot under this business, then the bytes straight to storage.
  /// Returns the public link to keep in the listing, and whether it is an image or a video.
  Future<({String url, String kind})> uploadMedia(PickedDocument d) async {
    final slot = await _call('svc_media_slot', {'content_type': d.contentType, 'size': d.bytes.length});
    final put = await (_http ?? http.Client())
        .put(Uri.parse(slot['upload_url'] as String), headers: {'Content-Type': d.contentType, 'x-upsert': 'true'}, body: d.bytes)
        .timeout(const Duration(minutes: 5));
    if (put.statusCode >= 300) throw ServiceApiException(put.statusCode, 'The upload did not finish. Try again.', 'upload');
    return (url: slot['url'] as String, kind: slot['media_kind'] as String? ?? 'image');
  }
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

  Future<ServiceDashboardData> dashboard({String? locationId}) async => ServiceDashboardData(await _call('svc_dashboard', {'location_id': locationId}));
  Future<FreeSlotsData> freeSlots({String? date, String? locationId}) async => FreeSlotsData(await _call('svc_free_slots', {'date': date, 'location_id': locationId}));
  Future<MoneySplitData> moneySplit({String? locationId}) async => MoneySplitData(await _call('svc_money_split', {'location_id': locationId}));

  /// [view] is day, week or month. [withCancelled] lists cancelled bookings too (the Bookings board's Cancelled column).
  /// [source]: 'pos' (offline) or 'app' (online) to show one kind only.
  Future<CalendarData> calendar({required String date, String view = 'day', String? locationId, String? staffId, bool withCancelled = false, String? source}) async =>
      CalendarData(await _call('svc_calendar', {'date': date, 'view': view, 'location_id': locationId, 'staff_id': staffId, if (withCancelled) 'with_cancelled': true, 'source': source}));

  /// [party]: who is coming ({group, guests: [{g, a}]}); [startsAt]: the time picked, for peak prices and time rules.
  Future<ServiceQuote> quote({required String serviceId, List<String> addonIds = const [], String? staffId, Map<String, Object?>? party, String? startsAt}) async =>
      ServiceQuote(await _call('svc_quote', {'service_id': serviceId, 'addon_ids': addonIds, 'staff_id': staffId, 'party': party, 'starts_at': startsAt}));

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
    Map<String, Object?>? party,
  }) async =>
      AppointmentView(await _call('svc_book', key: key, {
        'party': ?party,
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

  /// The paid visit's online bill (the same `/b/<code>` page as a store bill, 2 Nov 2026): made once per order, the same link after.
  /// Always the public OneLocal address, never this PC's server.
  Future<Uri> billLink(String orderId) async => Uri.parse('${AppEnv.publicWebUrl}/b/${(await _call('pos_bill_link', {'order_id': orderId}))['code']}');

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




  /// A service report (`svc_report`, 4 Nov 2026): [kind] is sales, services, categories, bookings, staff, payments, dues, discounts or
  /// cancellations; [from] and [to] are days in the business's time zone.
  Future<SvcData> report(String kind, {required DateTime from, required DateTime to}) async =>
      SvcData(await _call('svc_report', {'kind': kind, 'from': _day(from), 'to': _day(to)}));

  static String _day(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  Future<TemplateListData> templates({String q = ''}) async => TemplateListData(await _call('svc_template_list', {if (q.trim().isNotEmpty) 'q': q.trim()}));

  /// Add or change a template ({id?, name, category, subcategory, duration_min, requirements, rules, notes}); `archived: true` deletes it.
  Future<TemplateListData> saveTemplate(Map<String, Object?> fields, {required String key}) async => TemplateListData(await _call('svc_template_save', fields, key: key));

  /// Templates from Excel: one with the same name is replaced, a new one added.
  Future<TemplateListData> importTemplates(List<Map<String, Object?>> templates, {required String key}) async =>
      TemplateListData(await _call('svc_template_import', {'templates': templates}, key: key));
  /// A listing form: its answers when [serviceId] is given, and the places, tools, materials, team and branches it picks from.
  Future<ListingData> listingView({String? serviceId}) async => ListingData(await _call('svc_listing_view', {'service_id': serviceId}));

  /// Keeps a service's listing (its category and the form's answers).
  Future<ListingData> saveListing(String serviceId, String category, Map<String, Object?> listing, {required String key}) async =>
      ListingData(await _call('svc_listing_save', {'service_id': serviceId, 'category': category, 'listing': listing}, key: key));
  Future<InventoryData> inventory() async => InventoryData(await _call('svc_inventory', {}));

  /// Add or change a place, tool or material ({id?, kind, name, qty, ...}); `archived: true` removes it. Manager roles.
  Future<InventoryData> saveInventory(Map<String, Object?> fields, {required String key}) async => InventoryData(await _call('svc_inventory_save', fields, key: key));

  /// A tool going out or coming back, a material added or used.
  Future<InventoryData> moveInventory(String id, String action, num qty, {String? note, required String key}) async =>
      InventoryData(await _call('svc_inventory_move', {'id': id, 'action': action, 'qty': qty, 'note': note}, key: key));

  /// Take in a customer's item, change it, or move it on (with_you, in_work, ready, returned).
  Future<InventoryData> saveCare(Map<String, Object?> fields, {required String key}) async => InventoryData(await _call('svc_care_save', fields, key: key));

  Future<ScheduleData> schedule({String? locationId}) async => ScheduleData(await _call('svc_schedule', {'location_id': locationId}));

  /// The Bill tab: bills for [filter] (all, due or paid), searched by bill number, customer or phone.
  Future<BillListData> bills({String filter = 'all', String q = ''}) async =>
      BillListData(await _call('svc_bill_list', {'filter': filter, if (q.trim().isNotEmpty) 'q': q.trim()}));

  Future<BillView> billView(String orderId) async => BillView(await _call('svc_bill_view', {'order_id': orderId}));

  /// A new bill (not from a booking): services from the catalogue with quantities, a discount in rupees or percent. Left unpaid.
  Future<BillView> createBill({required String key, required String customerName, String? customerPhone, String? address, String? title, String? message,
          required List<Map<String, Object?>> lines, num? discount, num? discountPct}) async =>
      BillView(await _call('svc_invoice_create', key: key, {
        'customer_name': customerName,
        if (customerPhone != null && customerPhone.trim().isNotEmpty) 'customer_phone': customerPhone.trim(),
        if (address != null && address.trim().isNotEmpty) 'address': address.trim(),
        if (title != null && title.trim().isNotEmpty) 'title': title.trim(),
        if (message != null && message.trim().isNotEmpty) 'message': message.trim(),
        'lines': lines,
        'discount': discount,
        'discount_pct': discountPct,
      }));

  /// Takes what is due on a bill made in the Bill tab (a booking's bill is paid through its visit).
  Future<BillView> payBill(String orderId, {required String method, num? tendered, required String key}) async =>
      BillView(await _call('svc_invoice_pay', key: key, {'order_id': orderId, 'method': method, 'tendered': tendered}));

  /// A new job. With [scheduleLater] there are no visits yet; otherwise [date], [start] and [end] ('HH:MM'), repeated [repeatCount] times.
  Future<JobView> saveJob({
    required String key,
    required String customerName,
    String? customerPhone,
    String? address,
    String? title,
    String? instructions,
    required List<Map<String, Object?>> lines,
    num? discount,
    num? discountPct,
    List<String> team = const [],
    bool scheduleLater = false,
    String? date,
    String? start,
    String? end,
    int arrivalWindowMin = 0,
    String repeat = 'none',
    int repeatCount = 1,
    bool remindInvoice = true,
  }) async =>
      JobView(await _call('svc_job_save', key: key, {
        'customer_name': customerName,
        if (customerPhone != null && customerPhone.trim().isNotEmpty) 'customer_phone': customerPhone.trim(),
        if (address != null && address.trim().isNotEmpty) 'address': address.trim(),
        if (title != null && title.trim().isNotEmpty) 'title': title.trim(),
        if (instructions != null && instructions.trim().isNotEmpty) 'instructions': instructions.trim(),
        'lines': lines,
        'discount': discount,
        'discount_pct': discountPct,
        'team': team,
        if (scheduleLater) 'schedule_later': true else ...{'date': date, 'start': start, 'end': end, 'arrival_window_min': arrivalWindowMin, 'repeat': repeat, if (repeat != 'none') 'repeat_count': repeatCount},
        'remind_invoice': remindInvoice,
      }));

  Future<JobView> job(String id) async => JobView(await _call('svc_job_view', {'id': id}));

  /// [action]: start or complete (a visit: [visitId]), close or cancel (the job).
  Future<JobView> jobAct(String id, String action, {String? visitId, required String key}) async =>
      JobView(await _call('svc_job_act', key: key, {'id': id, 'action': action, 'visit_id': visitId}));

  /// One weekday (1 = Monday; today when null) of Service management's slot table.
  Future<SlotTableData> slotTable({int? weekday, String? locationId}) async =>
      SlotTableData(await _call('svc_slot_table', {'weekday': weekday, 'location_id': locationId}));

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
