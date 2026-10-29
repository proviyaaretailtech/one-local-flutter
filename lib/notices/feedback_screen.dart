import 'package:flutter/material.dart';

import '../inventory/inventory_api.dart' show Facts;
import '../orders/order_widgets.dart';
import '../ui/theme.dart';
import 'notices_api.dart';
import 'notices_widgets.dart';
import '../ui/i18n.dart';
import '../ui/motion.dart';

/// Customer feedback: average rating, status chips, each comment with Acknowledge / Resolve and an optional reply.
class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({super.key, required this.api});
  final NoticesApi api;
  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  static const _chips = [
    (null, 'All'),
    ('new', 'New'),
    ('acknowledged', 'Acknowledged'),
    ('resolved', 'Resolved'),
  ];
  String? _status;
  Facts? _data;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await widget.api.feedback(status: _status);
      if (!mounted) return;
      setState(() {
        _data = d;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = noticeError(e));
    }
  }

  Future<void> _answer(Facts f, String status) async {
    final reply = TextEditingController(text: f.s('response'));
    final send = await showOlDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(
          status == 'resolved' ? 'Resolve feedback' : 'Acknowledge feedback',
        ),
        content: TextField(
          controller: reply,
          maxLength: 1000,
          maxLines: 3,
          decoration: InputDecoration(hintText: tr('Reply (optional)')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(tr('Cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(tr('Save')),
          ),
        ],
      ),
    );
    if (send != true) return;
    try {
      await widget.api.respond(f.s('id'), status, reply.text);
      await _load();
    } catch (e) {
      if (mounted) showToast(context, noticeError(e));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: kBg,
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OrdersTopBar(
          title: tr('Customer feedback'),
          onBack: () => Navigator.of(context).maybePop(),
        ),
        Expanded(
          child: NoticeLoad<Facts>(
            data: _data,
            error: _error,
            onRetry: () {
              setState(() => _error = null);
              _load();
            },
            builder: (d) {
              final s = d.m('summary');
              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: [
                  OrderCardBox(
                    child: Row(
                      children: [
                        Text(
                          s.no('average') == null
                              ? '–'
                              : s.n('average').toString(),
                          style: inter(30, 700),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            '${s.n('total').toInt()} reviews · ${s.n('new').toInt()} new · ${s.n('resolved').toInt()} resolved',
                            style: inter(14, 400, color: kMuted),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final c in _chips)
                        SmallPill(
                          c.$2,
                          bg: _status == c.$1 ? kChipGreen : Colors.white,
                          fg: _status == c.$1 ? kGreenText : kMuted,
                          onTap: () {
                            setState(() {
                              _status = c.$1;
                              _data = null;
                            });
                            _load();
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (d.l('items').isEmpty)
                    OrderCardBox(
                      child: Text(
                        'No feedback here yet.',
                        style: inter(14.5, 400, color: kMuted),
                      ),
                    ),
                  for (final f in d.l('items'))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: OrderCardBox(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    f.s('customer_name').isEmpty
                                        ? 'Customer'
                                        : f.s('customer_name'),
                                    style: inter(15.5, 700),
                                  ),
                                ),
                                Text(
                                  '${'★' * f.n('rating').toInt()}${'☆' * (5 - f.n('rating').toInt())}',
                                  semanticsLabel:
                                      '${f.n('rating').toInt()} out of 5',
                                  style: inter(
                                    14,
                                    700,
                                    color: const Color(0xFFB45309),
                                  ),
                                ),
                              ],
                            ),
                            if (f.s('comment').isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  f.s('comment'),
                                  style: inter(14, 400, height: 1.4),
                                ),
                              ),
                            if (f.s('response').isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  'Your reply: ${f.s('response')}',
                                  style: inter(13.5, 400, color: kMuted),
                                ),
                              ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                DotChip(f.s('status')),
                                const Spacer(),
                                if (d.b('can_respond') &&
                                    f.s('status') == 'new')
                                  SmallPill(
                                    'Acknowledge',
                                    onTap: () => _answer(f, 'acknowledged'),
                                  ),
                                if (d.b('can_respond') &&
                                    f.s('status') != 'resolved') ...[
                                  const SizedBox(width: 8),
                                  SmallPill(
                                    'Resolve',
                                    onTap: () => _answer(f, 'resolved'),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    ),
  );
}
