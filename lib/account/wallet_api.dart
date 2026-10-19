import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';
import '../auth/partner_api.dart';

Map<String, dynamic> _map(Object? v) => (v as Map?)?.cast<String, dynamic>() ?? const {};
num _n(Object? v) => v is num ? v : (num.tryParse('${v ?? 0}') ?? 0);
String _s(Object? v) => v == null ? '' : '$v';
DateTime? _d(Object? v) => v == null ? null : DateTime.tryParse('$v')?.toLocal();

/// One line of the wallet: a weekly settlement (money One Local owes the business) or a payout (money sent to the bank).
class WalletMovement {
  const WalletMovement(this.raw);
  final Map<String, dynamic> raw;
  String get kind => _s(raw['kind']);
  String get id => _s(raw['id']);
  String get label => _s(raw['label']);
  bool get isIn => raw['direction'] == 'in';
  num get amount => _n(raw['amount']);
  String get status => _s(raw['status']);
  String get settlementId => _s(raw['settlement_id']);
  String? get reference => raw['reference'] == null ? null : _s(raw['reference']);
  bool get noTransferRecord => raw['no_transfer_record'] == true;
  DateTime? get at => _d(raw['at']);
}

class WalletPage {
  const WalletPage(this.raw);
  final Map<String, dynamic> raw;
  List<WalletMovement> get items => ((raw['items'] as List?) ?? const []).whereType<Map>().map((m) => WalletMovement(_map(m))).toList();
  int get total => _n(raw['total']).toInt();
  int? get nextOffset => raw['next_offset'] == null ? null : _n(raw['next_offset']).toInt();
}

/// `wallet_overview`: every figure is computed by the database from the settlement and payout records; the app only draws it.
class WalletOverview {
  const WalletOverview(this.raw);
  final Map<String, dynamic> raw;
  String get business => _s(raw['business']);
  num get unsettledDue => _n(_map(raw['unsettled'])['due']);
  num get unsettledCommission => _n(_map(raw['unsettled'])['commission']);
  int get unsettledOrders => _n(_map(raw['unsettled'])['orders']).toInt();
  String get unsettledNote => _s(_map(raw['unsettled'])['note']);
  DateTime? get nextSettlementWeek => _d(_map(raw['unsettled'])['next_settlement_week_starts']);
  num get onTheWay => _n(_map(raw['on_the_way'])['amount']);
  num get paid => _n(_map(raw['paid'])['amount']);
  int get failedTransfers => _n(_map(raw['paid'])['failed_transfers']).toInt();
  num get owedToOneLocal => _n(_map(raw['owed_to_onelocal'])['amount']);
  int get settledWithoutTransferRecord => _n(raw['settled_without_transfer_record']).toInt();
  WalletPage get movements => WalletPage(_map(raw['movements']));
}

class SettlementLine {
  const SettlementLine(this.raw);
  final Map<String, dynamic> raw;
  String get orderNumber => _s(raw['display_no']);
  String get paymentMode => _s(raw['payment_mode']);
  num get gross => _n(raw['gross']);
  num get foodDue => _n(raw['food_due']);
  num get commission => _n(raw['commission']);
}

class SettlementView {
  const SettlementView(this.raw);
  final Map<String, dynamic> raw;
  String get status => _s(raw['status']);
  DateTime? get from => _d(raw['period_start']);
  DateTime? get to => _d(raw['period_end']);
  num figure(String k) => _n(_map(raw['figures'])[k]);
  List<SettlementLine> get lines => ((raw['lines'] as List?) ?? const []).whereType<Map>().map((m) => SettlementLine(_map(m))).toList();
  List<Map<String, dynamic>> get payouts => ((raw['payouts'] as List?) ?? const []).whereType<Map>().map(_map).toList();
}

class WalletApiException extends PartnerApiException {
  const WalletApiException(super.status, super.message);
}

/// The One Local Wallet (database: 0511). Read only: no figure is computed or stored on the phone.
class WalletApi {
  WalletApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc})
      : _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);
  final RpcClient _rpc;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> args) async {
    try {
      return await _rpc.callMap(fn, args);
    } on RpcException catch (e) {
      throw WalletApiException(e.status, e.message);
    }
  }

  Future<WalletOverview> overview() async => WalletOverview(await _call('wallet_overview', {}));
  Future<WalletPage> movements({int offset = 0}) async => WalletPage(await _call('wallet_movements', {'offset': offset}));
  Future<SettlementView> settlement(String id) async => SettlementView(await _call('wallet_settlement_view', {'id': id}));
}
