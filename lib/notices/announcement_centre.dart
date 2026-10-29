import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_api.dart' show Facts;
import '../orders/order_widgets.dart';
import '../ui/theme.dart';
import 'notices_api.dart';
import 'notices_widgets.dart';
import '../ui/i18n.dart';

/// Figma "Announcement Centre": official news from the platform. Important ones sit in an amber card; the rest below. Read only, plus "mark read".
class AnnouncementCentre extends StatefulWidget {
  const AnnouncementCentre({super.key, required this.api, this.onUnread});
  final NoticesApi api;
  final ValueChanged<int>? onUnread;
  @override
  State<AnnouncementCentre> createState() => _AnnouncementCentreState();
}

class _AnnouncementCentreState extends State<AnnouncementCentre> {
  Facts? _data;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.api.announcements();
      if (!mounted) return;
      setState(() {
        _data = d;
        _error = null;
      });
      widget.onUnread?.call(d.n('unread').toInt());
    } catch (e) {
      if (mounted) setState(() => _error = noticeError(e));
    }
  }

  Future<void> _read(Facts a) async {
    if (a.b('is_read')) return;
    try {
      await widget.api.markAnnouncementRead(id: a.s('id'));
      await _load();
    } catch (e) {
      if (mounted) showToast(context, noticeError(e));
    }
  }

  static String _label(String c) => switch (c) {
    'maintenance' => 'Maintenance',
    'new_feature' => 'New feature',
    'policy_update' => 'Policy update',
    _ => 'Business update',
  };

  @override
  Widget build(BuildContext context) => NoticeLoad<Facts>(
    data: _data,
    error: _error,
    onRetry: () {
      setState(() => _error = null);
      _load();
    },
    builder: (d) {
      final unread = d.n('unread').toInt();
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            Text(tr('Announcement Centre'), style: inter(26, 700)),
            const SizedBox(height: 6),
            Text(
              'Official news and updates from OneLocal.',
              style: inter(14.5, 400, color: kMuted),
            ),
            const SizedBox(height: 16),
            if (d.l('important').isNotEmpty) ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Important announcements',
                      style: inter(17, 700),
                    ),
                  ),
                  if (unread > 0)
                    DotChip('$unread unread', bg: Colors.white, fg: kInk),
                ],
              ),
              const SizedBox(height: 10),
              for (final a in d.l('important'))
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _card(a, important: true),
                ),
            ],
            if (d.l('latest').isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(tr('Latest from OneLocal'), style: inter(17, 700)),
              const SizedBox(height: 10),
              for (final a in d.l('latest'))
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _card(a, important: false),
                ),
            ],
            if (d.l('important').isEmpty && d.l('latest').isEmpty)
              OrderCardBox(
                child: Text(
                  'No announcements right now.',
                  style: inter(14.5, 400, color: kMuted),
                ),
              ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                "You're up to date with OneLocal announcements.",
                style: inter(13, 400, color: kMuted),
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget _card(Facts a, {required bool important}) {
    final unread = !a.b('is_read');
    final date = a.t('published_at');
    final tag = important
        ? TagChip(
            _label(a.s('category')),
            bg: const Color(0xFFFFF0D2),
            fg: const Color(0xFF92400E),
          )
        : TagChip(
            _label(a.s('category')),
            bg: a.s('category') == 'new_feature' ? kChipGreen : kInfoGreyBg,
            fg: a.s('category') == 'new_feature' ? kGreenText : kMuted,
          );
    return Semantics(
      button: true,
      label: '${a.s('title')}. ${a.s('body')}${unread ? '. Unread' : ''}',
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => _read(a),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: important ? const Color(0xFFFFF4DD) : Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: important
                  ? const Color(0xFFF6CF8A)
                  : const Color(0xFFECEDE8),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  tag,
                  const Spacer(),
                  if (date != null)
                    Text(
                      noticeDate(date),
                      style: inter(12.5, 400, color: kMuted),
                    ),
                  if (unread)
                    const Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: UnreadDot(),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    important ? LucideIcons.triangleAlert : LucideIcons.info,
                    size: 20,
                    color: kInk,
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text(a.s('title'), style: inter(16.5, 700))),
                ],
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(left: 30),
                child: Text(
                  a.s('body'),
                  style: inter(14, 400, color: kMuted, height: 1.4),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
