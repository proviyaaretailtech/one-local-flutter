import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../auth/auth_repository.dart';
import '../auth/partner_api.dart';
import '../orders/order_widgets.dart' show kBadText, kBadBg, kChipGreen, kGreenText, kSoftField, kWarnBg, kWarnText, kLimeSoft;
import '../ui/theme.dart';

// Section P colours, read from the exported frames (assets/figma_ref_p): the lime Save button is #76EC00 (kCheck) with dark text,
// the page is the shared cream (kBg), rows sit on white 16-radius cards.
const double kSheetRadius = 28;

/// Runs a server call, shows the server's own sentence on failure, and answers null when it failed.
Future<T?> guarded<T>(BuildContext context, Future<T> Function() call) async {
  try {
    return await call();
  } catch (e) {
    if (context.mounted) showToast(context, e is PartnerApiException ? e.message : friendlyAuthError(e));
    return null;
  }
}

/// A small caption above a group of rows ("TIMINGS & READINESS").
class GroupTitle extends StatelessWidget {
  const GroupTitle(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.fromLTRB(4, 18, 4, 8), child: Text(text.toUpperCase(), style: inter(11.5, 700, color: kMuted).copyWith(letterSpacing: 0.4)));
}

/// A white rounded card holding rows separated by hairlines.
class GroupCard extends StatelessWidget {
  const GroupCard({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFECEDE8))),
        clipBehavior: Clip.antiAlias,
        child: Column(children: [
          for (var i = 0; i < children.length; i++) ...[if (i > 0) const Divider(height: 1, thickness: 1, color: Color(0xFFF1F2EE)), children[i]],
        ]),
      );
}

/// One settings row: round icon, title, status line, then the actions on the right (Edit, Verify, a switch, a chevron).
class SettingRow extends StatelessWidget {
  const SettingRow({super.key, required this.icon, required this.title, required this.subtitle, this.actions = const [], this.onTap});
  final IconData icon;
  final String title, subtitle;
  final List<Widget> actions;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(children: [
            Container(width: 36, height: 36, decoration: BoxDecoration(color: kChipGreen, borderRadius: BorderRadius.circular(12)), child: Icon(icon, size: 18, color: kGreenText)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: inter(14.5, 600)),
                const SizedBox(height: 2),
                Text(subtitle, style: inter(12, 400, color: kMuted, height: 1.3)),
              ]),
            ),
            ...actions,
          ]),
        ),
      );
}

/// The green "Edit" / "Verify" text button of a row.
class RowAction extends StatelessWidget {
  const RowAction(this.label, {super.key, this.onTap});
  final String label;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: label,
        child: InkWell(onTap: onTap, borderRadius: BorderRadius.circular(8), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10), child: Text(label, style: inter(13.5, 600, color: kLink)))),
      );
}

/// The lime pill button of a row ("Add users").
class LimePill extends StatelessWidget {
  const LimePill(this.label, {super.key, this.onTap});
  final String label;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Material(
        color: kCheck,
        shape: const StadiumBorder(),
        child: InkWell(customBorder: const StadiumBorder(), onTap: onTap, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11), child: Text(label, style: inter(13.5, 700)))),
      );
}

/// The big lime Save button at the foot of a sheet.
class SaveButton extends StatelessWidget {
  const SaveButton({super.key, required this.label, required this.onPressed, this.busy = false});
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  @override
  Widget build(BuildContext context) => Opacity(
        opacity: onPressed == null ? 0.5 : 1,
        child: Material(
          color: kCheck,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: busy ? null : onPressed,
            child: SizedBox(height: 46, child: Center(child: busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: kInk)) : Text(label, style: inter(14.5, 700)))),
          ),
        ),
      );
}

/// A switch the way the frames draw it: grey off, lime on.
class LimeSwitch extends StatelessWidget {
  const LimeSwitch({super.key, required this.value, required this.onChanged, this.label});
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? label;
  @override
  Widget build(BuildContext context) => Semantics(
        toggled: value,
        label: label,
        child: Switch(
          value: value,
          onChanged: onChanged,
          activeThumbColor: Colors.white,
          activeTrackColor: const Color(0xFF3DB800),
          inactiveThumbColor: Colors.white,
          inactiveTrackColor: const Color(0xFFCBD0D6),
          trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
        ),
      );
}

/// Cream strip with a warning line ("Bank details must match the Shop Act.").
class WarnStrip extends StatelessWidget {
  const WarnStrip(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        color: kWarnBg,
        child: Row(children: [const Icon(LucideIcons.info, size: 16, color: kWarnText), const SizedBox(width: 8), Expanded(child: Text(text, style: inter(12, 500, color: kWarnText)))]),
      );
}

/// Round status pill ("• Unverified").
class StatusPill extends StatelessWidget {
  const StatusPill(this.label, {super.key, this.good = false});
  final String label;
  final bool good;
  @override
  Widget build(BuildContext context) {
    final fg = good ? kGreenText : kWarnText;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: good ? kLimeSoft : kWarnBg, borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [Container(width: 6, height: 6, decoration: BoxDecoration(color: fg, shape: BoxShape.circle)), const SizedBox(width: 6), Text(label, style: inter(12, 600, color: fg))]),
    );
  }
}

/// A labelled soft-grey field (Figma: #F7F8F6, 12 radius, 44 tall).
class SheetField extends StatelessWidget {
  const SheetField({super.key, required this.label, required this.controller, this.hint, this.keyboardType, this.maxLines = 1, this.maxLength, this.prefix, this.inputFormatters, this.fieldKey, this.helper, this.obscure = false});
  final String label;
  final String? hint, helper, prefix;
  final TextEditingController controller;
  final TextInputType? keyboardType;
  final int maxLines;
  final int? maxLength;
  final List<TextInputFormatter>? inputFormatters;
  final Key? fieldKey;
  /// Dots instead of the text (keys and secrets). Single line only.
  final bool obscure;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (label.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(label, style: inter(13, 700))),
          Container(
            constraints: BoxConstraints(minHeight: maxLines > 1 ? 84 : 44),
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: maxLines > 1 ? 8 : 0),
            decoration: BoxDecoration(color: kField, border: Border.all(color: kFieldBorder), borderRadius: BorderRadius.circular(12)),
            child: Row(crossAxisAlignment: maxLines > 1 ? CrossAxisAlignment.start : CrossAxisAlignment.center, children: [
              if (prefix != null) ...[
                Padding(padding: EdgeInsets.only(top: maxLines > 1 ? 12 : 0), child: Text(prefix!, style: inter(13.5, 600))),
                Container(width: 1, height: 22, margin: const EdgeInsets.symmetric(horizontal: 10), color: kLine),
              ],
              Expanded(
                child: TextField(
                  key: fieldKey,
                  controller: controller,
                  keyboardType: keyboardType,
                  maxLines: obscure ? 1 : maxLines,
                  minLines: 1,
                  maxLength: maxLength,
                  inputFormatters: inputFormatters,
                  autocorrect: false,
                  obscureText: obscure,
                  enableSuggestions: !obscure,
                  style: inter(13.5, 400),
                  decoration: InputDecoration(border: InputBorder.none, isCollapsed: false, contentPadding: const EdgeInsets.symmetric(vertical: 12), hintText: hint, counterText: '', hintStyle: inter(13.5, 400, color: kMuted)),
                ),
              ),
            ]),
          ),
          if (helper != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(helper!, style: inter(12, 400, color: kMuted))),
        ]),
      );
}

/// A field that opens a picker (time, list): shows the value or the hint, a chevron on the right, and a muted "Not set" line under it.
class PickField extends StatelessWidget {
  const PickField({super.key, required this.label, required this.value, required this.hint, required this.onTap, this.showNotSet = false});
  final String label, hint;
  final String? value;
  final VoidCallback onTap;
  final bool showNotSet;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(label, style: inter(13, 700))),
          Semantics(
            button: true,
            label: label,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onTap,
              child: Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(color: kField, border: Border.all(color: kFieldBorder), borderRadius: BorderRadius.circular(12)),
                child: Row(children: [Expanded(child: Text(value ?? hint, style: inter(13.5, 400, color: value == null ? kMuted : kInk))), const Icon(LucideIcons.chevronDown, size: 18, color: kMuted)]),
              ),
            ),
          ),
          if (showNotSet && value == null) Padding(padding: const EdgeInsets.only(top: 6), child: Text('Not set', style: inter(12, 400, color: kMuted))),
        ]),
      );
}

/// A grey inset panel with a bold line and a muted line (empty states of Documents, QR, Manage store access).
class EmptyPanel extends StatelessWidget {
  const EmptyPanel({super.key, required this.title, required this.body, this.child});
  final String title, body;
  final Widget? child;
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: kSoftField, borderRadius: BorderRadius.circular(16), border: Border.all(color: kLine)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: inter(14, 700)),
          const SizedBox(height: 4),
          Text(body, style: inter(12.5, 400, color: kMuted, height: 1.4)),
          if (child != null) ...[const SizedBox(height: 12), child!],
        ]),
      );
}

/// Dark green wide button inside a panel ("Upload document", "Upload").
class PanelButton extends StatelessWidget {
  const PanelButton(this.label, {super.key, required this.onPressed, this.busy = false});
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  @override
  Widget build(BuildContext context) => Opacity(
        opacity: onPressed == null ? 0.5 : 1,
        child: Material(
          color: kCheck,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: busy ? null : onPressed,
            child: SizedBox(height: 42, width: double.infinity, child: Center(child: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: kInk)) : Text(label, style: inter(14, 700)))),
          ),
        ),
      );
}

/// The sheet every settings dialogue uses: grab handle, title, subtitle, close, then the body. Rounded top, white.
Future<T?> showSettingsSheet<T>(BuildContext context, {required String title, String? subtitle, required Widget Function(BuildContext) body}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(kSheetRadius))),
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Center(child: Container(width: 36, height: 4, decoration: BoxDecoration(color: const Color(0xFFD1D5DB), borderRadius: BorderRadius.circular(4)))),
            const SizedBox(height: 14),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Text(title, style: inter(21, 700, height: 1.2))),
              Semantics(button: true, label: 'Close', child: InkWell(customBorder: const CircleBorder(), onTap: () => Navigator.of(ctx).maybePop(), child: const Padding(padding: EdgeInsets.all(8), child: Icon(LucideIcons.x, size: 20, color: kMuted)))),
            ]),
            if (subtitle != null) Padding(padding: const EdgeInsets.only(top: 2, bottom: 12), child: Text(subtitle, style: inter(13, 400, color: kMuted))),
            if (subtitle == null) const SizedBox(height: 10),
            body(ctx),
          ]),
        ),
      ),
    ),
  );
}

/// Red text under a field when the database refused the value.
class FormError extends StatelessWidget {
  const FormError(this.text, {super.key});
  final String? text;
  @override
  Widget build(BuildContext context) => text == null
      ? const SizedBox.shrink()
      : Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: kBadBg, borderRadius: BorderRadius.circular(10)),
          child: Text(text!, style: inter(12.5, 500, color: kBadText)),
        );
}
