import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/auth_repository.dart';
import '../auth/partner_api.dart';
import '../ui/theme.dart';
import 'setup_api.dart';

// Section C ("Setup dialogues") tokens, read from the 2x Figma exports in assets/figma_ref_c (16 Oct 2026). The dialogues are a
// 351-wide white card with a 28 radius over a dimmed screen; the coach-mark scrim is #111827 at 13%.
const kLime = Color(0xFFA1FE2F);
const kDone = Color(0xFF287000);
const kPending = Color(0xFFD97706);
const kBoxBorder = Color(0xFFD1D5DB);
const kScrim = Color(0x21111827);
const double kDialogRadius = 28;
const double kDialogPad = 16;

/// Runs a server call, shows the server's own message on failure, and returns null when it failed.
Future<T?> setupGuarded<T>(BuildContext context, Future<T> Function() call) async {
  try {
    return await call();
  } catch (e) {
    if (context.mounted) showToast(context, e is PartnerApiException ? e.message : friendlyAuthError(e));
    return null;
  }
}

/// A setup step's place in the "Save & Continue" walk; [SetupDialog] shows it as "Step n of N" and a progress bar under
/// the kicker, a Back button beside the main action, and "Skip for now" on optional steps.
class SetupStepScope extends InheritedWidget {
  const SetupStepScope({super.key, required this.number, required this.total, this.onBack, this.onSkip, required super.child});
  final int number, total;

  /// Opens the previous step of the walk; null on the first step.
  final void Function(BuildContext context)? onBack;

  /// Moves on without saving; only optional steps have it.
  final void Function(BuildContext context)? onSkip;
  static SetupStepScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<SetupStepScope>();
  @override
  bool updateShouldNotify(SetupStepScope old) => number != old.number || total != old.total;
}

/// The frame every setup screen shares: kicker, close button, title, subtitle, scrolling body, a rule, pinned actions.
/// [tour] shows the screen's tip the first time it is seen, as a hint under the title (it no longer covers the form).
class SetupDialog extends StatefulWidget {
  const SetupDialog({
    super.key,
    this.kicker = 'Business setup',
    required this.title,
    this.subtitle,
    required this.children,
    required this.actions,
    this.onClose,
    this.tour,
  });
  final String kicker, title;
  final String? subtitle;
  final List<Widget> children;
  final List<Widget> actions;
  final VoidCallback? onClose;
  final TourStep? tour;

  @override
  State<SetupDialog> createState() => _SetupDialogState();
}

class _SetupDialogState extends State<SetupDialog> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final step = SetupStepScope.maybeOf(context);
    final close = widget.onClose ?? () => Navigator.of(context).maybePop();
    // Full screen (Pass 2): a fixed top bar (kicker, step and progress, a way out), the page scrolls, actions pinned below.
    final topBar = Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 8, 10),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.kicker.toUpperCase(), style: inter(11.5, 700, color: kMuted).copyWith(letterSpacing: 0.2)),
            if (step != null) ...[
              const SizedBox(height: 3),
              Text('Step ${step.number} of ${step.total}', style: inter(11.5, 600, color: kLink)),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(value: step.number / step.total, minHeight: 4, backgroundColor: kLine, color: kLime),
              ),
            ],
          ]),
        ),
        const SizedBox(width: 12),
        // In the walk the way out says what it does: finished steps are already saved, the rest waits on the checklist.
        if (step != null)
          Semantics(
            button: true,
            label: 'Finish later',
            excludeSemantics: true,
            child: TextButton(onPressed: close, child: Text('Finish later', style: inter(13, 600, color: kMuted))),
          )
        else
          Semantics(
            button: true,
            label: 'Close',
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: close,
              child: Container(
                width: 44,
                height: 44,
                decoration: const BoxDecoration(color: kBg, shape: BoxShape.circle),
                alignment: Alignment.center,
                child: const Icon(LucideIcons.x, size: 18, color: kMuted),
              ),
            ),
          ),
      ]),
    );
    final page = SingleChildScrollView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(widget.title, style: inter(22, 700, height: 1.2)),
        if (widget.subtitle != null) ...[
          const SizedBox(height: 8),
          Text(widget.subtitle!, style: inter(13, 400, color: kMuted, height: 1.42)),
        ],
        if (widget.tour != null) ...[const SizedBox(height: 12), _TipHint(tour: widget.tour!)],
        const SizedBox(height: 16),
        ...widget.children,
      ]),
    );
    final bottomBar = Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        const Divider(height: 1, thickness: 1, color: kLine),
        const SizedBox(height: 12),
        // In the walk, Back sits beside the main (last) action.
        if (step?.onBack != null && widget.actions.isNotEmpty) ...[
          ...widget.actions.take(widget.actions.length - 1),
          Row(children: [
            SizedBox(width: 104, child: PillSecondary(label: '← Back', onPressed: () => step!.onBack!(context))),
            const SizedBox(width: 10),
            Expanded(child: widget.actions.last),
          ]),
        ] else
          ...widget.actions,
        if (step?.onSkip != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: TextButton(
              onPressed: () => step!.onSkip!(context),
              child: Text('Skip for now', style: inter(13, 600, color: kMuted)),
            ),
          ),
      ]),
    );
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        bottom: false,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [topBar, Expanded(child: page)]),
      ),
      // As the Scaffold's bottom bar, so messages (toasts) appear above the buttons instead of covering them.
      bottomNavigationBar: SafeArea(top: false, child: bottomBar),
    );
  }
}

/// The screen's tip, shown once under the title: it explains without blocking the form; "Got it" records it as seen.
class _TipHint extends StatelessWidget {
  const _TipHint({required this.tour});
  final TourStep tour;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 4),
        decoration: BoxDecoration(color: kLime.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(12), border: Border.all(color: kLime.withValues(alpha: 0.6))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Padding(padding: EdgeInsets.only(top: 1), child: Icon(LucideIcons.lightbulb, size: 16, color: kDone)),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tour.title, style: inter(12.5, 700)),
                const SizedBox(height: 2),
                Text(tour.body, style: inter(12, 400, color: kMuted, height: 1.4)),
              ]),
            ),
          ]),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: tour.onNext, child: Text('Got it', style: inter(12.5, 700, color: kDone))),
          ),
        ]),
      );
}

/// Small label above a field (11.5 / 600).
class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(text, style: inter(11.5, 600)));
}

/// Section heading inside a dialogue (13 / 700).
class SetupHeading extends StatelessWidget {
  const SetupHeading(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Text(text, style: inter(13, 700));
}

/// Muted note under a block (12 / 400).
class SetupNote extends StatelessWidget {
  const SetupNote(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Text(text, style: inter(12, 400, color: kMuted, height: 1.42));
}

BoxDecoration get _boxDecoration => BoxDecoration(color: kBg, border: Border.all(color: kBoxBorder), borderRadius: BorderRadius.circular(12));

/// A 44-tall text field with its label above.
class SetupField extends StatelessWidget {
  const SetupField({super.key, required this.label, required this.controller, this.hint, this.keyboardType, this.maxLines = 1, this.inputFormatters, this.maxLength, this.obscure = false});
  final String label;
  final String? hint;
  final TextEditingController controller;
  final TextInputType? keyboardType;
  final int maxLines;
  final int? maxLength;
  final bool obscure;
  final List<TextInputFormatter>? inputFormatters;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (label.isNotEmpty) FieldLabel(label),
        Container(
          constraints: BoxConstraints(minHeight: maxLines > 1 ? 64 : 44),
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: maxLines > 1 ? 10 : 0),
          alignment: maxLines > 1 ? Alignment.topLeft : Alignment.centerLeft,
          decoration: _boxDecoration,
          child: TextField(
            controller: controller,
            keyboardType: keyboardType,
            maxLines: maxLines,
            minLines: 1,
            maxLength: maxLength,
            obscureText: obscure,
            inputFormatters: inputFormatters,
            autocorrect: false,
            style: inter(12.5, 400),
            decoration: plainInput.copyWith(hintText: hint, counterText: '', hintStyle: inter(12.5, 400, color: kMuted)),
          ),
        ),
      ]);
}

/// A 44-tall field that opens a list (chevron on the right). [display] maps a value to its words.
class SetupSelect<T> extends StatelessWidget {
  const SetupSelect({super.key, required this.label, required this.value, required this.options, required this.onChanged, required this.hint, required this.display, this.multiLineValue = false});
  final String label, hint;
  final T? value;
  final List<T> options;
  final ValueChanged<T> onChanged;
  final String Function(T) display;
  final bool multiLineValue;

  Future<void> _open(BuildContext context) async {
    final picked = await showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true, // a long list scrolls inside the sheet instead of running off the bottom
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(padding: const EdgeInsets.all(20), child: Text(label.isEmpty ? hint : label, style: inter(16, 700))),
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                for (final o in options)
                  ListTile(
                    title: Text(display(o), style: inter(14, o == value ? 700 : 400)),
                    trailing: o == value ? const Icon(LucideIcons.check, size: 18, color: kDone) : null,
                    onTap: () => Navigator.pop(context, o),
                  ),
              ]),
            ),
            const SizedBox(height: 8),
          ]),
        ),
      ),
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (label.isNotEmpty) FieldLabel(label),
        Semantics(
          button: true,
          label: label.isEmpty ? hint : label,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _open(context),
            child: Container(
              constraints: const BoxConstraints(minHeight: 44),
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
              decoration: _boxDecoration,
              child: Row(children: [
                Expanded(
                  child: Text(value == null ? hint : display(value as T),
                      maxLines: multiLineValue ? 2 : 1, overflow: TextOverflow.ellipsis, style: inter(12.5, 400, color: value == null ? kMuted : kInk, height: 1.3)),
                ),
                const Icon(Icons.keyboard_arrow_down, size: 20, color: kMuted),
              ]),
            ),
          ),
        ),
      ]);
}

/// A square checkbox (20, lime when on) with a title and optional muted line.
class SetupCheck extends StatelessWidget {
  const SetupCheck({super.key, required this.value, required this.title, this.sub, this.onChanged});
  final bool value;
  final String title;
  final String? sub;
  final ValueChanged<bool>? onChanged;
  @override
  Widget build(BuildContext context) => Semantics(
        checked: value,
        enabled: onChanged != null,
        label: title,
        child: InkWell(
          onTap: onChanged == null
              ? null
              : () {
                  HapticFeedback.selectionClick();
                  onChanged!(!value);
                },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(crossAxisAlignment: sub == null ? CrossAxisAlignment.center : CrossAxisAlignment.start, children: [
              Container(
                width: 20,
                height: 20,
                margin: EdgeInsets.only(top: sub == null ? 0 : 1),
                decoration: BoxDecoration(
                  color: value ? kLime : Colors.white,
                  border: value ? null : Border.all(color: kBoxBorder),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: value ? const Icon(LucideIcons.check, size: 14, color: kInk) : null,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: inter(12.5, 600, height: 1.3)),
                  if (sub != null) ...[const SizedBox(height: 3), Text(sub!, style: inter(11.5, 400, color: kMuted, height: 1.3))],
                ]),
              ),
            ]),
          ),
        ),
      );
}

/// The light box that holds a group of checkboxes or a summary (radius 16).
class SetupBox extends StatelessWidget {
  const SetupBox({super.key, required this.children, this.padding = const EdgeInsets.fromLTRB(12, 6, 12, 6)});
  final List<Widget> children;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(color: kBg, border: Border.all(color: kLine), borderRadius: BorderRadius.circular(16)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      );
}

/// A label on the left and a bold value on the right (plan card, usage limits).
class SetupKeyValue extends StatelessWidget {
  const SetupKeyValue(this.label, this.value, {super.key});
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(child: Text(label, style: inter(11.5, 400, color: kMuted))),
          Text(value, style: inter(12.5, 700)),
        ]),
      );
}

/// Grey pill with a dot ("Setup incomplete", "Device not registered"); green when [done].
class SetupStatusPill extends StatelessWidget {
  const SetupStatusPill(this.label, {super.key, this.done = false});
  final String label;
  final bool done;
  @override
  Widget build(BuildContext context) {
    final fg = done ? kDone : kMuted;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(color: done ? kNote : kBg, borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 6, height: 6, decoration: BoxDecoration(color: fg, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(label, style: inter(11.5, 600, color: fg)),
        ]),
      ),
    );
  }
}

/// Dark pill, lime text, 48 tall.
class PillPrimary extends StatelessWidget {
  const PillPrimary({super.key, required this.label, required this.onPressed});
  final String label;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => Opacity(
        opacity: onPressed == null ? 0.5 : 1,
        child: Material(
          color: kInk,
          shape: const StadiumBorder(),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onPressed,
            child: SizedBox(height: 48, child: Center(child: Text(label, style: inter(14, 700, color: kLime)))),
          ),
        ),
      );
}

/// Outlined pill, 44 tall.
class PillSecondary extends StatelessWidget {
  const PillSecondary({super.key, required this.label, required this.onPressed});
  final String label;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        shape: const StadiumBorder(side: BorderSide(color: kBoxBorder)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onPressed,
          child: SizedBox(height: 44, child: Center(child: Text(label, style: inter(13.5, 600)))),
        ),
      );
}

/// Marks the widget a coach mark points at.
class TourTarget extends StatelessWidget {
  const TourTarget({super.key, required this.tourKey, required this.child});
  final GlobalKey tourKey;
  final Widget child;
  @override
  Widget build(BuildContext context) => KeyedSubtree(key: tourKey, child: child);
}

/// One "n of 10" coach mark: what it says, what it points at, and what happens on Next.
class TourStep {
  const TourStep({required this.step, required this.title, required this.body, required this.target, required this.onNext});
  final int step;
  final String title, body;
  final GlobalKey target;
  final VoidCallback onNext;
}

/// The coach mark: a dim layer with a lime-ringed window over the target, and a white bubble with "n of 10" and Next.
class CoachMark extends StatefulWidget {
  const CoachMark({super.key, required this.step, required this.stackKey, required this.scroll});
  final TourStep step;
  final GlobalKey stackKey;
  final ScrollController scroll;
  @override
  State<CoachMark> createState() => _CoachMarkState();
}

class _CoachMarkState extends State<CoachMark> {
  Rect? _hole;

  @override
  void initState() {
    super.initState();
    widget.scroll.addListener(_measure);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final ctx = widget.step.target.currentContext;
      if (ctx != null && ctx.mounted) await Scrollable.ensureVisible(ctx, alignment: 0.5, duration: Duration.zero);
      _measure();
    });
  }

  @override
  void dispose() {
    widget.scroll.removeListener(_measure);
    super.dispose();
  }

  void _measure() {
    final box = widget.step.target.currentContext?.findRenderObject() as RenderBox?;
    final stack = widget.stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || stack == null || !box.attached || !mounted) return;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: stack);
    setState(() => _hole = (topLeft & box.size).inflate(6));
  }

  @override
  Widget build(BuildContext context) {
    final hole = _hole;
    return LayoutBuilder(builder: (context, c) {
      final below = hole == null || hole.center.dy < c.maxHeight / 2;
      final bubble = _Bubble(step: widget.step, arrowUp: below);
      return Stack(children: [
        Positioned.fill(child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () {}, child: CustomPaint(painter: _ScrimPainter(hole)))),
        if (hole != null)
          Positioned(
            left: 12,
            right: 12,
            top: below ? hole.bottom + 4 : null,
            bottom: below ? null : c.maxHeight - hole.top + 4,
            child: bubble,
          ),
      ]);
    });
  }
}

class _ScrimPainter extends CustomPainter {
  _ScrimPainter(this.hole);
  final Rect? hole;
  @override
  void paint(Canvas canvas, Size size) {
    final all = Path()..addRect(Offset.zero & size);
    if (hole == null) {
      canvas.drawPath(all, Paint()..color = kScrim);
      return;
    }
    final window = RRect.fromRectAndRadius(hole!, const Radius.circular(16));
    canvas.drawPath(Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(window), Paint()..color = kScrim);
    canvas.drawRRect(window, Paint()
      ..color = kLime
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_ScrimPainter old) => old.hole != hole;
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.step, required this.arrowUp});
  final TourStep step;
  final bool arrowUp;
  @override
  Widget build(BuildContext context) {
    final arrow = Center(child: CustomPaint(size: const Size(16, 8), painter: _ArrowPainter(up: arrowUp)));
    return Semantics(
      liveRegion: true,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (arrowUp) arrow,
        Container(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: kLine),
            boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 12, offset: Offset(0, 4))],
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(step.title, style: inter(20, 700, height: 1.2)),
            const SizedBox(height: 10),
            Text(step.body, style: inter(12, 400, height: 1.42)),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: Text('${step.step} of 10', style: inter(11.5, 400, color: kMuted))),
              Material(
                color: kLime,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: step.onNext,
                  child: SizedBox(width: 83, height: 37, child: Center(child: Text('Next', style: inter(13, 700)))),
                ),
              ),
            ]),
          ]),
        ),
        if (!arrowUp) arrow,
      ]),
    );
  }
}

class _ArrowPainter extends CustomPainter {
  _ArrowPainter({required this.up});
  final bool up;
  @override
  void paint(Canvas canvas, Size s) {
    final p = up
        ? (Path()..moveTo(0, s.height)..lineTo(s.width / 2, 0)..lineTo(s.width, s.height))
        : (Path()..moveTo(0, 0)..lineTo(s.width / 2, s.height)..lineTo(s.width, 0));
    canvas.drawPath(p..close(), Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_ArrowPainter old) => old.up != up;
}

/// Shows a screen's coach mark the first time; Next records it on the server and hides it.
mixin TourHost<T extends StatefulWidget> on State<T> {
  SetupApi get tourApi;
  SetupState get tourState;
  bool _tourHidden = false;

  TourStep? tourFor(int step, String title, String body, GlobalKey target) {
    if (_tourHidden || tourState.tourSeen.contains(step)) return null;
    return TourStep(step: step, title: title, body: body, target: target, onNext: () {
      setState(() => _tourHidden = true);
      tourApi.tourSeen(step).catchError((_) => tourState);   // a lost tour mark only means it shows again next time
    });
  }
}
