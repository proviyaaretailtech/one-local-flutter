import 'package:flutter/material.dart';

import '../orders/order_widgets.dart';
import '../ui/theme.dart';
import 'service_api.dart';
import 'service_menu.dart';
import 'service_widgets.dart';

/// Figma 87 "Staff & Service Providers": who takes bookings, their skills, certification, eligible services, area and hours, and whether
/// they are available, on a job or off duty right now (all computed by the server).
class StaffScreen extends StatefulWidget {
  const StaffScreen({super.key, required this.api, this.business = '', this.onNavigate});
  final ServiceApi api;
  final String business;
  final ValueChanged<String>? onNavigate;
  @override
  State<StaffScreen> createState() => _StaffScreenState();
}

class _StaffScreenState extends State<StaffScreen> {
  StaffData? _d;
  String? _error;
  String _q = '', _filter = 'all';
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final mine = ++_seq;
    try {
      final d = await widget.api.staff(q: _q, filter: _filter);
      if (mounted && mine == _seq) setState(() { _d = d; _error = null; });
    } catch (e) {
      if (mounted && mine == _seq) setState(() => _error = e.toString());
    }
  }

  Future<void> _edit([SvcData? provider]) async {
    final d = _d;
    if (d == null || !d.canEdit) return;
    if (provider == null && d.candidates.isEmpty) {
      showToast(context, 'Everyone on the team is already a provider. Invite staff from Setup first.');
      return;
    }
    final saved = await showOrderSheet<bool>(context, title: provider == null ? 'Add provider' : provider.s('name'), body: (ctx) => _ProviderForm(api: widget.api, data: d, provider: provider));
    if (saved == true && mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final total = d?.count('all') ?? 0;
    return ServicePage(
      title: 'Staff & Service Providers',
      subtitle: d == null ? '' : '$total team ${total == 1 ? 'member' : 'members'} · Skills and service eligibility',
      business: widget.business,
      onMenu: () => showServiceMenu(context, widget.api, business: widget.business, onNavigate: widget.onNavigate, current: 'staff'),
      onNavigate: widget.onNavigate,
      onRefresh: _load,
      error: _error,
      onRetry: _load,
      body: d == null
          ? null
          : [
              SvcSearch(hint: 'Search name, skill or certification...', fieldKey: const ValueKey('staff-search'), onChanged: (v) {
                _q = v;
                _load();
              }),
              const SizedBox(height: 14),
              SvcChips(
                options: [('all', 'All ${d.count('all')}'), ('available', 'Available ${d.count('available')}'), ('on_job', 'On job ${d.count('on_job')}'), ('off_duty', 'Off duty ${d.count('off_duty')}')],
                selected: _filter,
                onSelect: (v) {
                  _filter = v;
                  _load();
                },
              ),
              const SizedBox(height: 4),
              if (d.providers.isEmpty) OrderCardBox(child: Text(total == 0 ? 'No providers yet. Add the people who take bookings.' : 'Nobody matches.', style: inter(14, 400, color: kMuted))),
              for (final p in d.providers)
                SvcCard(
                  title: p.s('title').isEmpty ? p.s('name') : '${p.s('name')} · ${p.s('title')}',
                  onTap: d.canEdit ? () => _edit(p) : null,
                  children: [
                    Align(alignment: Alignment.centerLeft, child: svcStatus(p.s('state_label'), p.s('tone'))),
                    const SizedBox(height: 8),
                    if (p.s('skills').isNotEmpty) SvcKV('Skills', p.s('skills'), labelWidth: 140),
                    if (p.s('certification').isNotEmpty) SvcKV('Certification', p.s('certification'), labelWidth: 140),
                    SvcKV('Eligible services', p.s('services').isEmpty ? 'None yet' : p.s('services'), labelWidth: 140),
                    SvcKV('Service area', p.s('service_area'), labelWidth: 140),
                    SvcKV('Availability', p.s('availability'), labelWidth: 140),
                  ],
                ),
              if (d.canEdit) DarkCta(label: '+ Add provider', onPressed: () => _edit()),
            ],
    );
  }
}

class _ProviderForm extends StatefulWidget {
  const _ProviderForm({required this.api, required this.data, this.provider});
  final ServiceApi api;
  final StaffData data;
  final SvcData? provider;
  @override
  State<_ProviderForm> createState() => _ProviderFormState();
}

class _ProviderFormState extends State<_ProviderForm> {
  late final p = widget.provider;
  late String? _staff = p?.s('staff_id');
  late final _title = TextEditingController(text: p?.s('title') ?? '');
  late final _skills = TextEditingController(text: p?.s('skills') ?? '');
  late final _cert = TextEditingController(text: p?.s('certification') ?? '');
  late final _area = TextEditingController(text: p?.s('service_area') ?? '');
  late final Set<String> _services = {...?p?.ls('service_ids')};
  late bool _bookable = p == null || p!.b('is_bookable');
  final _key = ServiceApi.newKey();
  bool _busy = false;

  Future<void> _save() async {
    if (_staff == null) {
      showToast(context, 'Choose the staff member.');
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.api.saveProvider({
        'staff_id': _staff,
        'title': _title.text.trim(),
        'skills': _skills.text.trim(),
        'certification': _cert.text.trim(),
        'service_area': _area.text.trim(),
        'is_bookable': _bookable,
        'service_ids': _services.toList(),
      }, key: _key);
      if (mounted) Navigator.pop(context, true);
    } on ServiceApiException catch (e) {
      if (mounted) showToast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _f(String hint, TextEditingController c) => Padding(padding: const EdgeInsets.only(bottom: 10), child: TextField(key: ValueKey('provider-$hint'), controller: c, decoration: InputDecoration(hintText: hint)));

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (p == null) ...[
            Text('Staff member', style: inter(13, 600, color: kMuted)),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final c in widget.data.candidates) ModeChip(c.s('name'), selected: _staff == c.s('staff_id'), onTap: () => setState(() => _staff = c.s('staff_id'))),
            ]),
            const SizedBox(height: 12),
          ],
          _f('Title shown to staff (Senior stylist)', _title),
          _f('Skills', _skills),
          _f('Certification', _cert),
          _f('Service area', _area),
          Text('Eligible services', style: inter(13, 600, color: kMuted)),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final s in widget.data.services)
              ModeChip(s.s('name'), selected: _services.contains(s.s('id')), onTap: () => setState(() => _services.contains(s.s('id')) ? _services.remove(s.s('id')) : _services.add(s.s('id')))),
          ]),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: Text('Takes bookings', style: inter(14.5, 500)), value: _bookable, onChanged: (v) => setState(() => _bookable = v)),
          const SizedBox(height: 8),
          DarkCta(label: 'Save provider', busy: _busy, onPressed: _busy ? null : _save),
        ]),
      );
}
