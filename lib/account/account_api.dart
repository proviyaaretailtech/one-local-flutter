import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../api/rpc_client.dart';
import '../auth/partner_api.dart';

Map<String, dynamic> _map(Object? v) => (v as Map?)?.cast<String, dynamic>() ?? const {};
String _s(Object? v) => v == null ? '' : '$v';
DateTime? _d(Object? v) => v == null ? null : DateTime.tryParse('$v')?.toLocal();

class SignInMethod {
  const SignInMethod(this.raw);
  final Map<String, dynamic> raw;
  String get method => _s(raw['method']);
  String get label => _s(raw['label']);
  bool get enabled => raw['enabled'] == true;
  String? get code => raw['code'] == null ? null : _s(raw['code']);
  DateTime? get validUntil => _d(raw['valid_until']);
}

class AccountDevice {
  const AccountDevice(this.raw);
  final Map<String, dynamic> raw;
  String get device => _s(raw['device']);
  DateTime? get lastActive => _d(raw['last_active_at']);
  bool get thisDevice => raw['this_device'] == true;
}

/// `acct_get`: the signed-in person only.
class AccountInfo {
  const AccountInfo(this.raw);
  final Map<String, dynamic> raw;
  String get name => _s(raw['name']);
  String get email => _s(raw['email']);
  bool get emailConfirmed => raw['email_confirmed'] == true;
  String? get pendingEmail => raw['pending_email'] == null ? null : _s(raw['pending_email']);
  String? get phone => raw['phone'] == null ? null : _s(raw['phone']);
  bool get phoneConfirmed => raw['phone_confirmed'] == true;
  List<SignInMethod> get methods => ((raw['sign_in_methods'] as List?) ?? const []).whereType<Map>().map((m) => SignInMethod(_map(m))).toList();
  List<AccountDevice> get devices => ((raw['devices'] as List?) ?? const []).whereType<Map>().map((m) => AccountDevice(_map(m))).toList();
  List<Map<String, dynamic>> get memberships => ((raw['memberships'] as List?) ?? const []).whereType<Map>().map(_map).toList();
}

class AccountApiException extends PartnerApiException {
  const AccountApiException(super.status, super.message);
}

/// Manage account (database: 0512): profile and memberships through the database, the login itself through Supabase auth.
class AccountApi {
  AccountApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc})
      : _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);
  final RpcClient _rpc;

  Future<Map<String, dynamic>> _call(String fn, [Map<String, dynamic> args = const {}]) async {
    try {
      return await _rpc.callMap(fn, args);
    } on RpcException catch (e) {
      throw AccountApiException(e.status, e.message);
    }
  }

  Future<AccountInfo> get() async => AccountInfo(await _call('acct_get'));
  Future<void> saveName(String name) => _call('acct_save_name', {'name': name});
  Future<void> syncContact() => _call('acct_sync_contact');
  Future<void> recordSignOutEverywhere() => _call('acct_signed_out_everywhere');
}

/// The login's own changes, done by Supabase auth (confirmation mail, OTP, token revocation). An interface so screens can be tested.
abstract class AccountAuth {
  Future<void> setDisplayName(String name);
  /// Supabase sends a confirmation link to the new address; the change applies once it is opened.
  Future<void> changeEmail(String email);
  /// Supabase sends an OTP to the new number; [confirmPhone] completes the change.
  Future<void> changePhone(String e164);
  Future<void> confirmPhone(String e164, String code);
  /// Revokes every session of this login (every device), including this one.
  Future<void> signOutEverywhere();
}

class SupabaseAccountAuth implements AccountAuth {
  SupabaseAccountAuth([SupabaseClient? client]) : _client = client;
  final SupabaseClient? _client;
  GoTrueClient get _auth => (_client ?? Supabase.instance.client).auth;

  @override
  Future<void> setDisplayName(String name) => _auth.updateUser(UserAttributes(data: {'full_name': name}));
  @override
  Future<void> changeEmail(String email) => _auth.updateUser(UserAttributes(email: email));
  @override
  Future<void> changePhone(String e164) => _auth.updateUser(UserAttributes(phone: e164));
  @override
  Future<void> confirmPhone(String e164, String code) => _auth.verifyOTP(phone: e164, token: code, type: OtpType.phoneChange);
  @override
  Future<void> signOutEverywhere() => _auth.signOut(scope: SignOutScope.global);
}
