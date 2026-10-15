import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../ui/theme.dart';
import 'business_screens.dart';
import 'operations_screens.dart';
import 'setup_api.dart';
import 'setup_widgets.dart';
import 'storefront_screens.dart';

/// What a setup screen hands back: the newest state, and whether the person pressed the "… & Continue" button.
class StepResult {
  const StepResult(this.state, {this.advance = true});
  final SetupState state;
  final bool advance;
}

/// Closes a setup screen with the newest state; [advance] is true when "… & Continue" was pressed.
void popWith(BuildContext context, SetupState s, {bool advance = true}) => Navigator.of(context).pop(StepResult(s, advance: advance));

/// The order "Save & Continue" walks through. POS is left out for partners who sell only on the OneLocal app.
List<String> setupSequence(SetupState s) =>
    ['plan', 'payment', 'tax', if (s.posRequired) 'pos', 'staff', 'catalogue', 'listing', 'delivery'];

/// Whether one step of the walk is already saved on the server.
bool stepDone(SetupState s, String step) => switch (step) {
      'plan' => s.isDone('plan'),
      'payment' => s.payment['saved'] == true,
      'tax' => s.tax['saved'] == true,
      'pos' => s.isDone('pos'),
      'staff' => s.isDone('staff'),
      'catalogue' => s.isDone('catalogue'),
      'listing' => s.isDone('onelocal_profile'),
      'delivery' => s.isDone('delivery'),
      _ => true,
    };

/// The checklist row a step belongs to (tax is part of "Payment Setup").
const _rowOfStep = {'listing': 'onelocal_profile', 'tax': 'payment'};
const _stepOfRow = {'onelocal_profile': 'listing'};

Widget setupScreenFor(String step, SetupApi api, SetupState s) => switch (step) {
      'plan' => PlanScreen(api: api, state: s),
      'payment' => PaymentScreen(api: api, state: s),
      'tax' => TaxScreen(api: api, state: s),
      'pos' => PosScreen(api: api, state: s),
      'staff' => StaffScreen(api: api, state: s),
      'catalogue' => CatalogueScreen(api: api, state: s),
      'listing' => ListingScreen(api: api, state: s),
      _ => FulfilmentScreen(api: api, state: s),
    };

/// Opens the setup phase: reads the state from the server, then shows the checklist (or a retry screen).
/// [onFinished] runs from "Go to Partner Home" once setup is complete.
class SetupEntry extends StatefulWidget {
  const SetupEntry({super.key, this.api, required this.onFinished});
  final SetupApi? api;
  final void Function(BuildContext context) onFinished;
  @override
  State<SetupEntry> createState() => _SetupEntryState();
}

class _SetupEntryState extends State<SetupEntry> {
  late final _api = widget.api ?? SetupApi();
  late Future<SetupState> _load = _api.get();

  @override
  Widget build(BuildContext context) => FutureBuilder<SetupState>(
        future: _load,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const Scaffold(body: Center(child: CircularProgressIndicator(color: kLink)));
          if (snap.hasError) {
            return SetupDialog(
              title: 'We could not load your setup.',
              subtitle: 'Check your internet connection and try again.',
              children: const [],
              actions: [
                PillPrimary(
                  label: 'Try again',
                  onPressed: () {
                    final next = _api.get();
                    setState(() {
                      _load = next;
                    });
                  },
                ),
              ],
            );
          }
          return SetupDashboardScreen(api: _api, initial: snap.data!, onFinished: widget.onFinished);
        },
      );
}

/// Figma 17 "Business Setup Dashboard": the setup checklist with required and optional items.
class SetupDashboardScreen extends StatefulWidget {
  const SetupDashboardScreen({super.key, required this.api, required this.initial, required this.onFinished});
  final SetupApi api;
  final SetupState initial;
  final void Function(BuildContext context) onFinished;
  @override
  State<SetupDashboardScreen> createState() => _SetupDashboardScreenState();
}

class _SetupDashboardScreenState extends State<SetupDashboardScreen> with TourHost {
  late SetupState _s = widget.initial;
  final _listKey = GlobalKey();
  bool _busy = false;

  @override
  SetupApi get tourApi => widget.api;
  @override
  SetupState get tourState => _s;

  /// Opens [step]; while the person presses "… & Continue", carries on with the next step of the walk.
  Future<void> _walk(String step) async {
    var current = step;
    while (mounted) {
      final r = await Navigator.of(context).push<StepResult>(MaterialPageRoute(builder: (_) => setupScreenFor(current, widget.api, _s)));
      if (!mounted || r == null) return;
      setState(() => _s = r.state);
      if (!r.advance) return;
      final seq = setupSequence(_s);
      final i = seq.indexOf(current);
      if (i < 0 || i == seq.length - 1) {
        if (_s.canComplete) await _complete();
        return;
      }
      current = seq[i + 1];
    }
  }

  Future<void> _continue() async {
    if (_s.completed) return _openComplete();
    final seq = setupSequence(_s);
    final open = seq.where((k) => !stepDone(_s, k) && (_s.row(_rowOfStep[k] ?? k)['required'] == true)).toList();
    if (open.isEmpty) return _complete();
    await _walk(open.first);
  }

  Future<void> _complete() async {
    if (_busy) return;
    if (!_s.canComplete) {
      final left = _s.checklist.firstWhere((r) => r['required'] == true && r['done'] != true, orElse: () => const {});
      showToast(context, 'Finish ${left['title'] ?? 'the required items'} to complete setup.');
      return;
    }
    setState(() => _busy = true);
    final s = await setupGuarded(context, widget.api.complete);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (s != null) _s = s;
    });
    if (s != null) await _openComplete();
  }

  Future<void> _openComplete() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SetupCompleteScreen(api: widget.api, state: _s, onFinished: widget.onFinished)));
  }

  void _tapRow(Map<String, dynamic> r) {
    final key = r['key'] as String;
    switch (key) {
      case 'business_profile' || 'location' || 'owner_details':
        showToast(context, r['done'] == true ? 'Completed in your approved application.' : 'Contact OneLocal support to update this.');
      case 'inventory':
        showToast(context, 'Stock tracking is set up from your catalogue later. It is optional.');
      default:
        _walk(_stepOfRow[key] ?? key);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pct = _s.total == 0 ? 0.0 : _s.done / _s.total;
    return SetupDialog(
      title: 'Set up your business',
      subtitle: 'Finish the required items to start selling with OneLocal.',
      onClose: () => Navigator.of(context).maybePop(),
      tour: tourFor(1, 'Your setup checklist', 'Track your progress, see what’s complete, and find the next step to get your business ready.', _listKey),
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(value: pct, minHeight: 8, color: kLime, backgroundColor: kBg),
        ),
        const SizedBox(height: 8),
        Text('${_s.done} of ${_s.total} required tasks complete', style: inter(12, 400, color: kMuted)),
        const SizedBox(height: 14),
        TourTarget(
          tourKey: _listKey,
          child: Column(children: [
            for (final r in _s.checklist) _ChecklistRow(row: r, onTap: () => _tapRow(r)),
          ]),
        ),
      ],
      actions: [
        PillPrimary(label: _s.completed ? 'Go to Partner Home' : (_busy ? 'Completing…' : 'Continue Setup'), onPressed: _busy ? null : _continue),
      ],
    );
  }
}

class _ChecklistRow extends StatelessWidget {
  const _ChecklistRow({required this.row, required this.onTap});
  final Map<String, dynamic> row;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final status = row['status'] as String? ?? 'pending';
    final (word, color) = switch (status) {
      'completed' => ('Completed', kDone),
      'pending' => ('Pending', kPending),
      _ => ('Optional', kMuted),
    };
    final note = row['note'] as String?;
    return Semantics(
      button: true,
      label: '${row['title']}, $word',
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: kLine))),
          child: Row(children: [
            status == 'completed'
                ? const Icon(LucideIcons.circleCheck, size: 18, color: kDone)
                : Container(width: 17, height: 17, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: kMuted, width: 1.6))),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(row['title'] as String? ?? '', style: inter(12.5, 600)),
                if (note != null) Text(note, style: inter(10.5, 400, color: kMuted)),
              ]),
            ),
            Text(word, style: inter(10.5, 700, color: color)),
          ]),
        ),
      ),
    );
  }
}

/// Figma 26 "Setup Complete": the business is ready; "Go to Partner Home" hands over to [onFinished].
class SetupCompleteScreen extends StatefulWidget {
  const SetupCompleteScreen({super.key, required this.api, required this.state, required this.onFinished});
  final SetupApi api;
  final SetupState state;
  final void Function(BuildContext context) onFinished;
  @override
  State<SetupCompleteScreen> createState() => _SetupCompleteScreenState();
}

class _SetupCompleteScreenState extends State<SetupCompleteScreen> with TourHost {
  final _goKey = GlobalKey();
  @override
  SetupApi get tourApi => widget.api;
  @override
  SetupState get tourState => widget.state;

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    return SetupDialog(
      title: 'Your business is ready!',
      subtitle: 'Your required setup is complete. You can now continue to your Partner Home.',
      tour: tourFor(10, 'You’re ready to go!', 'Your required setup is complete. Head to Partner Home to start managing your business.', _goKey),
      children: [
        const SizedBox(height: 6),
        Center(
          child: Container(
            width: 64,
            height: 64,
            decoration: const BoxDecoration(color: Color(0xFFDCEBD0), shape: BoxShape.circle),
            alignment: Alignment.center,
            child: const Icon(LucideIcons.circleCheck, size: 32, color: kDone),
          ),
        ),
        const SizedBox(height: 16),
        Center(child: Text(s.businessName, textAlign: TextAlign.center, style: inter(13, 700))),
        const SizedBox(height: 4),
        Center(child: Text('${s.done} of ${s.total} required tasks complete', style: inter(12, 400, color: kMuted))),
        const SizedBox(height: 8),
      ],
      actions: [
        TourTarget(tourKey: _goKey, child: PillPrimary(label: 'Go to Partner Home', onPressed: () => widget.onFinished(context))),
      ],
    );
  }
}
