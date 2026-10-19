import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart';
import '../states/state_kit.dart';
import '../ui/theme.dart';

/// Loading / error (with retry) / content, shared by the section N tabs. Errors show the server's sentence.
class NoticeLoad<T> extends StatelessWidget {
  const NoticeLoad({
    super.key,
    required this.data,
    required this.error,
    required this.onRetry,
    required this.builder,
  });
  final T? data;
  final String? error;
  final VoidCallback onRetry;
  final Widget Function(T data) builder;

  @override
  Widget build(BuildContext context) {
    if (data != null) return builder(data as T);
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: StatusCard(
          icon: LucideIcons.cloudOff,
          tone: StateTone.warn,
          title: 'Could not load this',
          body: error!,
          primaryLabel: 'Try again',
          onPrimary: onRetry,
        ),
      );
    }
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(40),
        child: CircularProgressIndicator(strokeWidth: 2, color: kGreenText),
      ),
    );
  }
}

/// Green dot of an unread row.
class UnreadDot extends StatelessWidget {
  const UnreadDot({super.key});
  @override
  Widget build(BuildContext context) => Container(
    width: 7,
    height: 7,
    decoration: const BoxDecoration(
      color: Color(0xFF3DB800),
      shape: BoxShape.circle,
    ),
  );
}

/// Icon, tint and label of a notification kind (Figma: Notification Centre rows).
({IconData icon, Color bg, Color fg}) kindStyle(String kind) => switch (kind) {
  'order_confirmed' => (
    icon: LucideIcons.clipboardCheck,
    bg: kChipGreen,
    fg: kInk,
  ),
  'payment_received' => (icon: LucideIcons.fileText, bg: kChipGreen, fg: kInk),
  'low_stock' => (
    icon: LucideIcons.package,
    bg: kWarnBg,
    fg: const Color(0xFFEA580C),
  ),
  'order_ready' => (icon: LucideIcons.shoppingBag, bg: kChipGreen, fg: kInk),
  'order_delivered' => (icon: LucideIcons.truck, bg: kChipGreen, fg: kInk),
  'order_cancelled' => (icon: LucideIcons.circleX, bg: kBadBg, fg: kBadText),
  'payout_sent' => (icon: LucideIcons.landmark, bg: kChipGreen, fg: kInk),
  'documents_verified' => (
    icon: LucideIcons.shieldCheck,
    bg: kChipGreen,
    fg: kInk,
  ),
  _ => (icon: LucideIcons.bell, bg: kInfoGreyBg, fg: kMuted),
};
