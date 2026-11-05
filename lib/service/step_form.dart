import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart' show DarkCta, kGreenText, kLime;
import '../ui/theme.dart';

// Every Service POS form in steps (founder, 4 Nov 2026: "on all forms"): a small Back at the top (Close on the first step), the step's
// name with a step bar under it (one segment per step, green up to this one; a segment jumps to its step), "Step 2 of 4" and the next
// one, the step's fields sliding in from the side they were reached from, Next at the bottom, and the form's own buttons on the last step.
// The screen keeps which step is shown ([step], [onStep]), so it can send the person back to a step with something missing.

class StepFormPage extends StatefulWidget {
  const StepFormPage({
    super.key,
    required this.title,
    required this.steps,
    required this.step,
    required this.onStep,
    required this.body,
    required this.finish,
    this.keyPrefix = 'sf',
    this.above,
    this.canAdvance,
    this.lastLine = 'Last step: save',
  });

  /// Under the bar on the last step, in place of "Next: ...".
  final String lastLine;

  /// Shown small on the right of the top row ("New service", "Edit job").
  final String title;
  final List<String> steps;
  final int step;
  final ValueChanged<int> onStep;

  /// The fields of the step shown.
  final List<Widget> body;

  /// The buttons on the last step (Save, Publish ...).
  final Widget finish;

  /// Keys: 'PREFIX-back', '-close', '-seg-N', '-next', '-step-count', '-step-next', '-step-body-N'.
  final String keyPrefix;

  /// Above the Next / last buttons on every step (a running total).
  final Widget? above;

  /// Checked before Next: return false (after saying why) to stay on the step.
  final bool Function(int step)? canAdvance;

  @override
  State<StepFormPage> createState() => _StepFormPageState();
}

class _StepFormPageState extends State<StepFormPage> {
  int _dir = 1;

  @override
  void didUpdateWidget(StepFormPage old) {
    super.didUpdateWidget(old);
    if (old.step != widget.step) _dir = widget.step > old.step ? 1 : -1;
  }

  void _go(int i) {
    if (i < 0 || i >= widget.steps.length || i == widget.step) return;
    if (i > widget.step && widget.canAdvance != null && !widget.canAdvance!(widget.step)) return;
    FocusScope.of(context).unfocus();
    widget.onStep(i);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.keyPrefix;
    final step = widget.step;
    final last = step == widget.steps.length - 1;
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: Column(children: [
              _header(p, step, last),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 340),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
                  transitionBuilder: (child, a) {
                    final incoming = child.key == ValueKey('$p-step-body-$step');
                    final from = Offset((incoming ? 0.3 : -0.3) * _dir, 0);
                    return FadeTransition(opacity: a, child: SlideTransition(position: Tween(begin: from, end: Offset.zero).animate(a), child: child));
                  },
                  child: SingleChildScrollView(
                    key: ValueKey('$p-step-body-$step'),
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: widget.body),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
      // the buttons sit in the page's bottom bar, so a message (a toast) floats above them instead of covering Next or Save
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(color: kBg, border: Border(top: BorderSide(color: kLine))),
        child: SafeArea(
          top: false,
          child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 860),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (widget.above != null) ...[widget.above!, const SizedBox(height: 10)],
                  if (last)
                    widget.finish
                  else
                    DarkCta(key: ValueKey('$p-next'), label: 'Next: ${widget.steps[step + 1]}', onPressed: () => _go(step + 1)),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(String p, int step, bool last) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            height: 40,
            child: Row(children: [
              if (step > 0)
                TextButton.icon(
                  key: ValueKey('$p-back'),
                  style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8), visualDensity: VisualDensity.compact),
                  onPressed: () => _go(step - 1),
                  icon: const Icon(LucideIcons.chevronLeft, size: 18, color: kLink),
                  label: Text('Back', style: inter(14, 600, color: kLink)),
                )
              else
                IconButton(key: ValueKey('$p-close'), tooltip: 'Close', onPressed: () => Navigator.of(context).maybePop(), icon: const Icon(LucideIcons.x, color: kInk)),
              const SizedBox(width: 8),
              Expanded(child: Text(widget.title, textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(13, 600, color: kMuted))),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                transitionBuilder: (child, a) => FadeTransition(
                  opacity: a,
                  child: SlideTransition(position: Tween(begin: const Offset(0, 0.25), end: Offset.zero).animate(a), child: child),
                ),
                layoutBuilder: (current, previous) => Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
                child: Text(widget.steps[step], key: ValueKey('$p-title-$step'), style: inter(22, 800)),
              ),
              const SizedBox(height: 8),
              Row(children: [
                for (var i = 0; i < widget.steps.length; i++)
                  Expanded(
                    child: Tooltip(
                      message: widget.steps[i],
                      child: GestureDetector(
                        key: ValueKey('$p-seg-$i'),
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _go(i),
                        // a taller touch area than the thin segment
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(i == 0 ? 0 : 3, 6, i == widget.steps.length - 1 ? 0 : 3, 6),
                          // done steps green into neon lime; the current one glows (founder, 4 Nov 2026)
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 320),
                            curve: Curves.easeOutCubic,
                            height: i == step ? 6 : 5,
                            decoration: BoxDecoration(
                              color: i <= step ? null : const Color(0xFFDCE3DF),
                              gradient: i <= step ? const LinearGradient(colors: [kGreenText, kLime]) : null,
                              borderRadius: BorderRadius.circular(3),
                              boxShadow: i == step ? const [BoxShadow(color: Color(0x80A1FE2F), blurRadius: 8, offset: Offset(0, 1))] : null,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ]),
              Row(children: [
                Text('Step ${step + 1} of ${widget.steps.length}', key: ValueKey('$p-step-count'), style: inter(12.5, 600, color: kMuted)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(last ? widget.lastLine : 'Next: ${widget.steps[step + 1]}',
                      key: ValueKey('$p-step-next'), textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(12.5, 500, color: kMuted)),
                ),
              ]),
            ]),
          ),
        ]),
      );
}
