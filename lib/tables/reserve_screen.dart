import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_api.dart';
import '../inventory/inventory_widgets.dart';
import '../ui/theme.dart';
import 'table_widgets.dart';
import 'tables_api.dart';

/// Figma "Reserve Table T4" (screen-3-reserve-form): guest name, phone, party size 2/4/6/8, date, time, special notes, Confirm Reservation, Cancel.
/// The server checks capacity, a clashing booking, the time and the phone; its sentence is shown as it comes.
class ReserveScreen extends StatefulWidget {
  const ReserveScreen({super.key, required this.env, required this.table, this.now});
  final TablesEnv env;
  final Facts table;

  /// The store's wall clock (the phone's own only when the server did not send one; also the clock for tests).
  final DateTime Function()? now;
  @override
  State<ReserveScreen> createState() => _ReserveScreenState();
}

class _ReserveScreenState extends State<ReserveScreen> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _notes = TextEditingController();
  int _pax = 4;
  late DateTime _date;
  late TimeOfDay _time;
  bool _busy = false;
  String? _error;
  String? _key; // one key per intent: a retry of the same form sends the same key

  DateTime get _now => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    final n = _now;
    _date = DateTime(n.year, n.month, n.day);
    final up = n.add(const Duration(hours: 1));
    _time = TimeOfDay(hour: up.hour, minute: up.minute >= 30 ? 30 : 0);
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _notes.dispose();
    super.dispose();
  }

  DateTime get _at => DateTime(_date.year, _date.month, _date.day, _time.hour, _time.minute);

  String get _dateLabel {
    final n = _now;
    final today = DateTime(n.year, n.month, n.day);
    final d = '${['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][_date.month - 1]} ${_date.day}';
    if (_date == today) return 'Today, $d';
    if (_date == today.add(const Duration(days: 1))) return 'Tomorrow, $d';
    return d;
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _key ??= TablesApi.newKey();
      await widget.env.api.reserve(
        tableId: widget.table.s('id'),
        guestName: _name.text,
        phone: _phone.text,
        guests: _pax,
        localDate: '${_date.year.toString().padLeft(4, '0')}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}',
        localTime: '${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}',
        notes: _notes.text,
        key: _key!,
      );
      if (!mounted) return;
      showToast(context, 'Table ${widget.table.s('label')} reserved for ${clock12(_at)}.');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = sayError(e);
        if (e is TablesApiException) _key = null; // the server refused: a changed form is a new intent. A lost connection keeps the key so the retry cannot double.
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.table.s('label');
    Widget field(IconData icon, TextEditingController c, String hint, {bool phone = false}) => InvInput(controller: c, hint: hint, prefixIcon: icon, onChanged: (_) => setState(() {}));
    return TablesPage(
      env: widget.env,
      title: 'Reserve Table $label',
      back: true,
      nav: false,
      children: [
        const InvLabel('GUEST NAME'),
        field(LucideIcons.user, _name, 'Guest name'),
        const InvLabel('PHONE NUMBER'),
        InvInput(controller: _phone, hint: 'Mobile number', mobile: true, prefixIcon: LucideIcons.phone, onChanged: (_) => setState(() {})),
        const InvLabel('PARTY SIZE'),
        Row(children: [
          for (final n in const [2, 4, 6, 8])
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: n == 8 ? 0 : 8),
                child: Semantics(
                  button: true,
                  selected: _pax == n,
                  child: InkWell(
                    key: ValueKey('pax-$n'),
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => setState(() => _pax = n),
                    child: Container(
                      height: 54,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: _pax == n ? kLimeBtn : Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: _pax == n ? kLimeBtn : kLine)),
                      child: Text('$n Pax', style: inter(16, _pax == n ? 700 : 500)),
                    ),
                  ),
                ),
              ),
            ),
        ]),
        const SizedBox(height: 14),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const InvLabel('DATE'),
              _pick(LucideIcons.calendar, _dateLabel, 'reserve-date', () async {
                final n = _now;
                final d = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(n.year, n.month, n.day), lastDate: n.add(const Duration(days: 90)));
                if (d != null) setState(() => _date = d);
              }),
            ]),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const InvLabel('TIME'),
              _pick(LucideIcons.clock, clock12Padded(_at), 'reserve-time', () async {
                final t = await showTimePicker(context: context, initialTime: _time);
                if (t != null) setState(() => _time = t);
              }),
            ]),
          ),
        ]),
        const InvLabel('SPECIAL NOTES'),
        TextField(
          controller: _notes,
          maxLines: 4,
          maxLength: 300,
          style: inter(16, 400),
          decoration: InputDecoration(
            hintText: 'Window seat, occasion…',
            counterText: '',
            filled: true,
            fillColor: Colors.white,
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFFD9DBD5))),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: kInk)),
          ),
        ),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, key: const ValueKey('reserve-error'), style: inter(14, 500, color: kRedText))),
        const SizedBox(height: 28),
        LimeButton('Confirm Reservation', icon: LucideIcons.check, busy: _busy, height: 58, onPressed: _name.text.trim().isEmpty || _phone.text.trim().isEmpty ? null : _submit),
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).maybePop(), child: Text('Cancel', style: inter(17, 500, color: kMuted))),
      ],
    );
  }

  Widget _pick(IconData icon, String text, String key, VoidCallback onTap) => InkWell(
        key: ValueKey(key),
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          height: 54,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFD9DBD5))),
          child: Row(children: [Icon(icon, size: 20, color: kMuted), const SizedBox(width: 10), Expanded(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: inter(15.5, 400)))]),
        ),
      );
}
