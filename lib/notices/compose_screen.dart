import 'package:flutter/material.dart';

import '../inventory/inventory_api.dart' show Facts;
import '../orders/order_widgets.dart';
import '../states/state_kit.dart';
import '../ui/theme.dart';
import 'notices_api.dart';
import 'notices_widgets.dart';

/// Message customers: channel, group, a live count of who has agreed to hear from the store, the text, "Queue message".
/// The database records and queues it (one audited step). Nothing is sent from the app or the server today; the screen says so.
class ComposeScreen extends StatefulWidget {
  const ComposeScreen({super.key, required this.api});
  final NoticesApi api;
  @override
  State<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends State<ComposeScreen> {
  static const _channels = [
    ('whatsapp', 'WhatsApp'),
    ('sms', 'SMS'),
    ('email', 'Email'),
    ('push', 'App push'),
  ];
  final _title = TextEditingController(), _message = TextEditingController();
  Facts? _options, _audience;
  String? _error, _audienceError;
  String _channel = 'sms', _segment = 'all';
  bool _busy = false;
  Facts? _queued;
  final String _key = NoticesApi.newKey();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _title.dispose();
    _message.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final o = await widget.api.options();
      if (!mounted) return;
      setState(() {
        _options = o;
        _error = null;
      });
      _refreshAudience();
    } catch (e) {
      if (mounted) setState(() => _error = noticeError(e));
    }
  }

  Future<void> _refreshAudience() async {
    setState(() {
      _audience = null;
      _audienceError = null;
    });
    try {
      final a = await widget.api.audience(_segment, _channel);
      if (mounted) setState(() => _audience = a);
    } catch (e) {
      if (mounted) setState(() => _audienceError = noticeError(e));
    }
  }

  Future<void> _send() async {
    setState(() => _busy = true);
    try {
      final q = await widget.api.queue(
        channel: _channel,
        segment: _segment,
        message: _message.text,
        title: _title.text,
        key: _key,
      );
      if (!mounted) return;
      setState(() => _queued = q);
    } catch (e) {
      if (mounted) showToast(context, noticeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final can = _options?.b('can_send') ?? false;
    final reach = _audience?.n('reachable').toInt();
    return Scaffold(
      backgroundColor: kBg,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OrdersTopBar(
            title: 'Message customers',
            onBack: () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: NoticeLoad<Facts>(
              data: _options,
              error: _error,
              onRetry: () {
                setState(() => _error = null);
                _load();
              },
              builder: (o) => SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                child: _queued != null
                    ? _done(_queued!)
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          InfoBox(lines: [o.s('note')]),
                          const SizedBox(height: 16),
                          const Kick('Channel'),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final c in _channels)
                                SmallPill(
                                  c.$2,
                                  bg: _channel == c.$1
                                      ? kChipGreen
                                      : Colors.white,
                                  fg: _channel == c.$1 ? kGreenText : kMuted,
                                  onTap: () {
                                    setState(() => _channel = c.$1);
                                    _refreshAudience();
                                  },
                                ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          const Kick('Who gets it'),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final s in o.l('segments'))
                                SmallPill(
                                  '${s.s('name')} (${s.n('in_segment').toInt()})',
                                  bg: _segment == s.s('id')
                                      ? kChipGreen
                                      : Colors.white,
                                  fg: _segment == s.s('id')
                                      ? kGreenText
                                      : kMuted,
                                  onTap: () {
                                    setState(() => _segment = s.s('id'));
                                    _refreshAudience();
                                  },
                                ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          OrderCardBox(
                            child: _audienceError != null
                                ? Text(
                                    _audienceError!,
                                    style: inter(14, 400, color: kBadText),
                                  )
                                : _audience == null
                                ? Text(
                                    'Counting…',
                                    style: inter(14, 400, color: kMuted),
                                  )
                                : Text(
                                    '$reach ${reach == 1 ? 'customer has' : 'customers have'} agreed to hear from you on this channel'
                                    '${_audience!.n('without_consent') > 0 ? ' (${_audience!.n('without_consent').toInt()} in this group have not)' : ''}.',
                                    style: inter(14, 600, height: 1.4),
                                  ),
                          ),
                          const SizedBox(height: 16),
                          const Kick('Title (optional)'),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _title,
                            maxLength: 120,
                            decoration: const InputDecoration(
                              filled: true,
                              fillColor: Colors.white,
                              hintText: 'Festive offer',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const Kick('Message'),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _message,
                            maxLength: 1000,
                            minLines: 4,
                            maxLines: 8,
                            onChanged: (_) => setState(() {}),
                            decoration: const InputDecoration(
                              filled: true,
                              fillColor: Colors.white,
                              hintText: 'Write your message',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 10),
                          if (!can)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: Text(
                                'Your role can read customer messages but not queue them.',
                                style: inter(13.5, 400, color: kMuted),
                              ),
                            ),
                          DarkCta(
                            label: 'Queue message',
                            busy: _busy,
                            onPressed:
                                can &&
                                    (reach ?? 0) > 0 &&
                                    _message.text.trim().isNotEmpty
                                ? _send
                                : null,
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _done(Facts q) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      StatusCard(
        icon: Icons.check_rounded,
        tone: StateTone.ok,
        title: q.s('status') == 'scheduled'
            ? 'Message scheduled'
            : 'Message queued',
        body:
            '${q.n('audience_count').toInt()} customers on ${q.s('channel')}. ${q.s('status_note')}',
        primaryLabel: 'Done',
        onPrimary: () => Navigator.of(context).maybePop(),
      ),
    ],
  );
}
