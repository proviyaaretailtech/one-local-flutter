import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../service/service_widgets.dart' show svcRupees;
import '../ui/app_header.dart';
import '../ui/theme.dart';
import 'menu_api.dart';
import 'menu_widgets.dart';

/// Figma "Menu – Item detail" with the founder's changes (20 Oct 2026): a Description section with Write with AI, "Select availability"
/// (Morning, Evening, Night, Custom) instead of "Select Unavailable Duration", and "Apply to Channels" shown as Coming soon.
/// Nothing is written until the owner presses Save; the database checks the windows, the version and the role.
class DishScreen extends StatefulWidget {
  const DishScreen({super.key, required this.api, required this.dishId, this.locationId, this.startEditing = false});
  final MenuApi api;
  final String dishId;
  final String? locationId;
  final bool startEditing;

  static Route<bool> route(MenuApi api, String dishId, {String? locationId, bool edit = false}) => MaterialPageRoute(
    builder: (_) => DishScreen(api: api, dishId: dishId, locationId: locationId, startEditing: edit),
  );

  @override
  State<DishScreen> createState() => _DishScreenState();
}

class _DishScreenState extends State<DishScreen> {
  late Future<DishDetail> _f = _load();
  DishDetail? _dish;
  final _desc = TextEditingController();
  final _descFocus = FocusNode();
  List<ServingWindow> _windows = [];
  bool _aiBusy = false, _saving = false, _aiDraft = false, _changed = false;
  String? _aiNote; // why AI could not help (not set up, limit reached, ...): manual writing always stays available
  bool _aiNoteIsError = false;

  Future<DishDetail> _load() async {
    final d = await widget.api.dish(widget.dishId, locationId: widget.locationId);
    if (mounted) setState(() => _take(d)); // the Save bar lives outside the FutureBuilder
    if (widget.startEditing) WidgetsBinding.instance.addPostFrameCallback((_) => _descFocus.requestFocus());
    return d;
  }

  void _take(DishDetail d) {
    _dish = d;
    _desc.text = d.description;
    _windows = d.availability;
    _changed = false;
    _aiDraft = false;
  }

  @override
  void dispose() {
    _desc.dispose();
    _descFocus.dispose();
    super.dispose();
  }

  Future<void> _writeWithAi() async {
    final d = _dish;
    if (d == null || _aiBusy) return;
    setState(() {
      _aiBusy = true;
      _aiNote = null;
    });
    try {
      final text = await widget.api.aiDescribe(d.id, _desc.text);
      if (!mounted) return;
      setState(() {
        _desc.text = text;
        _aiDraft = true;
        _changed = true;
        _aiNote = 'AI draft. Read it, change anything, then tap Save.';
        _aiNoteIsError = false;
      });
    } on MenuApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _aiNote = e.aiNotConfigured
            ? 'AI writing is not set up yet. You can still write the description yourself.'
            : '${e.message} You can still write it yourself.';
        _aiNoteIsError = true;
      });
    } finally {
      if (mounted) setState(() => _aiBusy = false);
    }
  }

  Future<void> _save() async {
    final d = _dish;
    if (d == null || _saving) return;
    setState(() => _saving = true);
    try {
      final next = await widget.api.save(d.id, d.version, locationId: widget.locationId, description: _desc.text.trim(), availability: _windows);
      if (!mounted) return;
      setState(() {
        _take(next);
        _aiNote = null;
      });
      showToast(context, 'Saved');
    } on MenuApiException catch (e) {
      if (!mounted) return;
      showToast(context, e.stale ? 'This dish was changed on another device. Pull down to load the latest.' : e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _reload() async {
    final next = _load();
    setState(() {
      _f = next;
    });
    try {
      await next;
    } catch (_) {
      /* drawn by the builder */
    }
  }

  void _togglePreset(ServingWindow p) => setState(() {
    _windows.any((w) => w.slot == p.slot) ? _windows = _windows.where((w) => w.slot != p.slot).toList() : _windows = [..._windows, p];
    _changed = true;
  });

  Future<void> _addCustom() async {
    final w = await showModalBottomSheet<ServingWindow>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => const CustomWindowSheet(),
    );
    if (w == null || !mounted) return;
    setState(() {
      if (!_windows.contains(w)) _windows = [..._windows, w];
      _changed = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        children: [
          // the banner (☰ always) with the one back arrow under it
          AppHeader(title: 'Dish details', back: true, backKey: const ValueKey('dish-back'), onBack: () => Navigator.of(context).maybePop(_changed)),
          Expanded(
            child: FutureBuilder<DishDetail>(
              future: _f,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done && _dish == null) return const Center(child: CircularProgressIndicator(color: kLink));
                if (snap.hasError && _dish == null) return MenuError(error: snap.error!, onRetry: _reload);
                final d = _dish!;
                final edit = d.canEdit;
                return RefreshIndicator(
                  onRefresh: _reload,
                  color: kLink,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 120),
                    children: [
                      DishPhoto(urls: d.images, height: 220),
                      if (d.images.length > 1) ...[
                        const SizedBox(height: 8),
                        SizedBox(
                          height: 56,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            children: [
                              for (final u in d.images)
                                Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: DishPhoto(urls: [u], height: 56, width: 72),
                                ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(padding: const EdgeInsets.only(top: 6), child: FoodTypeMark(d.foodType)),
                          const SizedBox(width: 10),
                          Expanded(child: Text(d.name, style: inter(20, 700))),
                          Text(svcRupees(d.priceMinor / 100), style: inter(18, 700)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(d.orderableNow ? LucideIcons.circleCheck : LucideIcons.clock, size: 14, color: d.orderableNow ? kLink : kMuted),
                          const SizedBox(width: 6),
                          Text(
                            d.orderableNow ? 'Can be ordered now' : 'Not orderable right now',
                            key: const ValueKey('dish-orderable'),
                            style: inter(12, 500, color: d.orderableNow ? kLink : kMuted),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _Card(
                        title: 'Ingredients',
                        child: d.ingredients.isEmpty
                            ? Text('No recipe recorded for this dish.', style: inter(13, 400, color: kMuted))
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  for (final i in d.ingredients)
                                    Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 4),
                                      child: Row(
                                        children: [
                                          const Icon(Icons.circle, size: 8, color: kCheck),
                                          const SizedBox(width: 10),
                                          Text('${i['name']}', style: inter(14, 400, color: kMuted)),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                      ),
                      const SizedBox(height: 16),
                      _Card(
                        title: 'Description',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Type the ingredients or a rough note, then tap Write with AI. You can also just write it yourself.',
                              style: inter(12, 400, color: kMuted),
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              key: const ValueKey('dish-description'),
                              controller: _desc,
                              focusNode: _descFocus,
                              enabled: edit,
                              maxLines: 4,
                              minLines: 3,
                              maxLength: 500,
                              onChanged: (_) => setState(() => _changed = true),
                              style: inter(14, 400),
                              decoration: InputDecoration(
                                hintText: 'e.g. coffee shot, hot water, served large',
                                hintStyle: inter(14, 400, color: kMuted),
                                filled: true,
                                fillColor: kField,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(kRadius),
                                  borderSide: const BorderSide(color: kFieldBorder),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(kRadius),
                                  borderSide: const BorderSide(color: kFieldBorder),
                                ),
                              ),
                            ),
                            if (_aiNote != null)
                              Container(
                                key: const ValueKey('dish-ai-note'),
                                margin: const EdgeInsets.only(bottom: 8),
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(color: _aiNoteIsError ? const Color(0xFFFFF4E5) : kNote, borderRadius: BorderRadius.circular(10)),
                                child: Text(_aiNote!, style: inter(12, 500, color: _aiNoteIsError ? const Color(0xFF8A4B00) : kInk)),
                              ),
                            if (edit)
                              Align(
                                alignment: Alignment.centerLeft,
                                child: OutlinedButton.icon(
                                  key: const ValueKey('dish-ai'),
                                  onPressed: _aiBusy ? null : _writeWithAi,
                                  icon: _aiBusy
                                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: kInk))
                                      : const Icon(LucideIcons.sparkles, size: 16, color: kInk),
                                  label: Text(_aiBusy ? 'Writing…' : (_aiDraft ? 'Write again' : 'Write with AI'), style: inter(13, 600)),
                                  style: OutlinedButton.styleFrom(
                                    side: const BorderSide(color: kFieldBorder),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text('Select availability', style: inter(16, 700)),
                      const SizedBox(height: 4),
                      Text(
                        _windows.isEmpty ? 'Orderable all day. Choose times to sell it only then.' : 'Orderable only inside the chosen times.',
                        key: const ValueKey('dish-availability-hint'),
                        style: inter(12, 400, color: kMuted),
                      ),
                      const SizedBox(height: 10),
                      GridView.count(
                        crossAxisCount: 2,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        mainAxisSpacing: 10,
                        crossAxisSpacing: 10,
                        childAspectRatio: 2.6,
                        children: [
                          for (final p in kPresets)
                            SlotTile(
                              key: ValueKey('slot-${p.slot}'),
                              title: slotName(p.slot),
                              subtitle: p.label,
                              selected: _windows.any((w) => w.slot == p.slot),
                              onTap: edit ? () => _togglePreset(p) : null,
                            ),
                          SlotTile(
                            key: const ValueKey('slot-custom'),
                            title: 'Custom',
                            subtitle: 'Start and end time',
                            selected: _windows.any((w) => w.slot == 'custom'),
                            onTap: edit ? _addCustom : null,
                          ),
                        ],
                      ),
                      for (final w in _windows.where((w) => w.slot == 'custom'))
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Row(
                            children: [
                              const Icon(LucideIcons.clock, size: 16, color: kMuted),
                              const SizedBox(width: 8),
                              Expanded(child: Text('Custom ${w.label}', style: inter(13, 500))),
                              if (edit)
                                IconButton(
                                  key: ValueKey('custom-remove-${w.startsAt}-${w.endsAt}'),
                                  icon: const Icon(LucideIcons.x, size: 16, color: kMuted),
                                  onPressed: () => setState(() {
                                    _windows = _windows.where((x) => x != w).toList();
                                    _changed = true;
                                  }),
                                ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 22),
                      const ChannelsComingSoon(),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
      bottomNavigationBar: (_dish?.canEdit ?? false)
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: SizedBox(
                  height: 50,
                  child: FilledButton(
                    key: const ValueKey('dish-save'),
                    onPressed: _changed && !_saving ? _save : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: kPrimary,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadius)),
                    ),
                    child: Text(_saving ? 'Saving…' : 'Save', style: inter(15, 600, color: Colors.white)),
                  ),
                ),
              ),
            )
          : null,
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child});
  final String title;
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: kLine),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: inter(15, 700)),
        const SizedBox(height: 8),
        child,
      ],
    ),
  );
}

String slotName(String slot) => switch (slot) {
  'morning' => 'Morning',
  'evening' => 'Evening',
  'night' => 'Night',
  _ => 'Custom',
};

/// Picks a custom start and end time (every 30 minutes; an end before the start runs past midnight).
class CustomWindowSheet extends StatefulWidget {
  const CustomWindowSheet({super.key});
  @override
  State<CustomWindowSheet> createState() => _CustomWindowSheetState();
}

class _CustomWindowSheetState extends State<CustomWindowSheet> {
  static final _times = [for (var m = 0; m < 24 * 60; m += 30) '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}'];
  String _start = '12:00', _end = '16:00';

  Widget _pick(String label, String value, List<String> options, ValueChanged<String> on, Key key) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: inter(12, 500, color: kMuted)),
        DropdownButton<String>(
          key: key,
          value: value,
          isExpanded: true,
          items: [
            for (final t in options)
              DropdownMenuItem(
                value: t,
                child: Text(t, style: inter(15, 500)),
              ),
          ],
          onChanged: (v) => setState(() => on(v!)),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(kPadX, 20, kPadX, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Custom time', style: inter(16, 700)),
          const SizedBox(height: 4),
          Text('An end before the start runs past midnight.', style: inter(12, 400, color: kMuted)),
          const SizedBox(height: 12),
          Row(
            children: [
              _pick('Start', _start, _times, (v) => _start = v, const ValueKey('custom-start')),
              const SizedBox(width: 16),
              _pick('End', _end, [..._times.skip(1), '24:00'], (v) => _end = v, const ValueKey('custom-end')),
            ],
          ),
          const SizedBox(height: 16),
          FilledButton(
            key: const ValueKey('custom-add'),
            onPressed: _start == _end ? null : () => Navigator.pop(context, ServingWindow('custom', _start, _end)),
            style: FilledButton.styleFrom(backgroundColor: kPrimary, minimumSize: const Size.fromHeight(48)),
            child: Text('Add time', style: inter(15, 600, color: Colors.white)),
          ),
        ],
      ),
    ),
  );
}
