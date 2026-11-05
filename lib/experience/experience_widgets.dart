import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_api.dart' show Facts;
import '../orders/order_widgets.dart' show TagChip;
import '../storefront/sf_widgets.dart';
import '../ui/motion.dart';
import '../ui/theme.dart';
import 'experience_api.dart';
import 'experience_editors.dart' show gxPrice;

/// The draft as a guest's phone would show its first screen: the colours and font, the welcome picture, headline, line and button(s),
/// and one dish card in the card colour. It is a picture of the look, not the guest app itself; dishes come from the menu.
class GxPhonePreview extends StatelessWidget {
  const GxPhonePreview({super.key, required this.theme, required this.welcome, required this.orderMode, this.imageUrl, this.dish, this.businessName = ''});
  final Map<String, String> theme;
  final Map<String, dynamic> welcome, orderMode;
  final String? imageUrl;
  final Facts? dish;
  final String businessName;

  /// Headings in the device's serif when the restaurant chose one, as the guest page does (no serif is bundled: Inter where none exists).
  TextStyle _t(double size, int weight, Color color, {bool display = false}) {
    final base = inter(size, weight, color: color);
    return theme['font'] == 'serif' && display ? base.copyWith(fontFamily: 'serif', fontFamilyFallback: const ['Inter']) : base;
  }

  @override
  Widget build(BuildContext context) {
    final bg = hexColor(theme['background']), surface = hexColor(theme['surface']), text = hexColor(theme['text']), muted = hexColor(theme['muted']);
    final accent = hexColor(theme['accent']), accentText = hexColor(theme['accent_text']);
    final dine = orderMode['dine_in'] != false, pre = orderMode['pre_order'] == true;
    final sub = welcome['subtext'] as String?;
    final d = dish;
    Widget button(String label, {required bool filled, Key? key}) => Container(
          key: key,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: filled ? accent : Colors.transparent, borderRadius: BorderRadius.circular(40), border: filled ? null : Border.all(color: text.withValues(alpha: 0.5))),
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: _t(13.5, 800, filled ? accentText : text)),
        );
    return Center(
      child: Container(
        key: const ValueKey('gx-preview'),
        width: 252,
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(color: const Color(0xFF0A0A0A), borderRadius: BorderRadius.circular(36)),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(29),
          child: Container(
            color: bg,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Text('9:41', style: _t(10.5, 700, text)),
                const Spacer(),
                Icon(LucideIcons.wifi, size: 11, color: text),
                const SizedBox(width: 4),
                Icon(LucideIcons.batteryFull, size: 12, color: text),
              ]),
              const SizedBox(height: 10),
              if (businessName.isNotEmpty) Text(businessName, maxLines: 1, overflow: TextOverflow.ellipsis, style: _t(13, 800, text, display: true)),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: SizedBox(
                  height: 132,
                  child: imageUrl == null
                      ? Container(color: surface, child: Icon(LucideIcons.utensilsCrossed, size: 34, color: muted))
                      : Image.network(imageUrl!, fit: BoxFit.cover, errorBuilder: (_, _, _) => Container(color: surface, child: Icon(LucideIcons.image, size: 34, color: muted))),
                ),
              ),
              const SizedBox(height: 12),
              Text('${welcome['headline'] ?? ''}', key: const ValueKey('gx-preview-headline'), style: _t(20, 800, text, display: true).copyWith(height: 1.15)),
              if (sub != null && sub.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(sub, style: _t(12, 500, muted).copyWith(height: 1.35))),
              const SizedBox(height: 12),
              button('${welcome['cta_label'] ?? 'Start exploring'}', filled: true, key: const ValueKey('gx-preview-cta')),
              if (pre && dine) ...[const SizedBox(height: 8), button('${orderMode['pre_order_label'] ?? 'Pre-order'}', filled: false)],
              if (pre && !dine) ...[const SizedBox(height: 8), Text('Pre-orders only', textAlign: TextAlign.center, style: _t(11, 600, muted))],
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: surface, borderRadius: BorderRadius.circular(16)),
                child: Row(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(
                      width: 46,
                      height: 46,
                      child: d?.so('image_url') == null
                          ? Container(color: bg, child: Icon(LucideIcons.soup, size: 20, color: muted))
                          : Image.network(d!.s('image_url'), fit: BoxFit.cover, errorBuilder: (_, _, _) => Container(color: bg)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(d?.s('name') ?? 'A dish from your menu', maxLines: 1, overflow: TextOverflow.ellipsis, style: _t(12.5, 700, text)),
                      Text(d == null ? '₹ —' : gxPrice(d.no('price')), style: _t(11.5, 600, muted)),
                    ]),
                  ),
                  Container(width: 26, height: 26, decoration: BoxDecoration(color: accent, shape: BoxShape.circle), child: Icon(LucideIcons.plus, size: 15, color: accentText)),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// "Look" tile: the name and four dots of its colours; the chosen one has the lime outline.
class GxLookTile extends StatelessWidget {
  const GxLookTile({super.key, required this.name, required this.colours, required this.selected, required this.onTap});
  final String name;
  final Map<String, String> colours;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        label: name,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
            decoration: BoxDecoration(
              color: selected ? kSfLimeSoft : Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: selected ? kSfLimeLine : kLine, width: selected ? 1.5 : 1),
            ),
            child: Column(children: [
              Container(
                height: 34,
                decoration: BoxDecoration(color: hexColor(colours['background']), borderRadius: BorderRadius.circular(10), border: Border.all(color: kLine)),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  for (final k in ['surface', 'text', 'accent'])
                    Container(width: 12, height: 12, margin: const EdgeInsets.symmetric(horizontal: 2), decoration: BoxDecoration(color: hexColor(colours[k]), shape: BoxShape.circle, border: Border.all(color: Colors.black12))),
                ]),
              ),
              const SizedBox(height: 8),
              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(13, selected ? 800 : 600)),
            ]),
          ),
        ),
      );
}

/// A value of a change, in words: on/off, a list as "n dishes", text as it is, nothing as "—".
String gxValue(Object? v) => switch (v) {
      null => '—',
      true => 'on',
      false => 'off',
      final List l => l.isEmpty ? 'none' : '${l.length} item${l.length == 1 ? '' : 's'}',
      final String s => s.isEmpty ? '—' : s,
      _ => '$v',
    };

/// One change of a publish: what, from → to, and why it waits (when it does).
class GxChangeRow extends StatelessWidget {
  const GxChangeRow(this.change, {super.key});
  final Facts change;
  @override
  Widget build(BuildContext context) {
    final why = change.so('why');
    final high = change.s('risk') == 'high';
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: high ? const Color(0xFFFFF4E5) : const Color(0xFFF7F8F6), borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(change.s('label'), style: inter(13.5, 700)),
        const SizedBox(height: 2),
        Text('${gxValue(change.raw['from'])}  →  ${gxValue(change.raw['to'])}', style: inter(13, 500, color: kMuted)),
        if (why != null && why.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2), child: Text(why, style: inter(12.5, 600, color: high ? const Color(0xFFB45309) : kMuted))),
      ]),
    );
  }
}

/// Shows what a publish (or roll back) did: live now, being checked, or sent to OneLocal with the reasons and each change.
/// [builder] is the builder answer that came with it: an AI-flagged version keeps its changes on `pending`.
Future<void> showPublishOutcome(BuildContext context, Facts result, {required String? link, Future<void> Function(Uri uri)? onOpen}) {
  final status = result.s('result');
  final v = result.m('version');
  final pending = result.m('builder').mo('pending');
  var changes = v.l('changes');
  if (changes.isEmpty && pending != null && pending.s('id') == v.s('id')) changes = pending.l('changes');
  final summary = v.so('summary') ?? pending?.so('summary');
  final categories = v.ls('categories').isNotEmpty ? v.ls('categories') : (pending?.ls('categories') ?? const <String>[]);
  final aiNote = v.so('ai_note') ?? pending?.so('ai_note');
  final (key, icon, colour, title, body) = switch (status) {
    'auto_approved' || 'ai_approved' || 'human_approved' => (
        'gx-outcome-live',
        LucideIcons.circleCheck,
        const Color(0xFF15803D),
        'Live now',
        status == 'ai_approved' ? 'Your new wording was checked and guests see the new page now.' : 'Guests see the new page now.',
      ),
    'pending_ai' => (
        'gx-outcome-checking',
        LucideIcons.loader,
        const Color(0xFF2563EB),
        'Checking wording…',
        'OneLocal\'s AI is reading your new wording. It usually takes a few seconds. Guests keep seeing the last approved page until then.',
      ),
    _ => (
        'gx-outcome-review',
        LucideIcons.shieldCheck,
        const Color(0xFFB45309),
        'Sent to OneLocal for review',
        'A OneLocal person checks these changes before guests see them. Guests keep seeing the last approved page until then; the answer shows on this screen.',
      ),
  };
  final live = key == 'gx-outcome-live';
  return showOlDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: ValueKey(key),
      title: Row(children: [
        Icon(icon, color: colour, size: 24),
        const SizedBox(width: 10),
        Expanded(child: Text(title, style: inter(19, 800))),
      ]),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(body, style: inter(14, 400, color: kMuted, height: 1.4)),
            if (live && link != null) ...[
              const SizedBox(height: 12),
              SelectableText(link, key: const ValueKey('gx-outcome-link'), style: inter(14, 700, color: kInk)),
            ],
            if (!live && summary != null && summary.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(summary, key: const ValueKey('gx-outcome-summary'), style: inter(14, 600)),
            ],
            if (key == 'gx-outcome-review' && categories.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final c in categories) TagChip(gxCategoryLabel(c), key: ValueKey('gx-category-$c'), bg: const Color(0xFFFFEDD5), fg: const Color(0xFF9A3412)),
              ]),
            ],
            if (key == 'gx-outcome-review' && aiNote != null && aiNote.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('AI note: $aiNote', style: inter(13, 500, color: kMuted)),
            ],
            if (key == 'gx-outcome-review') for (final c in changes) GxChangeRow(c),
          ]),
        ),
      ),
      actions: [
        if (live && link != null) ...[
          TextButton(
            key: const ValueKey('gx-outcome-copy'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: link));
              if (ctx.mounted) showToast(ctx, 'Link copied.');
            },
            child: const Text('Copy link'),
          ),
          if (onOpen != null) TextButton(key: const ValueKey('gx-outcome-open'), onPressed: () => onOpen(Uri.parse(link)), child: const Text('Open')),
        ],
        TextButton(key: const ValueKey('gx-outcome-ok'), onPressed: () => Navigator.of(ctx).pop(), child: const Text('OK')),
      ],
    ),
  );
}

/// "4 Nov 2026 · 10:30" in the phone's time.
String gxWhen(DateTime? t) => t == null ? '' : '${dayText(t.toIso8601String())} · ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// One row of the history: version, status, summary, date; Live tag on the live one; Roll back on an approved one that is not live.
class GxHistoryRow extends StatelessWidget {
  const GxHistoryRow({super.key, required this.v, required this.liveVersion, required this.canRollBack, required this.onRollBack});
  final Facts v;
  final int? liveVersion;
  final bool canRollBack;
  final VoidCallback onRollBack;
  @override
  Widget build(BuildContext context) {
    final n = v.n('version').toInt();
    final status = v.s('status');
    final live = n == liveVersion;
    final (bg, fg) = switch (status) {
      'rejected' => (const Color(0xFFFEE2E2), const Color(0xFFB91C1C)),
      'pending_ai' || 'pending_human' => (const Color(0xFFFFEDD5), const Color(0xFF9A3412)),
      'superseded' => (const Color(0xFFF1F2F4), kMuted),
      _ => (const Color(0xFFDCFCE7), const Color(0xFF15803D)),
    };
    return SfCard(
      key: ValueKey('gx-history-$n'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('Version $n', style: inter(15, 800)),
          const SizedBox(width: 8),
          TagChip(gxStatusLabel(status), bg: bg, fg: fg),
          if (live) ...[const SizedBox(width: 6), const TagChip('Live', key: ValueKey('gx-history-live'))],
          if (v.s('source') == 'rollback' && v.no('rollback_of') != null) ...[const SizedBox(width: 6), Flexible(child: Text('from v${v.n('rollback_of').toInt()}', style: inter(12, 500, color: kMuted)))],
        ]),
        if (v.s('summary').isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(v.s('summary'), style: inter(13, 500))),
        if (status == 'rejected' && v.s('review_note').isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text('OneLocal: ${v.s('review_note')}', style: inter(12.5, 600, color: kError))),
        const SizedBox(height: 4),
        Row(children: [
          Expanded(child: Text([gxWhen(v.t('submitted_at')), if (v.s('decided_by_name').isNotEmpty && v.s('decided_kind') == 'human') 'by ${v.s('decided_by_name')}'].where((s) => s.isNotEmpty).join(' · '), style: inter(12, 400, color: kMuted))),
          if (gxApproved(status) && !live && canRollBack)
            TextButton.icon(key: ValueKey('gx-rollback-$n'), onPressed: onRollBack, icon: const Icon(LucideIcons.undo2, size: 16), label: Text('Roll back', style: inter(13, 700))),
        ]),
      ]),
    );
  }
}
