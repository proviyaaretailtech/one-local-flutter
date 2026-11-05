import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/net_guard.dart';
import '../inventory/inventory_api.dart' show Facts;
import '../menu/menu_api.dart';
import '../menu/menu_build_api.dart';
import '../menu/menu_screen.dart';
import '../money/money_style.dart' show MoneyDarkCard, kMoneyDeepSoft, kMoneyLime, moneyCard;
import '../onboarding/document_picker.dart';
import '../setup/setup_api.dart' show ImagePicker;
import '../storefront/builder_screen.dart' show BuilderController;
import '../storefront/menu_link_screen.dart' show menuLinkReasons;
import '../storefront/sf_widgets.dart';
import '../storefront/storefront_api.dart';
import '../ui/motion.dart';
import '../ui/theme.dart';
import 'experience_api.dart';
import 'experience_cards.dart';
import 'experience_editors.dart';
import 'experience_import.dart';
import 'experience_widgets.dart';

// Guest experience (spec specs/guest-experience-builder §1): the restaurant's branded page for table QR codes and pre-orders. The person
// picks a look, edits the welcome screen and the blocks, sees a phone preview, and publishes. Every edit is saved as the draft at once
// (gx_draft_save, with the draft version they saw); Publish hands the saved draft to the database's gate, which answers live now,
// checking the wording, or sent to OneLocal.
// Spec part 2 (contract D): Create with AI fills the draft from the business profile and the menu (never publishes); Import menu reads a
// pasted menu into dishes the owner checks and adds through quick add; the Dishes & stock and Offers cards show what the page reads live.

/// Holds the page being edited and the builder answer it came from. A stale draft (changed on another device) reloads and says so.
class ExperienceController extends ChangeNotifier {
  ExperienceController(this.api, {required this.images});
  final ExperienceApi api;

  /// The storefront picture library (the welcome picture is a storefront picture, kind `banner`).
  final BuilderController images;
  Facts? state;
  String? error;
  bool busy = false;

  Map<String, dynamic> get draft => Map<String, dynamic>.from((state?.raw['draft'] as Map?) ?? const {});
  String get look => '${draft['look'] ?? 'bistro_dark'}';
  Map<String, String> get theme => {...gxLooks['bistro_dark']!, for (final e in ((draft['theme'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'};
  List<GxBlock> get blocks => ((draft['blocks'] as List?) ?? const []).whereType<Map>().map((e) => GxBlock(e.cast<String, dynamic>())).toList();
  GxBlock? block(String type) => blocks.where((b) => b.type == type).firstOrNull;
  int get draftVersion => state?.n('draft_version').toInt() ?? 0;
  int? get liveVersion => state?.no('live_version')?.toInt();
  bool get unpublished => state?.b('has_unpublished') ?? false;
  bool get canPublish => state?.b('can_publish') ?? false;
  List<Facts> get dishes => state?.l('dishes') ?? const [];
  List<Facts> get history => state?.l('history') ?? const [];
  Facts? get pending => state?.mo('pending');
  Facts? get lastDecision => state?.mo('last_decision');
  Facts get business => state?.m('business') ?? const Facts({});
  List<String> get blockers => state?.ls('blockers') ?? const [];

  // a load or save that answers after the screen closed has no one to tell
  bool _gone = false;
  @override
  void dispose() {
    _gone = true;
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_gone) super.notifyListeners();
  }

  Future<void> load() async {
    try {
      state = await api.builder();
      error = null;
    } catch (e) {
      error = errorSentence(e);
    }
    notifyListeners();
    await images.refreshImages();
    notifyListeners();
  }

  /// Takes the builder answer that came with a publish or a roll back.
  void take(Facts answer) {
    if (answer.raw.isEmpty) return;
    state = answer;
    notifyListeners();
  }

  /// Saves the whole page as the draft. Answers null when the server took it, else the sentence to show.
  Future<String?> save({String? look, Map<String, String>? theme, List<GxBlock>? blocks}) =>
      saveDefinition({'look': look ?? this.look, 'theme': theme ?? this.theme, 'blocks': [for (final b in blocks ?? this.blocks) b.toJson()]});

  /// Saves [definition] as the draft. A change made after Create with AI ends its Undo (Undo would lose that change).
  Future<String?> saveDefinition(Map<String, dynamic> definition, {bool undoing = false}) async {
    busy = true;
    notifyListeners();
    try {
      state = await api.saveDraft(draftVersion, definition);
      if (!undoing) _beforeAi = null;
      return null;
    } on ExperienceException catch (e) {
      if (!e.stale) return e.message;
      await load();
      return 'This page was changed on another device. It has been reloaded; please make your change again.';
    } catch (e) {
      return errorSentence(e);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  // ------------------------------------------------------------------------------------------------ Create with AI

  bool aiBusy = false;

  /// What the server says the AI filled (and left out); shown until the next AI run or Undo.
  String? aiNote;
  Map<String, dynamic>? _beforeAi;
  bool get canUndoAi => _beforeAi != null;

  /// The server reads the business profile and the menu, fills the DRAFT and answers the builder: the preview shows it at once.
  /// Answers null when the page was filled, else the sentence to show (AI not reachable, the page changed elsewhere, a refusal).
  Future<String?> createWithAi(String style) async {
    final before = draft;
    aiBusy = busy = true;
    notifyListeners();
    try {
      final r = await api.aiCreate(style: style);
      if (r.raw['draft'] is Map) {
        state = r;
      } else {
        await load();
      }
      aiNote = r.so('ai_note') ?? 'AI filled your page.';
      _beforeAi = before;
      return null;
    } on ExperienceException catch (e) {
      if (e.stale) {
        await load();
        return 'This page was changed on another device. It has been reloaded; try Create with AI again.';
      }
      return e.aiDown && e.message.isEmpty ? 'AI is not available right now. Try again in a minute, or edit the page yourself.' : e.message;
    } catch (e) {
      return errorSentence(e);
    } finally {
      aiBusy = busy = false;
      notifyListeners();
    }
  }

  /// Brings back the draft as it was before Create with AI.
  Future<String?> undoAi() async {
    final b = _beforeAi;
    if (b == null) return null;
    final msg = await saveDefinition(b, undoing: true);
    if (msg == null) {
      _beforeAi = null;
      aiNote = null;
    }
    return msg;
  }

  Future<String?> replace(GxBlock b) => save(blocks: [for (final x in blocks) x.type == b.type ? b : x]);
  Future<String?> setEnabled(String type, bool on) => save(blocks: [for (final x in blocks) x.type == type ? x.withEnabled(on) : x]);
  Future<String?> move(int from, int to) {
    final l = blocks;
    l.insert(to, l.removeAt(from));
    return save(blocks: l);
  }

  /// A ready-made look brings its colours; "custom" keeps the ones there now.
  Future<String?> setLook(String look) => save(look: look, theme: look == 'custom' ? theme : {...gxLooks[look]!});

  /// New colours: the look they match, else "custom".
  Future<String?> setTheme(Map<String, String> t) {
    final match = gxLooks.entries.where((e) => e.value.entries.every((c) => (t[c.key] ?? '').toUpperCase() == c.value.toUpperCase())).firstOrNull;
    return save(look: match?.key ?? 'custom', theme: t);
  }
}

class ExperienceScreen extends StatefulWidget {
  const ExperienceScreen({super.key, this.api, this.storefront, this.picker = const ImagePicker(), this.linkBase, this.onOpen, this.menu, this.menuBuild,
      this.pickMenuFile = pickMenuTextFile, this.today});
  final ExperienceApi? api;

  /// The menu (dishes, stock: rst_menu, rst_menu_stock_set) and the menu builder (categories, quick add); by default through the same door.
  final MenuApi? menu;
  final MenuBuildApi? menuBuild;

  /// Picks the .csv / .txt file for Import menu (tests pass a fake; null hides the button).
  final MenuFilePicker? pickMenuFile;

  /// Tests fix "now" (coupon end dates).
  final DateTime? today;

  /// The storefront picture library and uploads (sf_image_library, storefront_image_slot / _attach).
  final StorefrontApi? storefront;
  final DocumentPicker picker;

  /// Tests fix the link's address and catch "Open".
  final String? linkBase;
  final Future<void> Function(Uri uri)? onOpen;

  static Route<void> route() => MaterialPageRoute(settings: const RouteSettings(name: 'guest-experience'), builder: (_) => const ExperienceScreen());

  @override
  State<ExperienceScreen> createState() => _ExperienceScreenState();
}

class _ExperienceScreenState extends State<ExperienceScreen> {
  late final StorefrontApi _storefront = widget.storefront ?? StorefrontApi();
  late final ExperienceController c = ExperienceController(
    widget.api ?? ExperienceApi(),
    images: BuilderController(_storefront, picker: widget.picker),
  )..addListener(_changed);
  late final MenuApi _menu = widget.menu ?? MenuApi(rpc: c.api.rpc);
  late final MenuBuildApi _menuBuild = widget.menuBuild ?? MenuBuildApi(rpc: c.api.rpc);
  bool _publishing = false;

  /// Bumped when the menu may have changed elsewhere (Import menu, the full Menu screen): the dishes card reads it again.
  int _menuGen = 0;

  @override
  void initState() {
    super.initState();
    c.load();
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _open(Uri u) => (widget.onOpen ?? (u) => launchUrl(u, mode: LaunchMode.externalApplication).then((_) {}))(u);

  String? get _url {
    final path = c.business.so('path');
    return path == null ? null : ExperienceApi.urlFor(path, base: widget.linkBase);
  }

  Future<void> _after(Future<String?> saved) async {
    final msg = await saved;
    if (msg != null && mounted) showToast(context, msg);
  }

  Future<void> _edit(GxBlock b) async {
    final out = await editBlock(context, b, c);
    if (out != null) await _after(c.replace(out));
  }

  Future<void> _colours() async {
    final t = await editColours(context, c.theme);
    if (t != null) await _after(c.setTheme(t));
  }

  /// After Import menu or the full Menu screen: the dishes card and the builder (its dish list, the preview's dish) read again.
  Future<void> _menuChanged() async {
    if (!mounted) return;
    setState(() => _menuGen++);
    await c.load();
  }

  Future<void> _import() async {
    await Navigator.of(context).push(MaterialPageRoute<int>(builder: (_) => GxImportScreen(api: c.api, menu: _menuBuild, pickFile: widget.pickMenuFile)));
    await _menuChanged();
  }

  Future<void> _openMenu() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => MenuScreen(api: _menu, buildApi: _menuBuild)));
    await _menuChanged();
  }

  Future<void> _publish() async {
    setState(() => _publishing = true);
    try {
      final r = await c.api.publish(draftVersion: c.draftVersion);
      c.take(r.m('builder'));
      final path = r.so('path') ?? c.business.so('path');
      if (!mounted) return;
      setState(() => _publishing = false);
      await showPublishOutcome(context, r, link: path == null ? null : ExperienceApi.urlFor(path, base: widget.linkBase), onOpen: _open);
    } on ExperienceException catch (e) {
      if (e.stale) await c.load();
      if (mounted) showToast(context, e.stale ? 'The page changed since you last looked. It has been reloaded; check it and publish again.' : e.message);
    } catch (e) {
      if (mounted) showToast(context, errorSentence(e));
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  Future<void> _rollback(int version) async {
    final ok = await showOlDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('gx-rollback-dialog'),
        title: Text('Bring back version $version?'),
        content: Text('Guests see version $version again, and your draft becomes that version too.', style: inter(14, 400, color: kMuted)),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(key: const ValueKey('gx-rollback-confirm'), onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Roll back')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _publishing = true);
    try {
      final r = await c.api.rollback(version);
      c.take(r.m('builder'));
      if (!mounted) return;
      setState(() => _publishing = false);
      await showPublishOutcome(context, r, link: _url, onOpen: _open);
    } catch (e) {
      if (mounted) showToast(context, errorSentence(e));
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  // ------------------------------------------------------------------------------------------------ pieces

  /// What OneLocal is doing with the last publish, or what it said: waiting, a question, or a refusal with the reason.
  Widget? _banner() {
    final p = c.pending;
    final d = c.lastDecision;
    final (String key, IconData icon, Color bg, Color fg, String title, String? body)? b = p != null
        ? p.s('ask_message').isNotEmpty
            ? ('gx-banner-ask', LucideIcons.messageCircleQuestion, const Color(0xFFE5EDFF), const Color(0xFF1D4ED8), 'OneLocal has a question about version ${p.n('version').toInt()}', p.s('ask_message'))
            : p.s('status') == 'pending_ai'
                ? ('gx-banner-checking', LucideIcons.loader, const Color(0xFFE5EDFF), const Color(0xFF1D4ED8), 'Checking the wording of version ${p.n('version').toInt()}…', 'Guests see the last approved page until then.')
                : ('gx-banner-waiting', LucideIcons.clock, const Color(0xFFFFF4E5), const Color(0xFFB45309), 'Version ${p.n('version').toInt()} is waiting for OneLocal', p.so('summary'))
        : d != null && d.s('status') == 'rejected'
            ? ('gx-banner-rejected', LucideIcons.circleX, const Color(0xFFFEE2E2), const Color(0xFFB91C1C), 'OneLocal did not approve version ${d.n('version').toInt()}', d.so('review_note') ?? d.so('summary'))
            : null;
    if (b == null) return null;
    return Container(
      key: ValueKey(b.$1),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: b.$3, borderRadius: BorderRadius.circular(16)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(b.$2, size: 20, color: b.$4),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(b.$5, style: inter(15, 800, color: b.$4)),
            if (b.$6 != null && b.$6!.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 3), child: Text(b.$6!, style: inter(13.5, 500, height: 1.35))),
          ]),
        ),
      ]),
    );
  }

  Widget _status() {
    final live = c.liveVersion;
    final (label, dot) = live == null
        ? ('Not published yet', const Color(0xFFFFB547))
        : c.unpublished
            ? ('Draft', const Color(0xFFFFB547))
            : ('Live · v$live', kMoneyLime);
    return MoneyDarkCard(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('Your guest page', style: inter(17, 800, color: Colors.white))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(color: kMoneyDeepSoft, borderRadius: BorderRadius.circular(40)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 7, height: 7, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
              const SizedBox(width: 5),
              Text(label, key: const ValueKey('gx-status'), style: inter(11.5, 700, color: Colors.white)),
            ]),
          ),
        ]),
        const SizedBox(height: 6),
        Text(
          c.unpublished ? 'Changes are saved as a draft. Publish to show them to guests.' : 'What guests see when they scan a table QR or open your link.',
          style: inter(12.5, 500, color: const Color(0xFFB8BCC4)),
        ),
      ]),
    );
  }

  Widget _link() {
    final url = _url;
    final reasons = c.blockers;
    final live = reasons.isEmpty && url != null;
    return Container(
      key: ValueKey(live ? 'gx-link-live' : 'gx-link-off'),
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(14),
      decoration: moneyCard(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(live ? LucideIcons.circleCheck : LucideIcons.circleAlert, color: live ? kLink : const Color(0xFFB45309), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(live ? 'Your guest page is open' : 'Not open to guests yet', style: inter(15, 800)),
              for (final r in reasons) Padding(padding: const EdgeInsets.only(top: 3), child: Text(menuLinkReasons[r] ?? r, style: inter(13, 400, color: kMuted))),
              if (url != null) Padding(padding: const EdgeInsets.only(top: 6), child: SelectableText(url, key: const ValueKey('gx-link-url'), style: inter(13.5, 600, color: kInk))),
            ]),
          ),
        ]),
        if (url != null) ...[
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                key: const ValueKey('gx-link-copy'),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: url));
                  if (mounted) showToast(context, 'Link copied.');
                },
                icon: const Icon(LucideIcons.copy, size: 16),
                label: const Text('Copy'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                key: const ValueKey('gx-link-share'),
                // WhatsApp is how restaurants here share a link; the text is only the public address
                onPressed: () => _open(Uri.parse('https://wa.me/?text=${Uri.encodeComponent(url)}')),
                icon: const Icon(LucideIcons.share2, size: 16),
                label: const Text('Share'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                key: const ValueKey('gx-link-open'),
                style: FilledButton.styleFrom(backgroundColor: kInk, foregroundColor: Colors.white),
                onPressed: live ? () => _open(Uri.parse(url)) : null,
                icon: const Icon(LucideIcons.externalLink, size: 16),
                label: const Text('Open'),
              ),
            ),
          ]),
        ],
      ]),
    );
  }

  Widget _looks() {
    final look = c.look;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        for (final k in const ['bistro_dark', 'bakery_warm', 'custom']) ...[
          if (k != 'bistro_dark') const SizedBox(width: 10),
          Expanded(
            child: GxLookTile(
              key: ValueKey('gx-look-$k'),
              name: gxLookNames[k]!,
              colours: k == 'custom' ? c.theme : gxLooks[k]!,
              selected: look == k,
              onTap: () => look == k ? (k == 'custom' ? _colours() : null) : _after(c.setLook(k)),
            ),
          ),
        ],
      ]),
      const SizedBox(height: 10),
      SfSoft('Edit colours & font', key: const ValueKey('gx-colours'), icon: LucideIcons.palette, onPressed: _colours),
    ]);
  }

  Widget _blockCard(GxBlock b, int i) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: moneyCard(),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: ValueKey('gx-block-${b.type}'),
            borderRadius: BorderRadius.circular(22),
            onTap: () => _edit(b),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 8, 8),
              child: Row(children: [
                ReorderableDragStartListener(
                  index: i,
                  child: const Padding(padding: EdgeInsets.symmetric(horizontal: 6, vertical: 10), child: Icon(LucideIcons.gripVertical, size: 18, color: kMuted)),
                ),
                Expanded(
                  child: Opacity(
                    opacity: b.enabled ? 1 : 0.55,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(b.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(15, 800)),
                      const SizedBox(height: 2),
                      Text(gxBlockWhat(b.type), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12, 500, color: kMuted)),
                    ]),
                  ),
                ),
                // a block the page cannot work without shows a lock instead of a switch
                if (b.required)
                  Tooltip(
                    message: 'Always on',
                    child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Icon(LucideIcons.lock, key: ValueKey('gx-lock-${b.type}'), size: 17, color: kMuted)),
                  )
                else
                  Semantics(
                    label: b.label,
                    toggled: b.enabled,
                    child: Switch(
                      key: ValueKey('gx-switch-${b.type}'),
                      value: b.enabled,
                      onChanged: c.busy ? null : (v) => _after(c.setEnabled(b.type, v)),
                      activeThumbColor: Colors.white,
                      activeTrackColor: kSfLime,
                      inactiveTrackColor: const Color(0xFFD1D5DB),
                      inactiveThumbColor: Colors.white,
                      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
                    ),
                  ),
                const Icon(LucideIcons.chevronRight, size: 18, color: kMuted),
              ]),
            ),
          ),
        ),
      );

  Widget _rules() => Container(
        key: const ValueKey('gx-rules'),
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: const Color(0xFFF7F8F6), borderRadius: BorderRadius.circular(16), border: Border.all(color: kLine)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('When does a change go live?', style: inter(15, 800)),
          const SizedBox(height: 8),
          for (final (icon, text) in const [
            (LucideIcons.zap, 'Right away: colours, look, font, photos, the order of blocks and switching blocks on or off.'),
            (LucideIcons.sparkles, 'In a few seconds: new wording. OneLocal\'s AI reads it first.'),
            (LucideIcons.shieldCheck, 'After OneLocal review: prices, offers, discounts, phone numbers or links in any text; switching dine-in or pre-order on or off; turning off split bill, feedback or the expected time.'),
          ])
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(icon, size: 16, color: kMuted),
                const SizedBox(width: 8),
                Expanded(child: Text(text, style: inter(13, 500, height: 1.35))),
              ]),
            ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final list = c.blocks;
    final welcome = c.block('welcome')?.props ?? const <String, dynamic>{};
    final picks = (c.block('highlights')?.props['pick_ids'] as List?)?.map((e) => '$e').toSet() ?? const <String>{};
    // the preview's sample dish: a chef's pick with a photo, else any dish with a photo, else the first pick or dish
    bool photo(Facts d) => (d.so('image_url') ?? '').trim().isNotEmpty;
    final picked = c.dishes.where((d) => picks.contains(d.s('id')));
    final dish = picked.where(photo).firstOrNull ?? c.dishes.where(photo).firstOrNull ?? picked.firstOrNull ?? c.dishes.firstOrNull;
    final banner = c.state == null ? null : _banner();
    return SfPage(
      title: 'Guest experience',
      subtitle: 'Your branded page for table QR and pre-orders',
      bottom: c.state == null
          ? null
          : Column(mainAxisSize: MainAxisSize.min, children: [
              if (!c.canPublish)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text('Your role can edit the page but cannot publish it. Ask the owner or a manager.', key: const ValueKey('gx-no-publish'), textAlign: TextAlign.center, style: inter(12.5, 500, color: kMuted)),
                ),
              SfSave(
                c.unpublished ? 'Publish' : 'Up to date',
                key: const ValueKey('gx-publish'),
                lime: true,
                busy: _publishing,
                onPressed: c.canPublish && c.unpublished && !c.busy ? _publish : null,
              ),
            ]),
      children: [
        if (c.state == null && c.error != null)
          SfCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Could not load your guest page', style: inter(15, 700)),
              const SizedBox(height: 6),
              Text(c.error!, key: const ValueKey('gx-error'), style: inter(13, 400, color: kMuted)),
              const SizedBox(height: 10),
              SfSoft('Try again', onPressed: c.load),
            ]),
          )
        else if (c.state == null)
          const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: kInk)))
        else ...[
          ?banner,
          GxAiCard(c: c),
          _status(),
          _link(),
          const SfLabel('Preview'),
          GxPhonePreview(
            theme: c.theme,
            welcome: welcome,
            orderMode: c.block('order_mode')?.props ?? const {},
            imageUrl: c.images.imageUrl(welcome['image_id'] as String?),
            dish: dish,
            businessName: c.business.s('name'),
          ),
          const SfLabel('Look'),
          _looks(),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 22, 4, 10),
            child: Row(children: [
              Expanded(child: Text('Blocks', style: inter(17, 800))),
              const Icon(LucideIcons.gripVertical, size: 14, color: kMuted),
              Text(' Drag to reorder', style: inter(12, 500, color: kMuted)),
            ]),
          ),
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: list.length,
            onReorderItem: (a, b) => _after(c.move(a, b)),
            itemBuilder: (_, i) => KeyedSubtree(key: ValueKey(list[i].type), child: _blockCard(list[i], i)),
          ),
          if (c.busy && !c.aiBusy) const Padding(padding: EdgeInsets.only(bottom: 8), child: LinearProgressIndicator(color: kInk, backgroundColor: kLine)),
          GxStockCard(menu: _menu, generation: _menuGen, onImport: _import, onOpenMenu: _openMenu),
          GxOffersCard(storefront: _storefront, api: c.api, today: widget.today),
          const SizedBox(height: 12),
          _rules(),
          if (c.history.isNotEmpty) ...[
            const SfLabel('History'),
            for (final v in c.history)
              GxHistoryRow(v: v, liveVersion: c.liveVersion, canRollBack: c.canPublish && !_publishing, onRollBack: () => _rollback(v.n('version').toInt())),
          ],
        ],
      ],
    );
  }
}
