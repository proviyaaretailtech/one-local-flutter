import 'dart:math';

import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';
import '../inventory/inventory_api.dart' show Facts;
import 'tables_api.dart' show TablesApiException;

/// The restaurant "Bill and pay" calls through the one generic door, `POST /rpc/<rst_function>` ([RpcClient]); the database functions of
/// migration 0550 do the work: they work out every amount (split shares, coupon, GST, change), check the business, the store and the role,
/// and make sure a guest's part is never paid twice. The app only draws the answers. Money calls carry an Idempotency-Key: keep the key of
/// one tap and send it again when retrying that same tap.
class BillApi {
  BillApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc, this.locationId})
      : _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);

  final RpcClient _rpc;
  String? locationId;

  static final _rand = Random.secure();
  static String newKey() => 'rst-${List.generate(16, (_) => _rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  Future<Facts> _call(String fn, Map<String, Object?> args, {String? key}) async {
    final body = <String, dynamic>{...args}..removeWhere((_, v) => v == null);
    try {
      return Facts(await _rpc.callMap(fn, body, key));
    } on RpcException catch (e) {
      throw TablesApiException(e.status, e.message, e.code);
    }
  }

  /// The bill of a table: its open orders (oldest first) with items, money, paid, due, coupon, note, split plan and payments.
  Future<Facts> view(String tableId) => _call('rst_bill_view', {'table_id': tableId, if (locationId != null && locationId!.isNotEmpty) 'location_id': locationId});

  /// [mode] equal | item | amount. [parts]: per guest {label, method, amount (amount mode), item_ids (item mode)}.
  Future<Facts> split(String orderId, {required String mode, int? guests, required List<Map<String, Object?>> parts, required String key}) =>
      _call('rst_bill_split', {'order_id': orderId, 'mode': mode, 'guests': guests, 'parts': parts, 'idempotency_key': key}, key: key);

  /// Pays one guest's part ([partId]) or, without it, the whole amount due. [tendered] is the cash handed over.
  Future<Facts> pay(String orderId, {String? partId, required String method, num? tendered, String? reference, required String key}) => _call(
      'rst_bill_pay', {'order_id': orderId, 'part_id': partId, 'method': method, 'tendered': tendered, 'reference': reference, 'idempotency_key': key},
      key: key);

  Future<Facts> coupon(String orderId, String code) => _call('rst_bill_coupon', {'order_id': orderId, 'code': code.trim()});

  Future<Facts> note(String orderId, String note) => _call('rst_bill_note', {'order_id': orderId, 'note': note.trim()});

  /// A paid bill for the Success and Send-receipt screens.
  Future<Facts> receipt(String orderId) => _call('rst_receipt_view', {'order_id': orderId});

  /// [channel] print | whatsapp | sms | email. The database keeps only a masked [to].
  Future<Facts> logReceipt(String orderId, String channel, {String? to}) => _call('rst_receipt_log', {'order_id': orderId, 'channel': channel, 'to': to});

  /// Who the bill is for, before or after it is paid: the customer with this mobile number (added when new, `cust_save` answers the one on
  /// file when the number is known) is put on the bill (`cust_attach_order`). Changing a customer already on the bill needs a manager.
  Future<void> setCustomer(String orderId, {required String name, required String phone}) async {
    final saved = await _call('cust_save', {'first_name': name.trim(), 'phone': phone});
    await _call('cust_attach_order', {'order_id': orderId, 'customer_id': saved.s('customer_id')});
  }
}

const _methodNames = {'cash': 'Cash', 'card': 'Card', 'upi': 'UPI', 'split': 'Split', 'wallet': 'Wallet', 'other': 'Other'};
String methodName(String m) => _methodNames[m] ?? m;

/// "₹1,302" / "₹166.67" — display only; every amount comes from the server.
String money(num? v) {
  final a = (v ?? 0).abs();
  final whole = a.truncate();
  final paise = ((a - whole) * 100).round();
  final s = whole.toString();
  var grouped = s;
  if (s.length > 3) {
    final last3 = s.substring(s.length - 3);
    var rest = s.substring(0, s.length - 3);
    final parts = <String>[];
    while (rest.length > 2) {
      parts.insert(0, rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) parts.insert(0, rest);
    grouped = '${parts.join(',')},$last3';
  }
  return '${(v ?? 0) < 0 ? '-' : ''}₹$grouped${paise == 0 ? '' : '.${paise.toString().padLeft(2, '0')}'}';
}

/// The plain-text bill / receipt (Print Bill, Print, WhatsApp, SMS, email). [bill] is one order as `rst_bill_view` or `rst_receipt_view` return it.
/// The bill's lines (0625): a combo's dishes (₹0 rows that are there for the kitchen) are left out; the combo is listed under its dish.
List<Facts> billItems(Facts order) => order.l('items').where((i) => !i.b('in_combo')).toList();

/// What was chosen with a bill line (0625), each priced for one dish: ("+ Cheese slice", 50), ("+ fries & Cole combo: Ice Blue, Salted Fries", 325).
List<(String, num)> billAddOns(Facts i) => [
      for (final a in i.l('add_ons'))
        (
          '+ ${a.n('qty') > 1 ? '${a.n('qty').toInt()} × ' : ''}${a.s('name')}'
              '${a.s('kind') == 'combo' ? ' combo${(a.so('items') ?? '').isEmpty ? '' : ': ${a.s('items')}'}' : ''}',
          a.n('price') * (a.n('qty') == 0 ? 1 : a.n('qty')),
        ),
    ];

String billText(Facts bill, {String? business, String? table, bool receipt = false}) {
  final out = <String>[
    if (business != null && business.isNotEmpty) business,
    '${receipt ? 'Receipt' : 'Bill'} ${bill.s('display_no')}${table == null ? '' : ' · Table $table'}',
    if ((bill.so('customer_name') ?? '').isNotEmpty) 'Customer: ${bill.s('customer_name')}',
    '',
  ];
  for (final i in billItems(bill).where((i) => !i.b('takeaway'))) {
    out.add('${i.n('qty')} x ${i.s('name')}${(i.so('variant') ?? '').isEmpty ? '' : ' (${i.s('variant')})'}  ${money(i.n('line_total'))}');
    for (final (what, price) in billAddOns(i)) {
      out.add('   $what  ${money(price)} each');
    }
  }
  // takeaway dishes on the same dine-in bill (0606), under their own heading
  final away = billItems(bill).where((i) => i.b('takeaway')).toList();
  if (away.isNotEmpty) out.add('-- Takeaway --');
  for (final i in away) {
    out.add('${i.n('qty')} x ${i.s('name')}${(i.so('variant') ?? '').isEmpty ? '' : ' (${i.s('variant')})'} (Takeaway)  ${money(i.n('line_total'))}');
    for (final (what, price) in billAddOns(i)) {
      out.add('   $what  ${money(price)} each');
    }
  }
  out.addAll(['', 'Subtotal ${money(bill.n('subtotal'))}']);
  if (bill.n('discount') != 0) out.add('Discount${bill.so('coupon_code') == null ? '' : ' ${bill.s('coupon_code')}'} -${money(bill.n('discount'))}');
  if (bill.n('gst_amount') != 0) out.add('GST (${_pct(bill.n('gst_pct'))}%) ${money(bill.n('gst_amount'))}');
  if (bill.n('service_charge') != 0) out.add('Service charge ${money(bill.n('service_charge'))}');
  if (bill.n('round_off') != 0) out.add('Round off ${money(bill.n('round_off'))}');
  out.add('Total ${money(bill.n('total'))}');
  for (final p in bill.l('payments')) {
    out.add('Paid ${money(p.n('amount'))} by ${methodName(p.s('method'))}');
  }
  if (!receipt && bill.n('due') > 0) out.add('Due ${money(bill.n('due'))}');
  return out.join('\n');
}

String _pct(num v) => v == v.roundToDouble() ? '${v.toInt()}' : '$v';
