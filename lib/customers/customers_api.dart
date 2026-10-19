import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';
import '../auth/partner_api.dart';

Map<String, dynamic> _map(Object? v) => (v as Map?)?.cast<String, dynamic>() ?? const {};
num _n(Object? v) => v is num ? v : (num.tryParse('${v ?? 0}') ?? 0);
String _s(Object? v) => v == null ? '' : '$v';
DateTime? _d(Object? v) => v == null ? null : DateTime.tryParse('$v')?.toLocal();

/// One customer of the business (`pos_customers`). Phone and email arrive masked unless the person's role may see them in full
/// (the database decides; the app never unmasks).
class Customer {
  const Customer(this.raw);
  final Map<String, dynamic> raw;
  String get id => _s(raw['id']);
  String get name => _s(raw['name']);
  String get firstName => _s(raw['first_name']);
  String get lastName => _s(raw['last_name']);
  String get phone => _s(raw['phone']);
  String? get email => raw['email'] == null ? null : _s(raw['email']);
  int get visits => _n(raw['visits']).toInt();
  num get spent => _n(raw['spent']);
  DateTime? get lastVisit => _d(raw['last_visit']);
}

/// The detail screen's answer (`cust_view`): the customer plus history and balances.
class CustomerDetail extends Customer {
  const CustomerDetail(super.raw);
  bool get fullContact => raw['full_contact'] == true;
  bool get canManage => raw['can_manage'] == true;
  String? get gstNumber => raw['gst_number'] == null ? null : _s(raw['gst_number']);
  String? get dateOfBirth => raw['date_of_birth'] == null ? null : _s(raw['date_of_birth']);
  String? get anniversary => raw['anniversary'] == null ? null : _s(raw['anniversary']);
  String get address => _s(raw['address']);
  String get notes => _s(raw['notes']);
  String get preferredDining => _s(raw['preferred_dining']);
  String get locationName => _s(raw['location_name']);
  num get walletBalance => _n(raw['wallet_balance']);
  int get loyaltyPoints => _n(raw['loyalty_points']).toInt();
  List<CustomerOrder> get orders => ((raw['orders'] as List?) ?? const []).whereType<Map>().map((m) => CustomerOrder(_map(m))).toList();
}

class CustomerOrder {
  const CustomerOrder(this.raw);
  final Map<String, dynamic> raw;
  String get id => _s(raw['id']);
  String get number => _s(raw['display_no']);
  String get status => _s(raw['status']);
  String get channel => _s(raw['channel']);
  num get total => _n(raw['total']);
  bool get paid => raw['paid'] == true;
  DateTime? get at => _d(raw['created_at']);
}

class CustomerPage {
  const CustomerPage(this.raw);
  final Map<String, dynamic> raw;
  List<Customer> get items => ((raw['items'] as List?) ?? const []).whereType<Map>().map((m) => Customer(_map(m))).toList();
  int get total => _n(raw['total']).toInt();
  int? get nextOffset => raw['next_offset'] == null ? null : _n(raw['next_offset']).toInt();
  bool get canManage => raw['can_manage'] == true;
  bool get fullContact => raw['full_contact'] == true;
}

/// What `cust_save` answered: a new customer, or the one already on file with that phone.
class SavedCustomer {
  const SavedCustomer(this.raw);
  final Map<String, dynamic> raw;
  String get id => _s(raw['customer_id']);
  bool get created => raw['created'] == true;
  bool get duplicate => raw['duplicate'] == true;
  Customer get customer => Customer(_map(raw['customer']));
}

class CustomersApiException extends PartnerApiException {
  const CustomersApiException(super.status, super.message);
}

/// Customers of the business (database: 0510). Every rule (role, outlet, masking, duplicates, which bills may change) is the database's.
class CustomersApi {
  CustomersApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc})
      : _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);
  final RpcClient _rpc;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> args) async {
    try {
      return await _rpc.callMap(fn, args);
    } on RpcException catch (e) {
      throw CustomersApiException(e.status, e.message);
    }
  }

  Future<CustomerPage> list({String q = '', int offset = 0}) async =>
      CustomerPage(await _call('cust_list', {if (q.trim().isNotEmpty) 'q': q.trim(), if (offset > 0) 'offset': offset}));

  /// Exact 10-digit phone, business-wide. Null when nobody has that number.
  Future<Customer?> lookup(String phone) async {
    final r = await _call('cust_lookup', {'phone': phone});
    return r['found'] == true ? Customer(_map(r['customer'])) : null;
  }

  Future<CustomerDetail> view(String id) async => CustomerDetail(await _call('cust_view', {'id': id}));

  Future<SavedCustomer> save(Map<String, dynamic> fields) async => SavedCustomer(await _call('cust_save', fields));

  /// S5.5: link [customerId] to the bill, or mark it walk-in when [customerId] is null.
  Future<void> attach(String orderId, String? customerId) =>
      _call('cust_attach_order', {'order_id': orderId, if (customerId != null) 'customer_id': customerId else 'walk_in': true});
}
