import 'dart:math';

import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';
import '../inventory/inventory_api.dart' show Facts;

export '../inventory/inventory_api.dart' show Facts;

/// Money calls through the one generic door, `POST /rpc/<money_function>` ([RpcClient]); the database functions of migration 0435 do the work and
/// check the business, the place, the permission and every rule. The Supabase session token is the only credential. Every write carries an
/// Idempotency-Key, so a retried tap never records twice. The phone formats paise as rupees and dates; every figure, label and allowed action is the server's.
class MoneyApi {
  MoneyApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc, this.locationId})
      : _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);

  final RpcClient _rpc;

  /// The place the screens look at; null means every place the person may see.
  String? locationId;

  static final _rand = Random.secure();

  /// A fresh key for one intent (one form). Keep it and send it again when retrying that same intent.
  static String newKey() => 'money-${List.generate(16, (_) => _rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  Future<Facts> _read(String fn, Map<String, dynamic> args) async {
    final body = <String, dynamic>{if (locationId != null && locationId!.isNotEmpty) 'location_id': locationId, ...args}..removeWhere((_, v) => v == null || v == '');
    return Facts(await _rpc.callMap(fn, body));
  }

  Future<Facts> options() => _read('money_options', {});
  Future<Facts> overview(Map<String, dynamic> q) => _read('money_overview', q);
  Future<Facts> payments(Map<String, dynamic> q) => _read('money_payments_list', q);
  Future<Facts> transactions(Map<String, dynamic> q) => _read('money_transactions_list', q);
  Future<Facts> invoices(Map<String, dynamic> q) => _read('money_invoices_list', q);
  Future<Facts> cashbook(Map<String, dynamic> q) => _read('money_cashbook', q);
  Future<Facts> expenses(Map<String, dynamic> q) => _read('money_expenses_list', q);
  Future<Facts> refunds(Map<String, dynamic> q) => _read('money_refunds_list', q);
  Future<Facts> settlements(Map<String, dynamic> q) => _read('money_settlements_list', q);
  Future<Facts> settlement(String id) => _read('money_settlement_detail', {'id': id});
  Future<Facts> payouts(Map<String, dynamic> q) => _read('money_payouts_list', q);
  Future<Facts> reports(Map<String, dynamic> q) => _read('money_reports', q);
  Future<Facts> reportRows(String report, Map<String, dynamic> q) => _read('money_report_rows', {...q, 'report': report});

  Future<Facts> _write(String fn, Map<String, dynamic> args, String key) async {
    final body = <String, dynamic>{if (locationId != null && locationId!.isNotEmpty) 'location_id': locationId, ...args}..removeWhere((_, v) => v == null || v == '');
    return Facts(await _rpc.callMap(fn, body, key));
  }

  Future<Facts> recordExpense(Map<String, dynamic> f, String key) => _write('money_expense_record', f, key);
  Future<Facts> voidExpense(String id, String note, String key) => _write('money_expense_void', {'id': id, 'note': note}, key);
  Future<Facts> recordCash(Map<String, dynamic> f, String key) => _write('money_cash_record', f, key);
  Future<Facts> voidCash(String id, String note, String key) => _write('money_cash_void', {'id': id, 'note': note}, key);
  Future<Facts> recordParty(Map<String, dynamic> f, String key) => _write('money_party_record', f, key);
  Future<Facts> requestAdjustment(Map<String, dynamic> f, String key) => _write('money_adjustment_request', f, key);
  Future<Facts> decideAdjustment(String id, String decision, String? note, String key) => _write('money_adjustment_decide', {'id': id, 'decision': decision, 'note': note}, key);
  Future<Facts> payInvoice(Map<String, dynamic> f, String key) => _write('money_invoice_pay', f, key);
}

// ---------------------------------------------------------------- display formats (no business rules)

const _mon = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _group(int whole) {
  final s = whole.toString();
  if (s.length <= 3) return s;
  final tail = s.substring(s.length - 3);
  var head = s.substring(0, s.length - 3);
  final parts = <String>[];
  while (head.length > 2) {
    parts.insert(0, head.substring(head.length - 2));
    head = head.substring(0, head.length - 2);
  }
  if (head.isNotEmpty) parts.insert(0, head);
  return '${parts.join(',')},$tail';
}

/// Paise as rupees with Indian grouping: 1234567 -> ₹12,345.67. [whole] drops ".00" when there are no paise; [sign] puts + or − in front.
String money(num? paise, {bool whole = false, bool sign = false}) {
  if (paise == null) return '–';
  final p = paise.round();
  final a = p.abs();
  final r = a ~/ 100, c = a % 100;
  final body = (whole && c == 0) ? '₹${_group(r)}' : '₹${_group(r)}.${c.toString().padLeft(2, '0')}';
  if (p < 0) return '−$body';
  return sign && p > 0 ? '+$body' : body;
}

/// "12 Oct" / "12 Oct 2026" from an ISO date or time.
String dayMonth(String? iso, {bool year = false}) {
  final d = DateTime.tryParse(iso ?? '');
  if (d == null) return '–';
  final l = iso!.length > 10 ? d.toLocal() : d;
  return '${l.day.toString().padLeft(2, '0')} ${_mon[l.month - 1]}${year ? ' ${l.year}' : ''}';
}

/// "05–07 Oct" or "28 Sep–04 Oct" for a window the server returned.
String rangeLabel(String? from, String? to) {
  final a = DateTime.tryParse(from ?? ''), b = DateTime.tryParse(to ?? '');
  if (a == null || b == null) return 'Dates';
  if (a == b) return dayMonth(to);
  if (a.month == b.month && a.year == b.year) return '${a.day.toString().padLeft(2, '0')}–${b.day.toString().padLeft(2, '0')} ${_mon[b.month - 1]}';
  return '${dayMonth(from)}–${dayMonth(to)}';
}

String hhmm(String? iso) {
  final d = DateTime.tryParse(iso ?? '')?.toLocal();
  return d == null ? '' : '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

String isoDay(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// "250", "250.5", "1,250.75" typed by a person -> paise; null when it is not an amount. The server checks the limits.
int? parseRupees(String text) {
  final t = text.replaceAll(',', '').trim();
  if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(t)) return null;
  final parts = t.split('.');
  final frac = parts.length == 1 ? 0 : int.parse(parts[1].padRight(2, '0'));
  return int.parse(parts[0]) * 100 + frac;
}

String _csvCell(Object? v) {
  final s = v == null ? '' : v.toString();
  return RegExp(r'[",\n\r]').hasMatch(s) ? '"${s.replaceAll('"', '""')}"' : s;
}

/// The CSV text of one `money_report_rows` answer. Columns of type money arrive in paise and are written as rupees with two decimals.
String csvOf(Facts report) {
  final cols = report.l('columns');
  final rows = (report.raw['rows'] as List?) ?? const [];
  final out = StringBuffer()..writeln(cols.map((c) => _csvCell(c.s('label'))).join(','));
  for (final r in rows.whereType<List>()) {
    out.writeln([
      for (var i = 0; i < cols.length; i++)
        _csvCell(i < r.length && r[i] != null && cols[i].s('type') == 'money' && r[i] is num ? ((r[i] as num) / 100).toStringAsFixed(2) : (i < r.length ? r[i] : '')),
    ].join(','));
  }
  return out.toString();
}
