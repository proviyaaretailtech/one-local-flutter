import '../api/rpc_client.dart';
import '../auth/partner_api.dart';

/// Returns, refunds & replacements (founder's spec, 29 Oct 2026, Phase 1 "Policy foundation"): the store picks one of OneLocal's
/// approved policies for each category once; every item in it follows that policy; every change is a new version the owner agrees to.
class ReturnsApi {
  ReturnsApi({RpcClient? rpc}) : _rpc = rpc ?? RpcClient();
  final RpcClient _rpc;

  Future<Map<String, dynamic>> _call(String fn, Map<String, Object?> args) async {
    try {
      return await _rpc.callMap(fn, {...args});
    } on RpcException catch (e) {
      throw PartnerApiException(e.status, e.message);
    }
  }

  /// can_edit, templates [...], categories [{id, name, items, suggested, policy, versions}], default (the "All other items" policy
  /// or null), uncategorised_items, dispatch_photo, bulk_items.
  Future<Map<String, dynamic>> home() => _call('rr_home', {});

  /// With [preview] true: {terms, label, categories} to show before agreeing, nothing saved. Otherwise [agree] must be true:
  /// {policies [...], label}. A null in [categoryIds] means "All other items".
  Future<Map<String, dynamic>> savePolicy(PolicyChoice c, {required List<String?> categoryIds, bool preview = false, bool agree = false}) =>
      _call('rr_policy_save', {
        'category_ids': categoryIds,
        ...c.toJson(),
        if (preview) 'preview': true,
        if (agree) 'agree': true,
      });

  /// Every version of one category's policy (null: "All other items"), newest first. {versions [...]}
  Future<Map<String, dynamic>> history(String? categoryId) => _call('rr_history', {'category_id': categoryId});

  /// The store's handover rules; answers the whole page again.
  Future<Map<String, dynamic>> saveSettings({bool? dispatchPhoto, int? bulkItems}) => _call('rr_settings_save', {
        'dispatch_photo': ?dispatchPhoto,
        'bulk_items': ?bulkItems,
      });
}

/// One of OneLocal's approved policies, with the limits the store may choose within.
class RrTemplate {
  RrTemplate(this.j);
  final Map<String, dynamic> j;
  String get id => j['id'] as String;
  String get name => j['name'] as String? ?? id;
  String get blurb => j['blurb'] as String? ?? '';
  bool get changeAllowed => j['change_of_mind_allowed'] == true;
  int get minHours => (j['min_hours'] as num?)?.toInt() ?? 24;
  int get maxHours => (j['max_hours'] as num?)?.toInt() ?? 168;
  int get defaultHours => (j['default_hours'] as num?)?.toInt() ?? 72;
  List<String> get remedies => [for (final r in j['remedies'] as List? ?? const []) r as String];

  /// The windows the store may pick: a few hours (for fresh food), then whole days.
  List<int> get windows => {
        for (final h in const [2, 4, 6, 12]) if (h >= minHours && h <= maxHours) h,
        for (var d = 1; d * 24 <= maxHours; d++) if (d * 24 >= minHours) d * 24,
      }.toList()
        ..sort();

  PolicyChoice defaults() => PolicyChoice(
        templateId: id,
        changeOfMind: changeAllowed && j['default_change_of_mind'] == true,
        windowHours: defaultHours,
        remedies: {for (final r in j['default_remedies'] as List? ?? const []) r as String},
        sealedOnly: j['default_sealed_only'] == true,
        inspection: j['default_inspection'] == true,
      );
}

/// What the store picked for a category.
class PolicyChoice {
  PolicyChoice({required this.templateId, required this.changeOfMind, required this.windowHours, required this.remedies, required this.sealedOnly, required this.inspection});
  String templateId;
  bool changeOfMind, sealedOnly, inspection;
  int windowHours;
  Set<String> remedies;

  /// From a saved policy (rr__policy_json).
  factory PolicyChoice.fromPolicy(Map<String, dynamic> p) => PolicyChoice(
        templateId: p['template_id'] as String,
        changeOfMind: p['change_of_mind'] == true,
        windowHours: (p['window_hours'] as num).toInt(),
        remedies: {for (final r in p['remedies'] as List? ?? const []) r as String},
        sealedOnly: p['sealed_only'] == true,
        inspection: p['inspection'] == true,
      );

  Map<String, Object?> toJson() => {
        'template_id': templateId,
        'change_of_mind': changeOfMind,
        'window_hours': windowHours,
        'remedies': [for (final r in kRemedies.keys) if (remedies.contains(r)) r],
        'sealed_only': changeOfMind && sealedOnly,
        'inspection': inspection,
      };

  /// The line customers see before paying; the same words the database saves (rr__label).
  String get label => changeOfMind
      ? 'Returns within ${windowWords(windowHours)}${sealedOnly ? ' · sealed items only' : ''}'
      : 'No change-of-mind returns · report issues within ${windowWords(windowHours)}';
}

/// OneLocal's order of the ways a store makes it right.
const kRemedies = {'refund': 'Refund', 'replacement': 'Replacement', 'exchange': 'Exchange', 'repair': 'Repair'};

/// What customers can always claim, whatever the store's policy says.
const kAlwaysCovered = ['Wrong item', 'Missing item', 'Damaged on arrival', 'Expired', 'Defective', 'Unsafe or spoiled', 'Not as described'];

/// "3 days" / "24 hours" / "1 day" (the database's rr__window).
String windowWords(int hours) {
  if (hours % 24 == 0) {
    final d = hours ~/ 24;
    return d == 1 ? '1 day' : '$d days';
  }
  return hours == 1 ? '1 hour' : '$hours hours';
}
