import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart';
import '../ui/theme.dart';
import 'team_api.dart';

/// What every Team screen shares: the API and the ways out of the section (other bottom-bar tabs).
class TeamEnv {
  TeamEnv({TeamApi? api, this.onNavigate}) : api = api ?? TeamApi();
  final TeamApi api;

  /// Bottom-bar tabs this section does not own: 'money', 'item', 'bill', 'online', 'stock'.
  final ValueChanged<String>? onNavigate;

  void tab(BuildContext context, String id) {
    if (onNavigate != null) {
      onNavigate!(id);
    } else {
      showToast(context, 'That part of the app is not built yet.');
    }
  }

  Future<T?> push<T>(BuildContext context, Widget screen) =>
      Navigator.of(context).push<T>(MaterialPageRoute(builder: (_) => screen));
}

const kRedLine = Color(0xFFEF4444);
const kRedPale = Color(0xFFFFE4E4);
const kAmber = Color(0xFFF59E0B);
const kAmberPale = Color(0xFFFEF3C7);
const kGreenDeep = Color(0xFF10A36F);
const kTileLine = Color(0xFFE5E7EB);

/// "10:42 AM".
String clock12(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '$h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';
}

/// "10:42 AM" today, "Yesterday · 6:18 PM", or "05 Oct · 6:18 PM".
String whenLabel(DateTime d, [DateTime? now]) {
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day),
      day = DateTime(d.year, d.month, d.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return clock12(d);
  if (diff == 1) return 'Yesterday · ${clock12(d)}';
  const m = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${d.day.toString().padLeft(2, '0')} ${m[d.month - 1]} · ${clock12(d)}';
}

/// Status chip of a person: text and colours (Figma: Active green, Invited green, Paused grey, Expired amber).
(String, Color, Color) personStatus(String s) => switch (s) {
  'active' => ('Active', kChipGreen, kGreenDeep),
  'invited' => ('Invited', kChipGreen, kGreenDeep),
  'expired' => ('Expired', kAmberPale, kWarnText),
  _ => ('Paused', kInfoGreyBg, kMuted),
};

/// Status chip of a task: text and colours (Figma: In progress green, Assigned grey, Overdue red).
(String, Color, Color) taskStatus(String s) => switch (s) {
  'in_progress' => ('In progress', kChipGreen, kGreenDeep),
  'overdue' => ('Overdue', kRedPale, kBadText),
  'submitted' => ('Waiting for review', kAmberPale, kWarnText),
  'completed' => ('Completed', kChipGreen, kGreenText),
  'failed' => ('Failed', kRedPale, kBadText),
  'draft' => ('Not assigned', kInfoGreyBg, kMuted),
  _ => ('Assigned', kInfoGreyBg, kMuted),
};

/// Page frame of every Team screen: top bar, scrolling content, the dark bottom bar.
class TeamPage extends StatelessWidget {
  const TeamPage({
    super.key,
    required this.env,
    required this.title,
    required this.children,
    this.subtitle,
    this.onRefresh,
    this.bottom,
  });
  final TeamEnv env;
  final String title;
  final String? subtitle;
  final List<Widget> children;
  final Future<void> Function()? onRefresh;
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    Widget list = ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        Semantics(header: true, child: Text(title, style: inter(24, 700))),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(subtitle!, style: inter(13.5, 400, color: kMuted, height: 1.35)),
        ],
        const SizedBox(height: 14),
        ...children,
      ],
    );
    if (onRefresh != null) {
      list = RefreshIndicator(onRefresh: onRefresh!, child: list);
    }
    return Scaffold(
      backgroundColor: kBg,
      body: Column(
        children: [
          OrdersTopBar(
            title: 'Team',
            onBack: Navigator.of(context).canPop()
                ? () => Navigator.of(context).maybePop()
                : null,
          ),
          Expanded(child: list),
          if (bottom != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: bottom,
            ),
        ],
      ),
      bottomNavigationBar: PosBottomNav(
        active: '',
        onTap: (id) => env.tab(context, id),
      ),
    );
  }
}

/// Loading / error / content with a retry.
class TeamLoad<T> extends StatelessWidget {
  const TeamLoad({
    super.key,
    required this.data,
    required this.error,
    required this.onRetry,
    required this.builder,
  });
  final T? data;
  final String? error;
  final VoidCallback onRetry;
  final List<Widget> Function(T data) builder;
  @override
  Widget build(BuildContext context) {
    if (data != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: builder(data as T),
      );
    }
    if (error != null) {
      return OrderCardBox(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Could not load this', style: inter(15, 600)),
            const SizedBox(height: 6),
            Text(error!, style: inter(13, 400, color: kMuted)),
            const SizedBox(height: 12),
            LightCta(label: 'Try again', onPressed: onRetry),
          ],
        ),
      );
    }
    return const Padding(
      padding: EdgeInsets.all(40),
      child: Center(child: CircularProgressIndicator(color: kInk)),
    );
  }
}

/// Plain sentence of any thrown error.
String errorText(Object e) => e is TeamApiException
    ? e.message
    : (e.toString().startsWith('Exception: ')
          ? e.toString().substring(11)
          : e.toString());

class Avatar extends StatelessWidget {
  const Avatar(this.initials, {super.key, this.size = 44, this.soft = false});
  final String initials;
  final double size;
  final bool soft;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: soft ? kInfoGreyBg : kChipGreen,
      shape: BoxShape.circle,
    ),
    child: ExcludeSemantics(
      child: Text(initials, style: inter(size * 0.32, 700)),
    ),
  );
}

/// A big number with a label and a note (Team dashboard tiles).
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.value,
    required this.label,
    required this.note,
    this.color = kInk,
    this.onTap,
  });
  final String value, label, note;
  final Color color;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Semantics(
    button: onTap != null,
    label: '$value $label, $note',
    child: Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: kTileLine),
          ),
          child: ExcludeSemantics(
            child: Row(
              children: [
                Text(value, style: inter(30, 600, color: color)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: inter(14, 600), maxLines: 2),
                      const SizedBox(height: 2),
                      Text(
                        note,
                        style: inter(12, 400, color: kMuted),
                        maxLines: 2,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// One person: avatar, name, "Role · Place", status on the right.
class PersonCard extends StatelessWidget {
  const PersonCard({
    super.key,
    required this.name,
    required this.initials,
    required this.sub,
    required this.status,
    this.onTap,
  });
  final String name, initials, sub, status;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final (label, _, fg) = personStatus(status);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Semantics(
        button: onTap != null,
        label: '$name, $sub, $label',
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: kTileLine),
              ),
              child: ExcludeSemantics(
                child: Row(
                  children: [
                    Avatar(initials),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            style: inter(16, 600),
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            sub,
                            style: inter(13, 400, color: kMuted),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      label,
                      style: inter(
                        13.5,
                        600,
                        color: status == 'paused'
                            ? kMuted
                            : (status == 'expired' ? kWarnText : fg),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Lime call-to-action (Figma: "Invite team member", "Create task", "Save changes").
class LimeButton extends StatelessWidget {
  const LimeButton(
    this.label, {
    super.key,
    required this.onPressed,
    this.busy = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  @override
  Widget build(BuildContext context) => Opacity(
    opacity: onPressed == null ? 0.55 : 1,
    child: Semantics(
      button: true,
      enabled: onPressed != null && !busy,
      label: label,
      child: Material(
        color: kLime,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: busy ? null : onPressed,
          child: SizedBox(
            height: 56,
            width: double.infinity,
            child: Center(
              child: busy
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: kInk,
                      ),
                    )
                  : ExcludeSemantics(child: Text(label, style: inter(16, 600))),
            ),
          ),
        ),
      ),
    ),
  );
}

/// White bordered button (Figma: "Suspend access", "Resend invitation").
class OutlineButton2 extends StatelessWidget {
  const OutlineButton2(
    this.label, {
    super.key,
    required this.onPressed,
    this.danger = false,
    this.busy = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final bool danger, busy;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onPressed != null && !busy,
    label: label,
    child: Material(
      color: Colors.white,
      shape: StadiumBorder(
        side: BorderSide(color: danger ? kRedLine : const Color(0xFFD1D5DB)),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: busy ? null : onPressed,
        child: SizedBox(
          height: 54,
          width: double.infinity,
          child: Center(
            child: busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: kInk,
                    ),
                  )
                : ExcludeSemantics(
                    child: Text(
                      label,
                      style: inter(16, 600, color: danger ? kBadText : kInk),
                    ),
                  ),
          ),
        ),
      ),
    ),
  );
}

/// Filter chips: (id, label, count). The active one is green.
class TeamChips extends StatelessWidget {
  const TeamChips({
    super.key,
    required this.items,
    required this.active,
    required this.onTap,
  });
  final List<(String id, String label, num? count)> items;
  final String active;
  final ValueChanged<String> onTap;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (id, label, count) in items)
          Semantics(
            button: true,
            selected: id == active,
            label: count == null ? label : '$label $count',
            child: InkWell(
              borderRadius: BorderRadius.circular(99),
              onTap: () => onTap(id),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: id == active ? kChipGreen : Colors.white,
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(
                    color: id == active ? kChipGreen : kTileLine,
                  ),
                ),
                child: ExcludeSemantics(
                  child: Text(
                    count == null ? label : '$label $count',
                    style: inter(
                      12.5,
                      600,
                      color: id == active ? kGreenText : kInk,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

/// A tinted banner for an error or a note (Figma: "Invitation couldn't be sent").
class TeamBanner extends StatelessWidget {
  const TeamBanner({
    super.key,
    required this.title,
    required this.body,
    this.onClose,
  });
  final String title, body;
  final VoidCallback? onClose;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    container: true,
    label: '$title. $body',
    child: Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: kRedPale,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kRedLine),
      ),
      child: ExcludeSemantics(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(LucideIcons.circleX, size: 20, color: kBadText),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: inter(14, 700)),
                  const SizedBox(height: 4),
                  Text(
                    body,
                    style: inter(13, 400, color: kMuted, height: 1.35),
                  ),
                ],
              ),
            ),
            if (onClose != null)
              InkWell(
                onTap: onClose,
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(LucideIcons.x, size: 18, color: kMuted),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

/// A labelled text field in the Figma style (grey fill, red border and message on error).
class TeamField extends StatelessWidget {
  const TeamField({
    super.key,
    required this.label,
    required this.controller,
    this.error,
    this.prefix,
    this.keyboard,
    this.hint,
    this.formatters,
    this.onChanged,
    this.action = TextInputAction.next,
  });
  final String label;
  final TextEditingController controller;
  final String? error, prefix, hint;
  final TextInputType? keyboard;
  final List<TextInputFormatter>? formatters;
  final ValueChanged<String>? onChanged;
  final TextInputAction action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: inter(12.5, 600)),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          keyboardType: keyboard,
          inputFormatters: formatters,
          textInputAction: action,
          onChanged: onChanged,
          style: inter(17, 400),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: inter(17, 400, color: kKicker),
            prefixIcon: prefix == null
                ? null
                : Padding(
                    padding: const EdgeInsets.only(left: 14, right: 10),
                    child: Center(
                      widthFactor: 1,
                      child: Text(prefix!, style: inter(17, 500)),
                    ),
                  ),
            filled: true,
            fillColor: kSoftField,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 16,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(
                color: error != null ? kRedLine : kTileLine,
                width: error != null ? 1.4 : 1,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(
                color: error != null ? kRedLine : kInk,
                width: 1.4,
              ),
            ),
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(error!, style: inter(12.5, 400, color: kBadText)),
          ),
      ],
    ),
  );
}

/// A tappable "select" row (Role, Location, Assign to): label above, value in a white box.
class TeamSelect extends StatelessWidget {
  const TeamSelect({
    super.key,
    required this.label,
    required this.value,
    required this.onTap,
    this.placeholder = 'Choose',
  });
  final String label;
  final String? value;
  final String placeholder;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: inter(12.5, 600)),
        const SizedBox(height: 6),
        Semantics(
          button: true,
          label: '$label, ${value ?? placeholder}',
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: Container(
              height: 54,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: kTileLine),
              ),
              child: ExcludeSemantics(
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        value ?? placeholder,
                        style: inter(
                          16,
                          400,
                          color: value == null ? kKicker : kInk,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const Icon(
                      LucideIcons.chevronDown,
                      size: 18,
                      color: kMuted,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
