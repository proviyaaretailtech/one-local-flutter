import 'shift_api.dart';

// The business day (founder, 31 Oct 2026; database: hosted_pos_business_day_2026-10-31.sql). The day starts by itself at the store's
// opening time (or on the first POS activity), carries yesterday's counted closing cash and closing stock, and is closed by a manager.
// Every figure here is the database's; nothing is worked out on the phone except the live difference while typing a count.

num _n(Object? v) => v is num ? v : num.tryParse('${v ?? ''}') ?? 0;
num? _nn(Object? v) => v == null ? null : _n(v);
Map<String, dynamic> _m(Object? v) => v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};
List<Map<String, dynamic>> _l(Object? v) => v is List ? v.map(_m).toList() : const [];

/// One audited change of a day's cash: the first opening cash, a correction, a provisional opening, the carried amount or a closing count.
class DayCashChange {
  DayCashChange(this.raw);
  final Map<String, dynamic> raw;
  String get id => '${raw['id'] ?? ''}';
  String get kind => '${raw['kind'] ?? ''}';
  num? get original => _nn(raw['original_amount']);
  num get revised => _n(raw['revised_amount']);
  String? get reason => raw['reason'] as String?;
  String get approval => '${raw['approval_status'] ?? 'approved'}';
  bool get pending => approval == 'pending';
  String get by => '${raw['by'] ?? ''}';
  String get at => shiftWhen(raw['created_at'] as String?);
  String get kindLabel => switch (kind) {
        'opening_initial' => 'Opening cash entered',
        'opening_correction' => 'Opening cash corrected',
        'provisional_opening' => 'Provisional opening',
        'opening_carried' => 'Carried from the day before',
        'closing_count' => 'Cash counted',
        _ => kind,
      };
}

/// One business day of one store (`pos_business_days` + its live cash).
class BusinessDay {
  BusinessDay(this.raw);
  final Map<String, dynamic> raw;
  String get id => '${raw['id'] ?? ''}';
  String get date => '${raw['business_date'] ?? ''}';
  String get status => '${raw['status'] ?? ''}';
  String? get attention => raw['attention_reason'] as String?;
  bool get closed => status == 'closed';
  int get version => _n(raw['version']).toInt();
  String get locationName => '${raw['location_name'] ?? ''}';
  String get trigger => '${raw['start_trigger'] ?? ''}';
  String get startedAt => shiftWhen(raw['started_at'] as String?);
  String get closedAt => shiftWhen(raw['closed_at'] as String?);
  num? get carried => _nn(raw['carried_cash']);
  num? get opening => _nn(raw['opening_cash']);
  String? get openingSource => raw['opening_cash_source'] as String?;
  num? get counted => _nn(raw['counted_cash']);
  num? get variance => _nn(raw['variance']);
  String? get varianceReason => raw['variance_reason'] as String?;
  String? get closeNote => raw['close_note'] as String?;
  Map<String, dynamic> get cash => _m(raw['cash']);
  num get expected => _n(cash['expected_cash']);
  num get cashSales => _n(cash['cash_sales']);
  num get otherIn => _n(cash['other_cash_in']);
  num get refunds => _n(cash['cash_refunds']);
  num get expenses => _n(cash['cash_expenses']);
  num get deposits => _n(cash['deposits_withdrawals']);
  num get otherOut => _n(cash['other_cash_out']);
  int get bills => _n(cash['bills']).toInt();
  Map<String, num> get otherMethods => _m(cash['other_methods']).map((k, v) => MapEntry(k, _n(v)));
  Map<String, dynamic> get stock => _m(raw['stock']);
  Map<String, dynamic>? get prev => raw['prev'] is Map ? _m(raw['prev']) : null;
  List<DayCashChange> get changes => _l(raw['adjustments']).map(DayCashChange.new).toList();
  List<DayCashChange> get pendingChanges => changes.where((c) => c.pending).toList();

  /// Not Started (no day), Started, Provisional, Requires attention, Closed.
  String get statusLabel => switch (status) { 'started' => 'Started', 'provisional' => 'Provisional', 'attention' => 'Requires attention', 'closed' => 'Closed', _ => 'Not started' };

  /// What needs doing, in a sentence (null when nothing does).
  String? get attentionText => switch (attention) {
        'no_previous_closing' => 'No earlier day was closed here. Enter the cash in the drawer to start.',
        'previous_not_closed' => 'The day before was not closed. Close it, or a manager can open today provisionally.',
        'not_closed' => 'This day was not closed. Count the cash and close it.',
        _ => null,
      };
}

/// Today for the store (`pos_day_today`): the day (null until it starts) and what this person may do.
class DayToday {
  DayToday(this.raw);
  final Map<String, dynamic> raw;
  BusinessDay? get day => raw['day'] is Map ? BusinessDay(_m(raw['day'])) : null;
  String get date => '${raw['business_date'] ?? ''}';
  bool get canManage => raw['can_manage'] == true;
  bool get canCount => raw['can_count'] == true;
  String? get opensAt => raw['opens_at'] as String?;
}

/// One item of an opening (or closing) stock snapshot.
class DayStockLine {
  DayStockLine(this.raw);
  final Map<String, dynamic> raw;
  String get name => '${raw['name'] ?? ''}';
  String get sku => '${raw['sku'] ?? ''}';
  String get unit => '${raw['unit'] ?? ''}';
  num get onHand => _n(raw['on_hand']);
  num? get previousClosing => _nn(raw['previous_closing']);
  num? get moved => _nn(raw['moved']);
}

extension BusinessDayCalls on ShiftApi {
  /// Today's day; [start] starts it when it has not (first activity). [trigger] 'manual' when a person taps Start day.
  Future<DayToday> dayToday({bool start = true, String trigger = 'first_activity', String? locationId}) async =>
      DayToday(await call('pos_day_today', {'start': start, 'trigger': trigger, 'location_id': ?locationId}));

  Future<BusinessDay> dayGet(String dayId) async => BusinessDay(await call('pos_day_get', {'day_id': dayId}));

  Future<List<BusinessDay>> dayList({int limit = 30, String? before, String? locationId}) async =>
      (await callList('pos_day_list', {'limit': limit, 'before': ?before, 'location_id': ?locationId})).map((e) => BusinessDay(_m(e))).toList();

  Future<List<DayStockLine>> dayStock(String dayId, {String kind = 'opening', String q = ''}) async =>
      _l((await call('pos_day_stock', {'day_id': dayId, 'kind': kind, if (q.trim().isNotEmpty) 'q': q.trim()}))['items']).map(DayStockLine.new).toList();

  /// The opening cash: the first day's, a correction or a provisional opening. A manager's applies at once; anyone else's waits.
  Future<BusinessDay> dayOpening(String dayId, {required num amount, required String reason, required String key, int? version}) async =>
      BusinessDay(await call('pos_day_opening_set', {'day_id': dayId, 'amount': amount, 'reason': reason.trim(), 'expected_version': ?version}, key));

  Future<BusinessDay> dayDecide(String adjustmentId, {required bool approve, String note = ''}) async =>
      BusinessDay(await call('pos_day_adjustment_decide', {'adjustment_id': adjustmentId, 'decision': approve ? 'approve' : 'reject', if (note.trim().isNotEmpty) 'note': note.trim()}));

  Future<BusinessDay> dayCount(String dayId, {required num counted, String? reason, required String key}) async =>
      BusinessDay(await call('pos_day_cash_count', {'day_id': dayId, 'counted_cash': counted, if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim()}, key));

  Future<BusinessDay> dayClose(String dayId, {String note = '', required String key, int? version}) async =>
      BusinessDay(await call('pos_day_close', {'day_id': dayId, if (note.trim().isNotEmpty) 'note': note.trim(), 'expected_version': ?version}, key));
}
