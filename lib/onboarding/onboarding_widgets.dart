import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth/auth_repository.dart';
import '../auth/partner_api.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// Common frame of every onboarding screen: brand bar, back + step caption, kicker, title, body, pinned actions.
class OnbPage extends StatelessWidget {
  const OnbPage({
    super.key,
    required this.kicker,
    required this.title,
    this.subtitle,
    required this.children,
    required this.actions,
    this.caption,
    this.onBack,
    this.titleSize = 32,
  });
  final String kicker, title;
  final String? subtitle, caption;
  final List<Widget> children;
  final List<Widget> actions;
  final VoidCallback? onBack;
  final double titleSize;

  @override
  Widget build(BuildContext context) {
    return ScreenShell(
      gradient: kRegistrationGradient,
      children: [
        const BrandNav(),
        if (caption != null) StepNav(caption: caption!, onBack: onBack ?? () => Navigator.maybePop(context)),
        FormContent(gap: 24, children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Kicker(kicker),
            const SizedBox(height: 12),
            subtitle == null
                ? Text(title, style: inter(titleSize, 600, height: 1.12))
                : PageIntro(title: title, subtitle: subtitle!, titleSize: titleSize),
          ]),
          ...children,
        ]),
      ],
      actions: actions,
    );
  }
}

/// Runs a server call, shows the server's own message on failure, and reports whether it worked.
Future<T?> guarded<T>(BuildContext context, Future<T> Function() call) async {
  try {
    return await call();
  } catch (e) {
    if (context.mounted) showToast(context, e is PartnerApiException ? e.message : friendlyAuthError(e));
    return null;
  }
}

class WhiteCard extends StatelessWidget {
  const WhiteCard({super.key, required this.child, this.padding = 20, this.radius = 16});
  final Widget child;
  final double padding, radius;
  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.all(padding),
        decoration: BoxDecoration(color: Colors.white, border: Border.all(color: kLine), borderRadius: BorderRadius.circular(radius)),
        child: child,
      );
}

/// Title and body inside a soft box. [green] uses the light-green helper colour, otherwise white.
class NoteCard extends StatelessWidget {
  const NoteCard({super.key, required this.title, required this.body, this.green = false});
  final String title, body;
  final bool green;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: green ? kNote : Colors.white, borderRadius: BorderRadius.circular(16)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: inter(16, 600)),
          const SizedBox(height: 8),
          Text(body, style: inter(14, 400, color: kMuted, height: 1.5)),
        ]),
      );
}

enum Tone { done, warn, neutral, bad }

class StatusChip extends StatelessWidget {
  const StatusChip(this.label, this.tone, {super.key});
  final String label;
  final Tone tone;
  @override
  Widget build(BuildContext context) {
    final (bg, dot, fg) = switch (tone) {
      Tone.done => (const Color(0xFFEBFAE0), const Color(0xFF3DB800), const Color(0xFF1E6B00)),
      Tone.warn => (const Color(0xFFFFF7E0), const Color(0xFFF59E0B), const Color(0xFF92400E)),
      Tone.bad => (const Color(0xFFFEE9E7), kError, const Color(0xFF912018)),
      Tone.neutral => (const Color(0xFFF1F2F4), const Color(0xFF6B7280), const Color(0xFF374151)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Text(label, style: inter(13, 600, color: fg)),
      ]),
    );
  }
}

/// White card: bold title with a green action on the right, muted lines, optional chip.
class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.title, this.action, this.onAction, required this.lines, this.chip});
  final String title;
  final String? action;
  final VoidCallback? onAction;
  final List<String> lines;
  final StatusChip? chip;
  @override
  Widget build(BuildContext context) => WhiteCard(
        radius: 16,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Text(title, style: inter(16, 600))),
            if (action != null) InkWell(onTap: onAction, child: Text(action!, style: inter(15, 600, color: kLink))),
          ]),
          for (final l in lines) ...[const SizedBox(height: 12), Text(l, style: inter(14, 400, color: kMuted, height: 1.4))],
          if (chip != null) ...[const SizedBox(height: 14), chip!],
        ]),
      );
}

class CheckRow extends StatelessWidget {
  const CheckRow({super.key, required this.value, required this.onChanged, required this.text, this.sub});
  final bool value;
  final ValueChanged<bool> onChanged;
  final String text;
  final String? sub;
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onChanged(!value);
        },
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 24,
            height: 24,
            margin: const EdgeInsets.only(top: 2),
            decoration: BoxDecoration(
              color: value ? kCheck : Colors.white,
              border: Border.all(color: value ? kCheck : kLine),
              borderRadius: BorderRadius.circular(6),
            ),
            child: value ? const Icon(Icons.check, size: 16, color: kPrimary) : null,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(text, style: inter(15, 400, height: 1.4)),
              if (sub != null) ...[const SizedBox(height: 4), Text(sub!, style: inter(13, 400, color: kMuted, height: 1.4))],
            ]),
          ),
        ]),
      );
}

/// A field that opens a list to choose from. [error] is not shown inline; screens validate and toast, like phase A.
class SelectField extends StatelessWidget {
  const SelectField({super.key, required this.label, required this.value, required this.options, required this.onChanged, this.hint = 'Choose', this.labelWeight = 600});
  final String label;
  final String? value;
  final List<String> options;
  final ValueChanged<String> onChanged;
  final String hint;
  final int labelWeight;

  Future<void> _open(BuildContext context) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (_, scroll) => Column(children: [
          Padding(padding: const EdgeInsets.all(20), child: Text(label, style: inter(18, 600))),
          Expanded(
            child: ListView(controller: scroll, children: [
              for (final o in options)
                ListTile(
                  title: Text(o, style: inter(15, o == value ? 600 : 400)),
                  trailing: o == value ? const Ico(lucideCircleCheck, size: 20) : null,
                  onTap: () => Navigator.pop(context, o),
                ),
            ]),
          ),
        ]),
      ),
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: inter(14, labelWeight)),
        const SizedBox(height: 8),
        InkWell(
          borderRadius: BorderRadius.circular(kRadius),
          onTap: options.isEmpty ? null : () => _open(context),
          child: Container(
            height: kFieldH,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(color: kField, border: Border.all(color: kFieldBorder), borderRadius: BorderRadius.circular(kRadius)),
            child: Row(children: [
              Expanded(child: Text(value ?? hint, style: inter(15, 400, color: value == null ? kMuted : kInk), overflow: TextOverflow.ellipsis)),
              const Icon(Icons.keyboard_arrow_down, size: 20, color: kMuted),
            ]),
          ),
        ),
      ]);
}

/// Pick any number of [options], all shown at once as wrapping chips (no sheet, no sideways scroll). Order of tapping is kept.
class MultiChipField extends StatelessWidget {
  const MultiChipField({super.key, required this.label, required this.options, required this.selected, required this.onChanged, this.hint});
  final String label;
  final String? hint;
  final List<String> options;
  final List<String> selected;
  final ValueChanged<List<String>> onChanged;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: inter(14, 500)),
        if (hint != null) ...[const SizedBox(height: 4), Text(hint!, style: inter(12.5, 400, color: kMuted))],
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final o in options)
            Builder(builder: (_) {
              final on = selected.contains(o);
              return InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => onChanged(on ? (List.of(selected)..remove(o)) : [...selected, o]),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: on ? kNote : kField,
                    border: Border.all(color: on ? kLink : kFieldBorder),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (on) ...[const Icon(Icons.check, size: 15, color: kLink), const SizedBox(width: 4)],
                    Text(o, style: inter(13.5, on ? 600 : 400, color: on ? kLink : kInk)),
                  ]),
                ),
              );
            }),
        ]),
      ]);
}

/// Radio-style choice card for onboarding (selected = light green).
class ChoiceCard extends StatelessWidget {
  const ChoiceCard({super.key, required this.icon, required this.title, required this.body, required this.selected, required this.onTap});
  final IconData icon;
  final String title, body;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(kRadius),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: selected ? kNote : Colors.white,
            border: Border.all(color: selected ? kLink : kLine, width: selected ? 1.5 : 1),
            borderRadius: BorderRadius.circular(kRadius),
          ),
          child: Row(children: [
            Ico(icon, size: 22, color: selected ? kLink : const Color(0xFF4B5563)),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: inter(15, 600)),
                const SizedBox(height: 4),
                Text(body, style: inter(14, 400, color: kMuted, height: 1.4)),
              ]),
            ),
            selected
                ? const Ico(lucideCircleCheck, size: 22)
                : Container(width: 20, height: 20, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: kLine, width: 2))),
          ]),
        ),
      );
}

class ProgressLine extends StatelessWidget {
  const ProgressLine({super.key, required this.done, required this.total, required this.percent});
  final int done, total, percent;
  @override
  Widget build(BuildContext context) => Column(children: [
        Row(children: [
          Expanded(child: Text('$done of $total sections complete', style: inter(15, 600))),
          Text('$percent%', style: inter(14, 400, color: kMuted)),
        ]),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(value: total == 0 ? 0 : done / total, minHeight: 8, color: kCheck, backgroundColor: kLine),
        ),
      ]);
}

/// Big round check inside a white card with title and body, used by the outcome screens.
class OutcomeCard extends StatelessWidget {
  const OutcomeCard({super.key, required this.title, required this.lines, required this.noteTitle, required this.noteBody, this.icon = lucideCircleCheck});
  final String title, noteTitle, noteBody;
  final List<String> lines;
  final IconData icon;
  @override
  Widget build(BuildContext context) => WhiteCard(
        padding: 24,
        radius: 24,
        child: Column(children: [
          Container(width: 64, height: 64, decoration: const BoxDecoration(color: kNote, shape: BoxShape.circle), alignment: Alignment.center, child: Ico(icon, size: 32, color: const Color(0xFF15803D))),
          const SizedBox(height: 20),
          Text(title, textAlign: TextAlign.center, style: inter(24, 700, height: 1.2)),
          const SizedBox(height: 12),
          for (final l in lines) Text(l, textAlign: TextAlign.center, style: inter(15, 400, color: kMuted, height: 1.5)),
          const SizedBox(height: 20),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: kBg, borderRadius: BorderRadius.circular(16)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(noteTitle, style: inter(14, 600)),
              const SizedBox(height: 8),
              Text(noteBody, style: inter(14, 400, color: kMuted, height: 1.5)),
            ]),
          ),
        ]),
      );
}

String niceDate(String? iso) {
  final d = DateTime.tryParse(iso ?? '')?.toLocal();
  if (d == null) return '';
  const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${d.day.toString().padLeft(2, '0')} ${m[d.month - 1]} ${d.year}';
}

/// Signs out and drops every onboarding screen, so the sign-in screen the gate shows is what the person sees.
Future<void> leaveOnboarding(BuildContext context, AuthRepository? auth) async {
  final nav = Navigator.of(context);
  await (auth ?? AuthRepository()).signOut();
  nav.popUntil((r) => r.isFirst);
}
