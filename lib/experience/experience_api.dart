import 'package:http/http.dart' as http;

import '../api/rpc_client.dart';
import '../auth/partner_api.dart';
import '../inventory/inventory_api.dart' show Facts;
import '../storefront/menu_link_screen.dart' show MenuLinkApi;

/// The guest experience builder (database 0654, spec specs/guest-experience-builder) through the one generic door, `POST /rpc/<gx_function>`
/// ([RpcClient]). The database cleans every draft (`gx__clean`), decides how risky a publish is and whether it goes live now, after the AI
/// reads the wording, or after a OneLocal person looks. This app only edits the draft and shows the answer.
class ExperienceApi {
  ExperienceApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc})
      : _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);

  final RpcClient _rpc;

  /// The same door, for the menu and offers calls the builder makes beside the page (dishes, stock, offers).
  RpcClient get rpc => _rpc;

  Future<Facts> _c(String fn, [Map<String, Object?> args = const {}]) async {
    try {
      return Facts(await _rpc.callMap(fn, {...args}..removeWhere((_, v) => v == null)));
    } on RpcException catch (e) {
      throw ExperienceException(e.status, e.message, e.code);
    }
  }

  /// `{draft, draft_version, has_unpublished, live_version, live, pending, last_decision, history, business, blockers, can_publish, dishes}`.
  Future<Facts> builder() => _c('gx_builder_get');

  /// Stores the draft (the server cleans it); answers the same shape as [builder].
  Future<Facts> saveDraft(int draftVersion, Map<String, dynamic> definition) => _c('gx_draft_save', {'expected_draft_version': draftVersion, 'definition': definition});

  /// Publishes the SAVED draft the person saw. `{result, version, path, builder}`; result is auto_approved, ai_approved, pending_ai or pending_human.
  Future<Facts> publish({required int draftVersion}) => _c('gx_publish', {'expected_draft_version': draftVersion});

  /// Brings an earlier approved version back as a new one. `{result, version, builder}`.
  Future<Facts> rollback(int version) => _c('gx_rollback', {'version': version});

  /// Create with AI (POS server, Groq): fills the DRAFT from the business profile and the menu (look, colours, welcome words, chef's picks,
  /// limited today, order labels) through the person's own draft save; never publishes. Answers the builder shape plus `ai_note`.
  /// AI not reachable: [ExperienceException] with [ExperienceException.aiDown].
  Future<Facts> aiCreate({String? style}) {
    final s = style?.replaceAll(RegExp(r'\s+'), ' ').trim();
    return _c('gx_ai_create', {'style': (s == null || s.isEmpty) ? null : s});
  }

  /// Import menu: the AI reads pasted text or CSV into proposed dishes `{dishes:[{name, category, price, veg, description}], dropped}`.
  /// Nothing is saved; the screen adds the dishes the person keeps through the menu's own quick add.
  Future<List<GxImportDish>> aiImportMenu(String text) async =>
      (await _c('menu_ai_import', {'text': text.trim()})).l('dishes').map(GxImportDish.fromFacts).toList();

  /// The business's coupons (`pos_coupon_list`); roles that may not see coupons get an [ExperienceException].
  Future<List<Facts>> coupons() async => (await _c('pos_coupon_list')).l('coupons');

  /// `<guest web base><path>`: the same base the menu link and table QR codes use.
  static String urlFor(String path, {String? base}) => MenuLinkApi.urlFor(path, base: base);
}

class ExperienceException extends PartnerApiException {
  const ExperienceException(super.status, super.message, this.code);
  final String? code;

  /// The draft changed on another device (GX_STALE: the server's family code, or the shared `version_conflict`).
  bool get stale => code == 'version_conflict' || code == 'stale' || code == 'GX_STALE';

  /// The AI was not reachable, timed out or gave nothing usable (503): nothing changed.
  bool get aiDown => code == 'ai_unavailable';
}

/// One dish the AI read from a pasted menu, as the person reviews it before it is added. Every rule is checked again by the database
/// when it is added (menu_item_quick_add: role, name, category, price).
class GxImportDish {
  GxImportDish({required this.name, required this.category, required this.price, this.foodType = 'veg', this.vegKnown = true, this.description});
  factory GxImportDish.fromFacts(Facts f) {
    final veg = f.raw['veg'];
    return GxImportDish(
      name: f.s('name'),
      category: f.s('category'),
      price: f.no('price')?.toDouble(),
      foodType: veg == false ? 'non_veg' : 'veg',
      vegKnown: veg is bool,
      description: f.so('description'),
    );
  }
  String name, category, foodType;
  double? price;
  final String? description;

  /// False when the menu did not say veg or not: the screen asks the person to check.
  final bool vegKnown;
  bool include = true, added = false;
  String? error;

  /// What is wrong before it can be added, in the words the quick add uses; null when it is ready.
  String? get problem => name.trim().length < 2
      ? 'Enter the dish name.'
      : category.trim().isEmpty
          ? 'Enter a category.'
          : (price == null || price! <= 0)
              ? 'Enter a selling price above zero.'
              : null;
  bool get ready => include && !added && problem == null;
}

/// The two ready-made looks; "custom" keeps whatever colours the restaurant set.
const gxLooks = <String, Map<String, String>>{
  'bistro_dark': {'background': '#0E0E0E', 'surface': '#1C1C1C', 'text': '#FFFFFF', 'muted': '#A3A3A3', 'accent': '#F5B83D', 'accent_text': '#111111', 'font': 'sans'},
  'bakery_warm': {'background': '#F6F1EA', 'surface': '#FFFFFF', 'text': '#2B1D14', 'muted': '#8A7766', 'accent': '#2B1D14', 'accent_text': '#FFFFFF', 'font': 'serif'},
};

const gxLookNames = {'bistro_dark': 'Bistro dark', 'bakery_warm': 'Bakery warm', 'custom': 'Custom'};

/// The six colours, in the order the colour sheet shows them, with the words the server uses in its sentences.
const gxColourKeys = <(String, String)>[
  ('background', 'Background'),
  ('surface', 'Cards'),
  ('text', 'Text'),
  ('muted', 'Soft text'),
  ('accent', 'Buttons'),
  ('accent_text', 'Button text'),
];

/// Blocks a guest page cannot work without (gx__required_types): always present, always on.
const gxRequired = {'welcome', 'order_mode', 'swipe', 'tracking', 'bill'};

/// One block of the page as the draft holds it: `{id, type, enabled, props}`. Editing returns a changed copy.
class GxBlock {
  GxBlock(Map<String, dynamic> raw) : raw = Map<String, dynamic>.from(raw)..['props'] = Map<String, dynamic>.from((raw['props'] as Map?) ?? const {});
  final Map<String, dynamic> raw;
  String get id => '${raw['id'] ?? raw['type']}';
  String get type => '${raw['type']}';
  bool get required => gxRequired.contains(type);
  bool get enabled => required || raw['enabled'] != false;
  Map<String, dynamic> get props => raw['props'] as Map<String, dynamic>;
  String get label => gxBlockLabel(type);
  GxBlock copy() => GxBlock({...raw, 'props': {...props}});
  GxBlock withProps(Map<String, dynamic> p) => GxBlock({...raw, 'props': p});
  GxBlock withEnabled(bool on) => GxBlock({...raw, 'enabled': on});
  Map<String, dynamic> toJson() => raw;
}

String gxBlockLabel(String type) => const {
      'welcome': 'Welcome screen',
      'order_mode': 'Dine-in or pre-order',
      'budget': 'Table budget',
      'categories': 'Categories',
      'swipe': 'Swipe deck',
      'highlights': "Chef's picks & limited today",
      'preorder': 'Pre-order slots',
      'tracking': 'Order tracking',
      'bill': 'Bill & feedback',
    }[type] ??
    type;

/// What a block is, in a few words, under its name.
String gxBlockWhat(String type) => const {
      'welcome': 'Headline, line, picture and button',
      'order_mode': 'How guests order',
      'budget': 'Guests set a budget and see it fill',
      'categories': 'Your menu categories as tiles',
      'swipe': 'Dishes as cards to swipe',
      'highlights': 'Dishes you want guests to see first',
      'preorder': 'Days, hours and time slots',
      'tracking': 'Live status after ordering',
      'bill': 'Split the bill, leave feedback',
    }[type] ??
    'A part of your guest page';

/// The status of a published version, in plain words.
String gxStatusLabel(String status) => const {
      'pending_ai': 'Checking wording',
      'pending_human': 'With OneLocal',
      'auto_approved': 'Approved',
      'ai_approved': 'Approved',
      'human_approved': 'Approved by OneLocal',
      'rejected': 'Not approved',
      'superseded': 'Replaced',
    }[status] ??
    status;

bool gxApproved(String status) => status == 'auto_approved' || status == 'ai_approved' || status == 'human_approved';

/// Plain words for the review categories.
String gxCategoryLabel(String c) => const {'money': 'Money', 'compliance': 'Rules for guests', 'security': 'Safety', 'content': 'Wording'}[c] ?? c;

/// What the server refuses in any text (no markup).
bool gxTextOk(String s) => !s.contains('<') && !s.contains('>');
