import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api/rpc_client.dart';
import '../auth/partner_api.dart';
import '../ui/app_header.dart';
import '../ui/i18n.dart';
import '../ui/theme.dart';

// Store staff (founder, 28 Oct 2026; the web POS's Store Staff Management made for the phone, with only what a shop needs):
// Staff | Attendance | Salary | Advances, on the same pos_staff tables. Salary payments and advances also show in Money.

class StaffApi {
  StaffApi({http.Client? client, String? baseUrl, String? Function()? accessToken, RpcClient? rpc})
      : _rpc = rpc ?? RpcClient(client: client, baseUrl: baseUrl, accessToken: accessToken);
  final RpcClient _rpc;
  static final _rand = Random.secure();
  static String newKey() => 'st-${List.generate(16, (_) => _rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  Future<Map<String, dynamic>> _call(String fn, Map<String, Object?> args, {String? key}) async {
    try {
      return await _rpc.callMap(fn, {...args}..removeWhere((_, v) => v == null), key);
    } on RpcException catch (e) {
      throw PartnerApiException(e.status, e.message);
    }
  }

  Future<Map<String, dynamic>> home() => _call('staff_home', {});
  Future<Map<String, dynamic>> save(Map<String, Object?> body) => _call('staff_save', body);
  Future<Map<String, dynamic>> attendance(String date) => _call('staff_attendance', {'date': date});
  Future<Map<String, dynamic>> mark(String date, List<Map<String, Object?>> rows) => _call('staff_attendance_save', {'date': date, 'rows': rows});
  Future<Map<String, dynamic>> salary(int year, int month) => _call('staff_salary', {'year': year, 'month': month});
  Future<Map<String, dynamic>> generate(int year, int month) => _call('staff_salary_generate', {'year': year, 'month': month});
  Future<Map<String, dynamic>> adjust(String id, {num bonus = 0, num penalty = 0}) => _call('staff_salary_adjust', {'id': id, 'bonus': bonus, 'penalty': penalty});
  Future<Map<String, dynamic>> pay(String id, {num? amount, required String account, required String key}) =>
      _call('staff_salary_pay', {'id': id, 'amount': amount, 'account': account}, key: key);
  Future<Map<String, dynamic>> advances() => _call('staff_advances', {});
  Future<Map<String, dynamic>> giveAdvance(Map<String, Object?> body, {required String key}) => _call('staff_advance_give', body, key: key);
}

String _rs(num? minor) {
  final v = (minor ?? 0).round();
  final abs = v.abs(), rupees = abs ~/ 100, paise = abs % 100;
  final d = rupees.toString();
  final g = d.length <= 3 ? d : '${d.substring(0, d.length - 3).replaceAllMapped(RegExp(r'(\d)(?=(\d\d)+$)'), (m) => '${m[1]},')},${d.substring(d.length - 3)}';
  return '${v < 0 ? '-' : ''}₹$g${paise == 0 ? '' : '.${paise.toString().padLeft(2, '0')}'}';
}

String _iso(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
const _months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const _green = Color(0xFF15803D), _red = Color(0xFFC62828), _amber = Color(0xFFB45309);
const _per = {'monthly': 'month', 'daily': 'day', 'hourly': 'hour'};
const _marks = [('present', 'P', 'Present'), ('half_day', '½', 'Half day'), ('leave', 'L', 'Leave'), ('absent', 'A', 'Absent')];
Color _markColor(String? s) => switch (s) { 'present' => _green, 'half_day' => _amber, 'leave' => const Color(0xFF2563EB), 'absent' => _red, _ => kMuted };

InputDecoration _dec(String label, {String? prefix, String? hint}) => InputDecoration(
      isDense: true,
      labelText: tr(label),
      hintText: hint,
      prefixText: prefix,
      filled: true,
      fillColor: kBg,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kLine)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kLine)),
    );

String _err(Object e, String fallback) => e is PartnerApiException ? e.message : tr(fallback);

/// Team → Staff: the tiles, then Staff | Attendance | Salary | Advances. App logins and roles are one tap away ([onAppUsers]).
class StaffScreen extends StatefulWidget {
  const StaffScreen({super.key, this.api, this.onAppUsers, this.today});
  final StaffApi? api;
  final VoidCallback? onAppUsers;
  final DateTime? today;
  @override
  State<StaffScreen> createState() => _StaffScreenState();
}

class _StaffScreenState extends State<StaffScreen> {
  late final StaffApi _api = widget.api ?? StaffApi();
  Map<String, dynamic>? _home;
  String? _error;
  String _part = 'staff';

  DateTime get _today {
    final t = widget.today ?? DateTime.now();
    return DateTime(t.year, t.month, t.day);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final h = await _api.home();
      if (mounted) {
        setState(() {
          _home = h;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = _err(e, 'Could not load staff. Check your connection.'));
    }
  }

  Future<void> _edit([Map<String, dynamic>? s]) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _StaffForm(api: _api, staff: s, today: _today),
    );
    if (saved == true && mounted) _load();
  }

  Widget _tile(String label, String value, IconData icon, {Color? color, String? key}) => Container(
        key: key == null ? null : ValueKey(key),
        width: 132,
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: kLine)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 14, color: color ?? kMuted),
            const SizedBox(width: 5),
            Expanded(child: Text(tr(label), maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(11, 600, color: kMuted))),
          ]),
          const SizedBox(height: 6),
          FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(value, style: inter(18, 800, color: color ?? kInk))),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final h = _home;
    final m = (h?['month'] as Map?) ?? const {};
    final payable = m['payable_minor'] as num? ?? 0, paid = m['paid_minor'] as num? ?? 0;
    return Scaffold(
      backgroundColor: kBg,
      floatingActionButton: _part == 'staff' && h != null
          ? FloatingActionButton.extended(
              key: const ValueKey('staff-add'),
              onPressed: () => _edit(),
              backgroundColor: const Color(0xFF7ED321),
              icon: const Icon(LucideIcons.userPlus, color: kInk),
              label: Text(tr('Add staff'), style: inter(15, 700)),
            )
          : null,
      body: Column(children: [
        AppHeader(
          title: tr('Staff'),
          onBack: Navigator.of(context).canPop() ? () => Navigator.of(context).maybePop() : null,
          trailing: widget.onAppUsers == null
              ? null
              : TextButton(key: const ValueKey('staff-app-users'), onPressed: widget.onAppUsers, child: Text(tr('App users'), style: inter(13, 700, color: kLink))),
        ),
        Expanded(
          child: _error != null && h == null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center, style: inter(14, 500, color: kMuted))))
              : h == null
                  ? const Center(child: CircularProgressIndicator())
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(key: const ValueKey('staff-screen'), padding: const EdgeInsets.fromLTRB(14, 12, 14, 96), children: [
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(children: [
                            _tile('Staff', '${h['active']}', LucideIcons.users, key: 'tile-staff'),
                            _tile('Present today', '${h['present_today']}', LucideIcons.userCheck, color: _green, key: 'tile-present'),
                            _tile('Absent today', '${h['absent_today']}', LucideIcons.userX, color: _red, key: 'tile-absent'),
                            _tile('${_months[(m['month'] as int? ?? 1) - 1].substring(0, 3)} payable', _rs(payable), LucideIcons.indianRupee, key: 'tile-payable'),
                            _tile('Paid', _rs(paid), LucideIcons.circleCheck, color: _green, key: 'tile-paid'),
                            _tile('Pending', _rs(max(payable - paid, 0)), LucideIcons.clock, color: _amber, key: 'tile-pending'),
                          ]),
                        ),
                        const SizedBox(height: 14),
                        Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(color: const Color(0xFFE9EAEE), borderRadius: BorderRadius.circular(14)),
                          child: Row(children: [
                            for (final (id, label) in const [('staff', 'Staff'), ('attendance', 'Attendance'), ('salary', 'Salary'), ('advances', 'Advances')])
                              Expanded(
                                child: GestureDetector(
                                  key: ValueKey('staff-part-$id'),
                                  onTap: () => setState(() => _part = id),
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 150),
                                    padding: const EdgeInsets.symmetric(vertical: 10),
                                    decoration: BoxDecoration(color: _part == id ? Colors.white : Colors.transparent, borderRadius: BorderRadius.circular(10)),
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Text(tr(label), style: inter(13, 700, color: _part == id ? kInk : kMuted)),
                                    ),
                                  ),
                                ),
                              ),
                          ]),
                        ),
                        const SizedBox(height: 12),
                        switch (_part) {
                          'attendance' => _Attendance(key: const ValueKey('att'), api: _api, today: _today, onChanged: _load),
                          'salary' => _Salary(key: const ValueKey('sal'), api: _api, today: _today, onChanged: _load),
                          'advances' => _Advances(key: const ValueKey('adv'), api: _api, staff: (h['staff'] as List? ?? const []).cast<Map>(), today: _today),
                          _ => _StaffList(staff: (h['staff'] as List? ?? const []).cast<Map>(), onOpen: _edit),
                        },
                      ]),
                    ),
        ),
      ]),
    );
  }
}

// ------------------------------------------------------------------------------------------------------------------- staff list
class _StaffList extends StatelessWidget {
  const _StaffList({required this.staff, required this.onOpen});
  final List<Map> staff;
  final void Function(Map<String, dynamic> s) onOpen;
  @override
  Widget build(BuildContext context) {
    if (staff.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(28),
        child: Column(children: [
          const Icon(LucideIcons.users, size: 36, color: kMuted),
          const SizedBox(height: 8),
          Text(tr('No staff yet'), style: inter(16, 700)),
          Text(tr('Add the people who work in your store.'), textAlign: TextAlign.center, style: inter(13, 400, color: kMuted)),
        ]),
      );
    }
    return Column(children: [
      for (final s in staff)
        Container(
          key: ValueKey('staff-${s['id']}'),
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: kLine)),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => onOpen(s.cast<String, dynamic>()),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: const Color(0xFFEAF5EC),
                    child: Text('${s['name']}'.trim().split(RegExp(r'\s+')).take(2).map((w) => w.isEmpty ? '' : w[0].toUpperCase()).join(), style: inter(14, 800, color: _green)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${s['name']}', style: inter(15, 700, color: s['status'] == 'active' ? kInk : kMuted)),
                      Text([if ('${s['role'] ?? ''}'.isNotEmpty) '${s['role']}', if ('${s['mobile'] ?? ''}'.isNotEmpty) '${s['mobile']}', if (s['status'] != 'active') tr('Inactive')].join(' · '),
                          style: inter(12, 400, color: kMuted)),
                    ]),
                  ),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text('${_rs(s['pay_minor'] as num?)}/${tr(_per[s['salary_type']] ?? 'month')}', style: inter(13.5, 700)),
                    if (s['today'] != null)
                      Text(tr(_marks.where((m) => m.$1 == s['today']).map((m) => m.$3).firstOrNull ?? '${s['today']}'), style: inter(11.5, 700, color: _markColor('${s['today']}'))),
                  ]),
                ]),
              ),
            ),
          ),
        ),
    ]);
  }
}

class _StaffForm extends StatefulWidget {
  const _StaffForm({required this.api, this.staff, required this.today});
  final StaffApi api;
  final Map<String, dynamic>? staff;
  final DateTime today;
  @override
  State<_StaffForm> createState() => _StaffFormState();
}

class _StaffFormState extends State<_StaffForm> {
  Map<String, dynamic> get s => widget.staff ?? const {};
  late final _c = {
    for (final k in ['name', 'mobile', 'role', 'email', 'emergency_contact', 'department', 'address', 'bank_name', 'account_number', 'ifsc', 'upi_id'])
      k: TextEditingController(text: '${s[k] ?? ''}'),
  };
  late final _pay = TextEditingController(text: s['pay_minor'] == null ? '' : ((s['pay_minor'] as num) / 100).toStringAsFixed(2).replaceAll('.00', ''));
  late final _hours = TextEditingController(text: '${s['working_hours'] ?? 8}'.replaceAll('.00', '').replaceAll('.0', ''));
  late String _type = '${s['salary_type'] ?? 'monthly'}';
  late bool _active = (s['status'] ?? 'active') == 'active';
  late DateTime _join = DateTime.tryParse('${s['joining_date'] ?? ''}') ?? widget.today;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [..._c.values, _pay, _hours]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_c['name']!.text.trim().isEmpty) return showToast(context, tr('Enter the name.'));
    setState(() => _busy = true);
    try {
      await widget.api.save({
        'id': s['id'],
        for (final e in _c.entries) e.key: e.value.text.trim(),
        'salary_type': _type,
        'pay': num.tryParse(_pay.text.trim()) ?? 0,
        'working_hours': num.tryParse(_hours.text.trim()) ?? 8,
        'joining_date': _iso(_join),
        if (s['id'] != null) 'status': _active ? 'active' : 'inactive',
      });
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showToast(context, _err(e, 'Could not save. Try again.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _f(String k, String label, {TextInputType? type, String? hint}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(key: ValueKey('staff-f-$k'), controller: _c[k], keyboardType: type, style: inter(14.5, 600), decoration: _dec(label, hint: hint)),
      );

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(18, 16, 18, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(key: const ValueKey('staff-form'), mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(tr(s['id'] == null ? 'Add staff' : 'Edit staff'), style: inter(19, 800)),
            const SizedBox(height: 12),
            _f('name', 'Name *'),
            Row(children: [
              Expanded(child: _f('mobile', 'Mobile', type: TextInputType.phone)),
              const SizedBox(width: 8),
              Expanded(child: _f('role', 'Role', hint: tr('Cashier, helper…'))),
            ]),
            InkWell(
              key: const ValueKey('staff-join'),
              onTap: () async {
                final d = await showDatePicker(context: context, initialDate: _join, firstDate: DateTime(2000), lastDate: widget.today);
                if (d != null) setState(() => _join = d);
              },
              child: InputDecorator(decoration: _dec('Joining date'), child: Text('${_join.day} ${_months[_join.month - 1].substring(0, 3)} ${_join.year}', style: inter(14.5, 600))),
            ),
            const SizedBox(height: 12),
            Text(tr('Pay'), style: inter(12.5, 700, color: kMuted)),
            const SizedBox(height: 6),
            SegmentedButton<String>(
              key: const ValueKey('staff-type'),
              showSelectedIcon: false,
              segments: [for (final t in const ['monthly', 'daily', 'hourly']) ButtonSegment(value: t, label: Text(tr('${t[0].toUpperCase()}${t.substring(1)}'), style: inter(13, 700)))],
              selected: {_type},
              onSelectionChanged: (v) => setState(() => _type = v.first),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                flex: 3,
                child: TextField(
                  key: const ValueKey('staff-pay'),
                  controller: _pay,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                  style: inter(16, 700),
                  decoration: _dec('${tr('Pay per')} ${tr(_per[_type]!)}', prefix: '₹ '),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: TextField(
                  key: const ValueKey('staff-hours'),
                  controller: _hours,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                  style: inter(16, 700),
                  decoration: _dec('Hours / day'),
                ),
              ),
            ]),
            if (s['id'] != null)
              SwitchListTile(
                key: const ValueKey('staff-active'),
                contentPadding: EdgeInsets.zero,
                value: _active,
                onChanged: (v) => setState(() => _active = v),
                title: Text(tr('Working here'), style: inter(14.5, 600)),
                subtitle: Text(tr('Turn off when someone leaves. Their records stay.'), style: inter(12, 400, color: kMuted)),
              ),
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                key: const ValueKey('staff-more'),
                tilePadding: EdgeInsets.zero,
                title: Text(tr('More details'), style: inter(14.5, 700)),
                subtitle: Text(tr('Email, emergency contact, address, bank, UPI'), style: inter(12, 400, color: kMuted)),
                children: [
                  _f('email', 'Email', type: TextInputType.emailAddress),
                  _f('emergency_contact', 'Emergency contact', type: TextInputType.phone),
                  _f('department', 'Department'),
                  _f('address', 'Address'),
                  _f('bank_name', 'Bank name'),
                  Row(children: [
                    Expanded(child: _f('account_number', 'Account number', type: TextInputType.number)),
                    const SizedBox(width: 8),
                    Expanded(child: _f('ifsc', 'IFSC')),
                  ]),
                  _f('upi_id', 'UPI ID', hint: 'name@bank'),
                ],
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              key: const ValueKey('staff-save'),
              onPressed: _busy ? null : _save,
              style: FilledButton.styleFrom(backgroundColor: kPrimary, padding: const EdgeInsets.symmetric(vertical: 15), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
              child: Text(_busy ? '…' : tr(s['id'] == null ? 'Add staff' : 'Save'), style: inter(15.5, 700, color: Colors.white)),
            ),
          ]),
        ),
      );
}

// ------------------------------------------------------------------------------------------------------------------- attendance
class _Attendance extends StatefulWidget {
  const _Attendance({super.key, required this.api, required this.today, required this.onChanged});
  final StaffApi api;
  final DateTime today;
  final VoidCallback onChanged;
  @override
  State<_Attendance> createState() => _AttendanceState();
}

class _AttendanceState extends State<_Attendance> {
  late DateTime _day = widget.today;
  List<Map<String, dynamic>>? _rows;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _take(Map<String, dynamic> r) => setState(() {
        _rows = (r['rows'] as List? ?? const []).cast<Map>().map((e) => e.cast<String, dynamic>()).toList();
        _error = null;
      });

  Future<void> _load() async {
    try {
      final r = await widget.api.attendance(_iso(_day));
      if (mounted) _take(r);
    } catch (e) {
      if (mounted) setState(() => _error = _err(e, 'Could not load attendance.'));
    }
  }

  Future<void> _mark(List<Map<String, Object?>> rows) async {
    try {
      final r = await widget.api.mark(_iso(_day), rows);
      if (!mounted) return;
      _take(r);
      if (_day == widget.today) widget.onChanged();
    } catch (e) {
      if (mounted) showToast(context, _err(e, 'Could not save attendance.'));
    }
  }

  Future<void> _ot(Map<String, dynamic> r) async {
    final c = TextEditingController(text: (r['ot_hours'] as num? ?? 0) == 0 ? '' : '${r['ot_hours']}');
    final v = await showDialog<num>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${tr('Overtime')} · ${r['name']}', style: inter(17, 700)),
        content: TextField(key: const ValueKey('ot-hours'), controller: c, autofocus: true, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: tr('Extra hours'))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Cancel'), style: inter(14, 600))),
          TextButton(key: const ValueKey('ot-save'), onPressed: () => Navigator.pop(ctx, num.tryParse(c.text.trim()) ?? 0), child: Text(tr('Save'), style: inter(14, 700))),
        ],
      ),
    );
    if (v == null) return;
    await _mark([{'staff_id': r['staff_id'], 'status': r['status'] ?? 'present', 'ot_hours': v}]);
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final isToday = _day == widget.today;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        IconButton(key: const ValueKey('att-prev'), onPressed: () { setState(() => _day = _day.subtract(const Duration(days: 1))); _load(); }, icon: const Icon(LucideIcons.chevronLeft)),
        Expanded(
          child: InkWell(
            onTap: () async {
              final d = await showDatePicker(context: context, initialDate: _day, firstDate: DateTime(2020), lastDate: widget.today);
              if (d != null) {
                setState(() => _day = d);
                _load();
              }
            },
            child: Text(isToday ? tr('Today') : '${_day.day} ${_months[_day.month - 1].substring(0, 3)} ${_day.year}', key: const ValueKey('att-day'), textAlign: TextAlign.center, style: inter(16, 800)),
          ),
        ),
        IconButton(key: const ValueKey('att-next'), onPressed: isToday ? null : () { setState(() => _day = _day.add(const Duration(days: 1))); _load(); }, icon: const Icon(LucideIcons.chevronRight)),
      ]),
      if (rows != null && rows.isNotEmpty)
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            key: const ValueKey('att-all-present'),
            onPressed: () => _mark([for (final r in rows) if (r['status'] == null) {'staff_id': r['staff_id'], 'status': 'present'}].ifEmptyAll(rows)),
            icon: const Icon(LucideIcons.checkCheck, size: 17, color: _green),
            label: Text(tr('Mark all present'), style: inter(13.5, 700, color: _green)),
          ),
        ),
      if (_error != null && rows == null)
        Text(_error!, style: inter(13.5, 500, color: kMuted))
      else if (rows == null)
        const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()))
      else if (rows.isEmpty)
        Padding(padding: const EdgeInsets.all(20), child: Text(tr('No staff working on this day.'), textAlign: TextAlign.center, style: inter(13.5, 500, color: kMuted)))
      else
        for (final r in rows)
          Container(
            key: ValueKey('att-${r['staff_id']}'),
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: kLine)),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${r['name']}', style: inter(14.5, 700)),
                  InkWell(
                    key: ValueKey('att-ot-${r['staff_id']}'),
                    onTap: () => _ot(r),
                    child: Text((r['ot_hours'] as num? ?? 0) > 0 ? '${tr('OT')} ${r['ot_hours']} h' : tr('+ OT'), style: inter(12, 600, color: kLink)),
                  ),
                ]),
              ),
              for (final (id, short, word) in _marks)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Tooltip(
                    message: tr(word),
                    child: InkWell(
                      key: ValueKey('att-${r['staff_id']}-$id'),
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => _mark([{'staff_id': r['staff_id'], 'status': r['status'] == id ? null : id, 'ot_hours': r['ot_hours']}]),
                      child: Container(
                        width: 38,
                        height: 38,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: r['status'] == id ? _markColor(id) : Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: r['status'] == id ? _markColor(id) : kLine),
                        ),
                        child: Text(short, style: inter(14, 800, color: r['status'] == id ? Colors.white : _markColor(id))),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
      if (rows != null && rows.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(tr('P present · ½ half day · L paid leave · A absent (unpaid). Tap again to clear.'), style: inter(11.5, 400, color: kMuted)),
        ),
    ]);
  }
}

extension on List<Map<String, Object?>> {
  /// Mark all present with everyone already marked: mark them all present again.
  List<Map<String, Object?>> ifEmptyAll(List<Map<String, dynamic>> rows) => isNotEmpty ? this : [for (final r in rows) {'staff_id': r['staff_id'], 'status': 'present'}];
}

// ------------------------------------------------------------------------------------------------------------------- salary
class _Salary extends StatefulWidget {
  const _Salary({super.key, required this.api, required this.today, required this.onChanged});
  final StaffApi api;
  final DateTime today;
  final VoidCallback onChanged;
  @override
  State<_Salary> createState() => _SalaryState();
}

class _SalaryState extends State<_Salary> {
  late int _y = widget.today.year, _m = widget.today.month;
  List<Map<String, dynamic>>? _rows;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _take(Map<String, dynamic> r) => setState(() {
        _rows = (r['rows'] as List? ?? const []).cast<Map>().map((e) => e.cast<String, dynamic>()).toList();
        _error = null;
      });

  Future<void> _load() async {
    try {
      final r = await widget.api.salary(_y, _m);
      if (mounted) _take(r);
    } catch (e) {
      if (mounted) setState(() => _error = _err(e, 'Could not load salaries.'));
    }
  }

  void _step(int by) {
    final d = DateTime(_y, _m + by);
    if (d.isAfter(DateTime(widget.today.year, widget.today.month))) return;
    setState(() {
      _y = d.year;
      _m = d.month;
      _rows = null;
    });
    _load();
  }

  Future<void> _generate() async {
    setState(() => _busy = true);
    try {
      final r = await widget.api.generate(_y, _m);
      if (!mounted) return;
      _take(r);
      widget.onChanged();
    } catch (e) {
      if (mounted) showToast(context, _err(e, 'Could not work out salaries.'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pay(Map<String, dynamic> r) async {
    final amount = TextEditingController(text: ((r['pending_minor'] as num? ?? 0) / 100).toStringAsFixed(2).replaceAll('.00', ''));
    var account = 'cash';
    final key = StaffApi.newKey();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => Padding(
          padding: EdgeInsets.fromLTRB(18, 16, 18, 16 + MediaQuery.viewInsetsOf(ctx).bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('${tr('Pay')} ${r['name']}', style: inter(19, 800)),
            Text('${_months[_m - 1]} $_y · ${tr('due')} ${_rs(r['pending_minor'] as num?)}', style: inter(13, 500, color: kMuted)),
            const SizedBox(height: 12),
            TextField(key: const ValueKey('pay-amount'), controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), style: inter(18, 700), decoration: _dec('Amount', prefix: '₹ ')),
            const SizedBox(height: 10),
            Text(tr('Paid from'), style: inter(12.5, 700, color: kMuted)),
            Wrap(spacing: 6, children: [
              for (final (id, label) in const [('cash', 'Cash drawer'), ('upi', 'UPI'), ('bank', 'Bank')])
                ChoiceChip(key: ValueKey('pay-from-$id'), label: Text(tr(label), style: inter(12.5, 600)), selected: account == id, onSelected: (_) => set(() => account = id)),
            ]),
            const SizedBox(height: 14),
            FilledButton(
              key: const ValueKey('pay-confirm'),
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: kPrimary, padding: const EdgeInsets.symmetric(vertical: 15), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
              child: Text(tr('Pay salary'), style: inter(15.5, 700, color: Colors.white)),
            ),
          ]),
        ),
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final res = await widget.api.pay('${r['id']}', amount: num.tryParse(amount.text.trim()), account: account, key: key);
      if (!mounted) return;
      _take(res);
      showToast(context, tr('Paid. It is in Money as Salary / wages.'));
      widget.onChanged();
    } catch (e) {
      if (mounted) showToast(context, _err(e, 'Could not pay. Try again.'));
    }
  }

  Future<void> _adjust(Map<String, dynamic> r) async {
    final bonus = TextEditingController(text: (r['bonus_minor'] as num? ?? 0) == 0 ? '' : '${(r['bonus_minor'] as num) / 100}');
    final penalty = TextEditingController(text: (r['penalty_minor'] as num? ?? 0) == 0 ? '' : '${(r['penalty_minor'] as num) / 100}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${tr('Bonus or penalty')} · ${r['name']}', style: inter(17, 700)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(key: const ValueKey('adj-bonus'), controller: bonus, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: tr('Bonus'), prefixText: '₹ ')),
          TextField(key: const ValueKey('adj-penalty'), controller: penalty, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: tr('Penalty'), prefixText: '₹ ')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Cancel'), style: inter(14, 600))),
          TextButton(key: const ValueKey('adj-save'), onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Save'), style: inter(14, 700))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final res = await widget.api.adjust('${r['id']}', bonus: num.tryParse(bonus.text.trim()) ?? 0, penalty: num.tryParse(penalty.text.trim()) ?? 0);
      if (mounted) _take(res);
      widget.onChanged();
    } catch (e) {
      if (mounted) showToast(context, _err(e, 'Could not save. Try again.'));
    }
  }

  void _csv() {
    final rows = _rows ?? const [];
    String q(Object? v) => '"${'${v ?? ''}'.replaceAll('"', '""')}"';
    String r2(Object? m) => ((m as num? ?? 0) / 100).toStringAsFixed(2);
    final text = [
      'Staff,Basic,OT,Bonus,Advance,Penalty,Net,Paid,Pending,Status',
      for (final r in rows) [r['name'], r2(r['basic_minor']), r2(r['ot_minor']), r2(r['bonus_minor']), r2(r['advance_minor']), r2(r['penalty_minor']), r2(r['net_minor']), r2(r['paid_minor']), r2(r['pending_minor']), r['status']].map(q).join(','),
    ].join('\n');
    Clipboard.setData(ClipboardData(text: text));
    showToast(context, tr('Salary sheet copied as CSV. Paste into Excel or Sheets.'));
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final current = _y == widget.today.year && _m == widget.today.month;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        IconButton(key: const ValueKey('sal-prev'), onPressed: () => _step(-1), icon: const Icon(LucideIcons.chevronLeft)),
        Expanded(child: Text('${_months[_m - 1]} $_y', key: const ValueKey('sal-month'), textAlign: TextAlign.center, style: inter(16, 800))),
        IconButton(key: const ValueKey('sal-next'), onPressed: current ? null : () => _step(1), icon: const Icon(LucideIcons.chevronRight)),
      ]),
      Row(children: [
        Expanded(
          child: FilledButton.icon(
            key: const ValueKey('sal-generate'),
            onPressed: _busy ? null : _generate,
            icon: const Icon(LucideIcons.calculator, size: 17, color: kInk),
            label: Text(tr(rows != null && rows.isNotEmpty ? 'Work out again' : 'Generate salaries'), style: inter(14, 700)),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF7ED321), padding: const EdgeInsets.symmetric(vertical: 13), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.outlined(key: const ValueKey('sal-csv'), tooltip: tr('Copy as CSV'), onPressed: rows == null || rows.isEmpty ? null : _csv, icon: const Icon(LucideIcons.download, size: 18)),
      ]),
      const SizedBox(height: 4),
      Text(tr('From attendance: absent days are unpaid, half days count half. Paid salaries stay as they are.'), style: inter(11.5, 400, color: kMuted)),
      const SizedBox(height: 10),
      if (_error != null && rows == null)
        Text(_error!, style: inter(13.5, 500, color: kMuted))
      else if (rows == null)
        const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()))
      else if (rows.isEmpty)
        Padding(padding: const EdgeInsets.all(20), child: Text(tr('No salaries for this month yet. Tap Generate salaries.'), textAlign: TextAlign.center, style: inter(13.5, 500, color: kMuted)))
      else
        for (final r in rows)
          Container(
            key: ValueKey('sal-${r['staff_id']}'),
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: kLine)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(child: Text('${r['name']}', style: inter(15, 700))),
                Text(_rs(r['net_minor'] as num?), style: inter(16, 800)),
              ]),
              const SizedBox(height: 2),
              Text(
                [
                  '${tr('Basic')} ${_rs(r['basic_minor'] as num?)}',
                  if ((r['ot_minor'] as num? ?? 0) > 0) '${tr('OT')} ${_rs(r['ot_minor'] as num?)}',
                  if ((r['bonus_minor'] as num? ?? 0) > 0) '${tr('Bonus')} ${_rs(r['bonus_minor'] as num?)}',
                  if ((r['advance_minor'] as num? ?? 0) > 0) '${tr('Advance')} −${_rs(r['advance_minor'] as num?)}',
                  if ((r['penalty_minor'] as num? ?? 0) > 0) '${tr('Penalty')} −${_rs(r['penalty_minor'] as num?)}',
                ].join(' · '),
                style: inter(12, 400, color: kMuted),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: Text(
                    r['status'] == 'paid' ? tr('Paid') : r['status'] == 'partial' ? '${tr('Paid')} ${_rs(r['paid_minor'] as num?)} · ${tr('due')} ${_rs(r['pending_minor'] as num?)}' : tr('Not paid'),
                    maxLines: 2,
                    style: inter(12.5, 700, color: r['status'] == 'paid' ? _green : _amber),
                  ),
                ),
                if (r['status'] != 'paid') ...[
                  IconButton(
                    key: ValueKey('sal-adjust-${r['staff_id']}'),
                    tooltip: tr('Bonus or penalty'),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _adjust(r),
                    icon: const Icon(LucideIcons.slidersHorizontal, size: 18, color: kLink),
                  ),
                  FilledButton(
                    key: ValueKey('sal-pay-${r['staff_id']}'),
                    onPressed: () => _pay(r),
                    style: FilledButton.styleFrom(backgroundColor: kPrimary, visualDensity: VisualDensity.compact, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                    child: Text(tr('Pay'), style: inter(13, 700, color: Colors.white)),
                  ),
                ],
              ]),
            ]),
          ),
    ]);
  }
}

// ------------------------------------------------------------------------------------------------------------------- advances
class _Advances extends StatefulWidget {
  const _Advances({super.key, required this.api, required this.staff, required this.today});
  final StaffApi api;
  final List<Map> staff;
  final DateTime today;
  @override
  State<_Advances> createState() => _AdvancesState();
}

class _AdvancesState extends State<_Advances> {
  List<Map<String, dynamic>>? _rows;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _take(Map<String, dynamic> r) => setState(() {
        _rows = (r['advances'] as List? ?? const []).cast<Map>().map((e) => e.cast<String, dynamic>()).toList();
        _error = null;
      });

  Future<void> _load() async {
    try {
      final r = await widget.api.advances();
      if (mounted) _take(r);
    } catch (e) {
      if (mounted) setState(() => _error = _err(e, 'Could not load advances.'));
    }
  }

  Future<void> _give() async {
    final active = widget.staff.where((s) => s['status'] == 'active').toList();
    if (active.isEmpty) return showToast(context, tr('Add staff first.'));
    String? who = '${active.first['id']}';
    var mode = 'cash';
    final thisMonth = DateTime(widget.today.year, widget.today.month), next = DateTime(widget.today.year, widget.today.month + 1);
    var back = thisMonth;
    final amount = TextEditingController(), reason = TextEditingController();
    final key = StaffApi.newKey();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => Padding(
          padding: EdgeInsets.fromLTRB(18, 16, 18, 16 + MediaQuery.viewInsetsOf(ctx).bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(tr('Give advance'), style: inter(19, 800)),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const ValueKey('adv-who'),
              initialValue: who,
              isExpanded: true,
              decoration: _dec('To'),
              items: [for (final s in active) DropdownMenuItem(value: '${s['id']}', child: Text('${s['name']}', style: inter(14.5, 600)))],
              onChanged: (v) => set(() => who = v),
            ),
            const SizedBox(height: 10),
            TextField(key: const ValueKey('adv-amount'), controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), style: inter(18, 700), decoration: _dec('Amount', prefix: '₹ ')),
            const SizedBox(height: 10),
            Text(tr('Paid from'), style: inter(12.5, 700, color: kMuted)),
            Wrap(spacing: 6, children: [
              for (final (id, label) in const [('cash', 'Cash drawer'), ('upi', 'UPI'), ('bank', 'Bank')])
                ChoiceChip(key: ValueKey('adv-from-$id'), label: Text(tr(label), style: inter(12.5, 600)), selected: mode == id, onSelected: (_) => set(() => mode = id)),
            ]),
            const SizedBox(height: 8),
            Text(tr('Take back from'), style: inter(12.5, 700, color: kMuted)),
            Wrap(spacing: 6, children: [
              for (final d in [thisMonth, next])
                ChoiceChip(label: Text('${_months[d.month - 1]} ${tr('salary')}', style: inter(12.5, 600)), selected: back == d, onSelected: (_) => set(() => back = d)),
            ]),
            const SizedBox(height: 10),
            TextField(controller: reason, style: inter(14, 500), decoration: _dec('Reason (optional)')),
            const SizedBox(height: 14),
            FilledButton(
              key: const ValueKey('adv-confirm'),
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: kPrimary, padding: const EdgeInsets.symmetric(vertical: 15), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
              child: Text(tr('Give advance'), style: inter(15.5, 700, color: Colors.white)),
            ),
          ]),
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final amt = num.tryParse(amount.text.trim());
    if (amt == null || amt <= 0) return showToast(context, tr('Enter the amount.'));
    try {
      final r = await widget.api.giveAdvance({'staff_id': who, 'amount': amt, 'mode': mode, 'deduct_month': back.month, 'deduct_year': back.year, 'reason': reason.text.trim()}, key: key);
      if (!mounted) return;
      _take(r);
      showToast(context, tr('Advance given. It is in Money and comes off the salary.'));
    } catch (e) {
      if (mounted) showToast(context, _err(e, 'Could not save. Try again.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      FilledButton.icon(
        key: const ValueKey('adv-give'),
        onPressed: _give,
        icon: const Icon(LucideIcons.handCoins, size: 18, color: kInk),
        label: Text(tr('Give advance'), style: inter(14.5, 700)),
        style: FilledButton.styleFrom(backgroundColor: const Color(0xFF7ED321), padding: const EdgeInsets.symmetric(vertical: 13), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
      ),
      const SizedBox(height: 10),
      if (_error != null && rows == null)
        Text(_error!, style: inter(13.5, 500, color: kMuted))
      else if (rows == null)
        const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()))
      else if (rows.isEmpty)
        Padding(padding: const EdgeInsets.all(20), child: Text(tr('No advances given.'), textAlign: TextAlign.center, style: inter(13.5, 500, color: kMuted)))
      else
        for (final a in rows)
          Container(
            key: ValueKey('adv-${a['id']}'),
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: kLine)),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${a['name']}', style: inter(14.5, 700)),
                  Text(
                    [
                      '${a['date']}'.length >= 10 ? '${int.parse('${a['date']}'.substring(8, 10))} ${_months[int.parse('${a['date']}'.substring(5, 7)) - 1].substring(0, 3)}' : '',
                      '${a['mode']}'.toUpperCase(),
                      '${tr('from')} ${_months[(a['deduct_month'] as int) - 1].substring(0, 3)} ${tr('salary')}',
                      if ('${a['reason'] ?? ''}'.isNotEmpty) '${a['reason']}',
                    ].join(' · '),
                    style: inter(12, 400, color: kMuted),
                  ),
                ]),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(_rs(a['amount_minor'] as num?), style: inter(15, 800)),
                Text(tr(a['status'] == 'deducted' ? 'Taken back' : 'To take back'), style: inter(11.5, 700, color: a['status'] == 'deducted' ? _green : _amber)),
              ]),
            ]),
          ),
    ]);
  }
}
