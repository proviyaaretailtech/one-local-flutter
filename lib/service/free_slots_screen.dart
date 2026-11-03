import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart' show OrderCardBox, kChipGreen, kGreenText;
import '../ui/theme.dart';
import 'booking_screen.dart';
import 'service_api.dart';
import 'service_widgets.dart';

/// Free slots today (founder, 2 Nov 2026: "this should show which slots and who is free"): who is free now, busy (till when) or off, and
/// each person's free start times. A time opens a new booking for today. From `svc_free_slots`, the same rule the dashboard counts with.
class FreeSlotsScreen extends StatefulWidget {
  const FreeSlotsScreen({super.key, this.api});
  final ServiceApi? api;
  @override
  State<FreeSlotsScreen> createState() => _FreeSlotsScreenState();
}

class _FreeSlotsScreenState extends State<FreeSlotsScreen> {
  late final ServiceApi _api = widget.api ?? ServiceApi();
  FreeSlotsData? _data;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final d = await _api.freeSlots();
      if (mounted) setState(() => _data = d);
    } on ServiceApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load free slots. Check the connection and try again.');
    }
  }

  Future<void> _book() async {
    final booked = await Navigator.of(context).push<AppointmentView>(MaterialPageRoute(builder: (_) => ServiceBookingScreen(api: _api, date: DateTime.now())));
    if (booked != null && mounted) _load();
  }

  /// Where a person is right now: (word, background, text colour).
  (String, Color, Color) _state(SvcData p) => switch (p.s('state')) {
        'free_now' => ('Free now', kChipGreen, kGreenText),
        'busy' => ('Busy till ${p.s('busy_until')}', const Color(0xFFFFF4E0), const Color(0xFFB45309)),
        'on_job' => ('On a job', const Color(0xFFFFF4E0), const Color(0xFFB45309)),
        'not_working_now' => ('Not working now', const Color(0xFFF1F2F4), kMuted),
        'off' => ('Off today', const Color(0xFFF1F2F4), kMuted),
        _ => ('Working', kChipGreen, kGreenText),
      };

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final free = d?.freeNow.length ?? 0;
    return ServicePage(
      title: 'Free slots',
      subtitle: d == null ? 'Who is free and when, today' : '${d.dateLabel} · ${d.slotMinutes > 0 ? '${d.slotMinutes} min slots' : 'no bookable service yet'}',
      onRefresh: _load,
      error: _error,
      onRetry: _load,
      body: d == null
          ? null
          : [
              SvcTopButton('+ New booking', key: const ValueKey('free-book'), onTap: _book),
              const SizedBox(height: 10),
              SvcCard(children: [
                Row(children: [
                  Expanded(child: _figure('${d.total}', d.total == 1 ? 'free slot left today' : 'free slots left today', key: 'free-total')),
                  Expanded(child: _figure('$free', free == 1 ? 'person free now' : 'people free now', key: 'free-now')),
                ]),
                if (d.closed != null) ...[const SizedBox(height: 8), Text('Closed today: ${d.closed}', style: inter(13, 600, color: const Color(0xFFB45309)))],
              ]),
              const SizedBox(height: 12),
              SvcSectionHead('Who is free', count: '${d.people.length}'),
              if (d.people.isEmpty)
                OrderCardBox(child: Text('No bookable staff yet. Add people in Team management.', style: inter(14, 400, color: kMuted))),
              for (final p in d.people) ...[_person(p), const SizedBox(height: 8)],
            ],
    );
  }

  Widget _figure(String n, String label, {required String key}) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(n, key: ValueKey(key), style: inter(22, 800)),
        Text(label, style: inter(12, 500, color: kMuted)),
      ]);

  Widget _person(SvcData p) {
    final (word, bg, fg) = _state(p);
    final slots = p.l('slots');
    final name = p.s('name');
    return Container(
      key: ValueKey('free-person-${p.s('staff_id')}'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: kLine)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: bg,
            child: Text(name.isEmpty ? '?' : name[0].toUpperCase(), style: inter(14, 800, color: fg)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(14.5, 700)),
              if (p.s('title').isNotEmpty) Text(p.s('title'), style: inter(12, 400, color: kMuted)),
            ]),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(40)),
            child: Text(word, style: inter(11.5, 700, color: fg)),
          ),
        ]),
        const SizedBox(height: 10),
        if (slots.isEmpty)
          Text(p.s('state') == 'off' ? 'Not working today.' : 'No free slot left today.', style: inter(12.5, 500, color: kMuted))
        else ...[
          Text('${slots.length} free ${slots.length == 1 ? 'slot' : 'slots'}', style: inter(12, 600, color: kMuted)),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final s in slots)
              Material(
                color: kChipGreen,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  key: ValueKey('free-slot-${p.s('staff_id')}-${s.s('time')}'),
                  borderRadius: BorderRadius.circular(10),
                  onTap: _book,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(LucideIcons.clock, size: 12, color: kGreenText),
                      const SizedBox(width: 4),
                      Text(s.s('label'), style: inter(12.5, 700, color: kGreenText)),
                    ]),
                  ),
                ),
              ),
          ]),
        ],
      ]),
    );
  }
}
