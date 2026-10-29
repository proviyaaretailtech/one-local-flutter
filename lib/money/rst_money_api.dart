import 'dart:math';

import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';
import '../auth/partner_api.dart';

/// The restaurant's Money in the store's design (`rmoney_*`, migration 0622): the wallet (cash drawer, UPI, bank), Money in / out, Transfer,
/// the cash register and its close, dues, and contacts to pay. Supplier invoices are paid through `money_invoice_pay`.
class RstMoneyApi {
  RstMoneyApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc})
      : _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);
  final RpcClient _rpc;
  static final _rand = Random.secure();

  /// A fresh key for one save; a retry of the same save sends the same key and is not recorded twice.
  static String newKey() => 'rm-${List.generate(16, (_) => _rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  Future<Map<String, dynamic>> _call(String fn, Map<String, Object?> args, {String? key}) async {
    try {
      return await _rpc.callMap(fn, {...args}..removeWhere((_, v) => v == null), key);
    } on RpcException catch (e) {
      throw PartnerApiException(e.status, e.message);
    }
  }

  Future<Map<String, dynamic>> home() => _call('rmoney_home', {});
  Future<Map<String, dynamic>> entries({required String direction, String method = 'all', required String from, required String to}) =>
      _call('rmoney_entries_list', {'direction': direction, 'method': method, 'from': from, 'to': to});
  Future<Map<String, dynamic>> record(Map<String, Object?> body, {required String key}) => _call('rmoney_record', body, key: key);
  Future<Map<String, dynamic>> voidEntry(String id, String reason) => _call('rmoney_void', {'id': id, 'reason': reason});
  Future<Map<String, dynamic>> register({String? day}) => _call('rmoney_register', {'day': day});
  Future<Map<String, dynamic>> closeDay(int countedMinor, {String? day}) => _call('rmoney_close_day', {'counted_minor': countedMinor, 'day': day});
  Future<Map<String, dynamic>> dues() => _call('rmoney_dues', {});
  Future<Map<String, dynamic>> contacts({String q = ''}) => _call('rmoney_contacts_list', {'q': q.trim().isEmpty ? null : q.trim()});
  Future<Map<String, dynamic>> saveContact({String? id, required String name, String phone = '', String upiId = ''}) =>
      _call('rmoney_contact_save', {'id': id, 'name': name, 'phone': phone, 'upi_id': upiId});
  Future<Map<String, dynamic>> payInvoice(String invoiceId, int amountMinor, String method, {required String key}) =>
      _call('money_invoice_pay', {'invoice_id': invoiceId, 'amount_minor': amountMinor, 'method': method}, key: key);
}
