import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';
import '../auth/partner_api.dart';
import '../home/home_nav.dart';

Map<String, dynamic> _map(Object? v) => (v as Map?)?.cast<String, dynamic>() ?? const {};

/// One outlet as the server describes it (`outlet_list`, migration 0522). Every word on the card (status, delivery label, why a
/// toggle is off) comes from the server; the app only draws it.
/// What a place is called, by the kind of business the app is running as (the shell's kind): a store's screens never say restaurant or
/// kitchen. [kind] is for tests and for screens shown outside the shell.
bool outletIsRestaurant([String? kind]) => (kind ?? HomeNav.shell?.kind) == 'restaurant';
String outletNoun([String? kind]) => outletIsRestaurant(kind) ? 'restaurant' : 'store';
String outletNounTitle([String? kind]) => outletIsRestaurant(kind) ? 'Restaurant' : 'Store';

class Outlet {
  const Outlet(this.raw);
  final Map<String, dynamic> raw;
  String _s(String k) => (raw[k] ?? '').toString();
  String get id => _s('id');
  String get code => _s('code');
  String get name => _s('name');
  String get locality => _s('locality');
  String get city => _s('city');

  /// approved | pending | rejected | inactive
  String get verification => _s('verification');

  /// online | offline | paused | pending | rejected | inactive
  String get status => _s('status');
  String get statusLabel => _s('status_label');
  String get deliveryLabel => _s('delivery_label');
  String get reference => _s('reference');
  String get reviewNote => _s('review_note');
  String get toggleNote => _s('toggle_note');
  bool get accepting => raw['accepting'] == true;
  bool get rushMode => raw['rush_mode'] == true;
  int get rushExtraMinutes => (raw['rush_extra_minutes'] as num?)?.toInt() ?? 15;
  bool get canToggle => raw['can_toggle'] == true;
  bool get verified => verification == 'approved';
}

/// The answer of `outlet_list`: the outlets the person may see, the one the app works in, the summary chip and what they may do.
class OutletOverview {
  const OutletOverview(this.raw);
  final Map<String, dynamic> raw;
  List<Outlet> get outlets => ((raw['outlets'] as List?) ?? const []).whereType<Map>().map((m) => Outlet(_map(m))).toList();
  Outlet? get current => raw['current'] is Map ? Outlet(_map(raw['current'])) : null;
  Map<String, dynamic> get summary => _map(raw['summary']);
  String get chip => (summary['chip'] ?? '').toString();
  int get pending => (summary['pending'] as num?)?.toInt() ?? 0;
  String get personName => (_map(raw['person'])['name'] ?? '').toString();
  String get businessName => (_map(raw['business'])['name'] ?? '').toString();
  bool get needsFssai => _map(raw['business'])['needs_fssai'] == true;
  bool get canAdd => raw['can_add'] == true;

  /// The open add-outlet draft of the business (id, name, step), or null.
  Map<String, dynamic>? get draft => raw['draft'] is Map ? _map(raw['draft']) : null;

  /// Verified outlets (the switcher's list).
  List<Outlet> get verified => outlets.where((o) => o.verified).toList();
}

/// An add-outlet draft (`outlet_draft_*`, migration 0523): what was typed so far, the step reached and what is still missing.
class OutletDraft {
  const OutletDraft(this.raw);
  final Map<String, dynamic> raw;
  String _s(String k) => (raw[k] ?? '').toString();
  String get id => _s('id');
  String get status => _s('status');
  String get step => raw['step'] == null ? 'state' : _s('step');
  String get stateCode => _s('state_code');
  String get stateName => _s('state_name');
  bool get interState => raw['inter_state'] == true;
  String s(String k) => _s(k);
  double? d(String k) => (raw[k] as num?)?.toDouble();
  Map<String, dynamic> get hours => _map(raw['hours']);
  List<String> get missing => ((raw['missing'] as List?) ?? const []).map((e) => '$e').toList();
  Outlet? get outlet => raw['outlet'] is Map ? Outlet(_map(raw['outlet'])) : null;
}

/// `outlet_draft_get`: the draft to continue (or null), the GST state list and the business's home state.
class DraftStart {
  const DraftStart(this.raw);
  final Map<String, dynamic> raw;
  OutletDraft? get draft => raw['draft'] is Map ? OutletDraft(_map(raw['draft'])) : null;
  List<(String, String)> get states =>
      ((raw['states'] as List?) ?? const []).whereType<Map>().map((m) => ('${m['code']}', '${m['name']}')).toList();
  String? get homeStateCode => raw['home_state_code'] as String?;
  String? get homeStateName => raw['home_state_name'] as String?;
  bool get needsFssai => raw['needs_fssai'] == true;
}

class OutletsApi {
  OutletsApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc})
      : _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);
  final RpcClient _rpc;

  Future<T> _wrap<T>(Future<T> Function() f) async {
    try {
      return await f();
    } on RpcException catch (e) {
      throw PartnerApiException(e.status, e.message);
    }
  }

  /// Every outlet the person may see. [locationId] picks the outlet shown in the header (the server falls back to the default one).
  Future<OutletOverview> list({String? q, String? locationId}) =>
      _wrap(() async => OutletOverview(await _rpc.callMap('outlet_list', {'q': ?q, 'location_id': ?locationId})));

  /// Delivery status (accepting One Local orders) and Rush mode of one verified outlet. Answers the outlet as it now is.
  Future<Outlet> setChannel(String locationId, {bool? accepting, bool? rushMode, int? rushExtraMinutes}) => _wrap(() async {
        final r = await _rpc.callMap('outlet_set_channel', {
          'location_id': locationId,
          'accepting': ?accepting,
          'rush_mode': ?rushMode,
          'rush_extra_minutes': ?rushExtraMinutes,
        });
        return Outlet(_map(r['outlet']));
      });

  /// The draft to continue ([id], else the newest open one) with the state list.
  Future<DraftStart> draftGet({String? id}) => _wrap(() async => DraftStart(await _rpc.callMap('outlet_draft_get', {'id': ?id})));

  /// Saves what was typed so far. A new draft needs [key] (the same key on a retry finds the same draft).
  Future<OutletDraft> draftSave(Map<String, dynamic> fields, {String? id, String? key}) => _wrap(() async {
        final r = await _rpc.callMap('outlet_draft_save', {...fields, 'id': ?id}, id == null ? key : null);
        return OutletDraft(_map(r['draft']));
      });

  /// Sends a complete draft for verification: the outlet is created as pending.
  Future<Outlet> draftSubmit(String id) => _wrap(() async {
        final r = await _rpc.callMap('outlet_draft_submit', {'id': id});
        return Outlet(_map(r['outlet']));
      });

  Future<void> draftDiscard(String id) => _wrap(() => _rpc.callMap('outlet_draft_discard', {'id': id}));

  /// A new outlet, saved as pending until One Local verifies it. [key] makes a retry of the same form safe.
  Future<Outlet> add(Map<String, dynamic> form, {required String key}) => _wrap(() async {
        final r = await _rpc.callMap('outlet_add', form, key);
        return Outlet(_map(r['outlet']));
      });
}
