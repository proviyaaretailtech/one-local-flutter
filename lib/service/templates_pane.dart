import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../orders/order_widgets.dart';
import '../ui/motion.dart';
import '../ui/theme.dart';
import '../ui/xlsx.dart';
import 'service_api.dart';
import 'service_form.dart';
import 'service_parts.dart';
import 'service_widgets.dart';
import 'step_form.dart';

// Templates (founder, 3 Nov 2026: "like a restaurant's recipe master"): a template is a name, e.g. Manicure, with what the service needs
// (one person, a bottle of nail paint, a filer ...) and its rules, all picked from dropdowns. They are searched, used to fill the Add
// service form, and imported from or exported to Excel.

/// Hands an .xlsx over (tests replace it): a save dialog on a phone or computer, a download in the browser.
Future<void> Function(Uint8List bytes, String name) saveTemplatesFile = (bytes, name) async {
  await FilePicker.saveFile(fileName: name, bytes: bytes, mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', type: FileType.custom,
      allowedExtensions: const ['xlsx']);
};

/// Tests replace the file picker: a name and the bytes, or null.
Future<({String name, Uint8List bytes})?> Function() pickTemplatesFile = () async {
  final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['xlsx', 'csv']);
  if (f == null) return null;
  return (name: f.name, bytes: await f.readAsBytes());
};

// ============================================================================================================ Excel

const kTemplateColumns = ['Template', 'Category', 'Subcategory', 'Length (min)', 'Line', 'Type or rule category', 'Item or condition', 'Qty', 'Unit', 'Result', 'Price', 'Notes'];

/// One sheet: a row per need and per rule, each with its template's name (the first row of a template also carries its category, length
/// and notes). A template with nothing yet still has one row.
List<List<Object?>> templateRows(List<ServiceTemplate> templates) => [
      kTemplateColumns,
      for (final t in templates) ...() {
        final lines = <List<Object?>>[
          for (final n in t.requirements) ['Needs', needLabel('${n['type']}'), n['name'], n['qty'], n['unit'], null, null],
          for (final r in t.rules)
            ['Rule', ruleConditions(r).map((c) => c['category']).join(' + '), ruleConditions(r).map((c) => c['condition']).join(' + '), null, r['per'], r['result'], r['price']],
        ];
        if (lines.isEmpty) lines.add([null, null, null, null, null, null, null]);
        return [
          for (var i = 0; i < lines.length; i++)
            [t.name, i == 0 ? listingCategory(t.category)?.name : null, i == 0 ? t.subcategory : null, i == 0 ? t.durationMin : null, ...lines[i], i == 0 ? t.notes : null],
        ];
      }(),
    ];

/// The templates in a sheet laid out as [templateRows] (the header row is found by its first cell). Items are matched to [options] by
/// name, so a material or tool in the business's Inventory keeps its link; anything else is kept by name.
List<Map<String, Object?>> templatesFromRows(List<List<String>> table, NeedsOptions options) {
  final head = table.indexWhere((r) => r.isNotEmpty && r.first.trim().toLowerCase() == 'template');
  final byName = <String, Map<String, Object?>>{};
  for (final row in table.skip(head + 1)) {
    String cell(int i) => i < row.length ? row[i].trim() : '';
    final name = cell(0);
    if (name.isEmpty) continue;
    final t = byName.putIfAbsent(name.toLowerCase(), () => {'name': name, 'requirements': <Map<String, Object?>>[], 'rules': <Map<String, Object?>>[]});
    final cat = listingCategories.where((c) => c.name.toLowerCase() == cell(1).toLowerCase() || c.key == cell(1).toLowerCase()).firstOrNull;
    if (cat != null) t['category'] = cat.key;
    if (cell(2).isNotEmpty) t['subcategory'] = cell(2);
    final len = int.tryParse(cell(3));
    if (len != null && len >= 5 && len <= 600) t['duration_min'] = len;
    if (cell(11).isNotEmpty) t['notes'] = cell(11);
    final line = cell(4).toLowerCase();
    if (line == 'needs' && cell(6).isNotEmpty) {
      final type = needType(kNeedTypes.firstWhere((k) => k.toLowerCase() == cell(5).toLowerCase(), orElse: () => 'Other'));
      final match = options.itemsFor(type).where((x) => x.$2.toLowerCase() == cell(6).toLowerCase() || x.$2.toLowerCase().startsWith('${cell(6).toLowerCase()} ·')).firstOrNull;
      (t['requirements'] as List).add({
        'type': type,
        'item_id': match?.$1,
        'name': match?.$2 ?? cell(6),
        'qty': num.tryParse(cell(7)) ?? 1,
        if (type == 'material' || type == 'other') 'unit': kUnits.contains(cell(8)) ? cell(8) : 'pcs',
      });
    } else if (line == 'rule' && cell(5).isNotEmpty) {
      // "Gender + Age" with "Women + 18 and above": one rule with both conditions
      final cats = cell(5).split(' + '), conds = cell(6).split(' + ');
      (t['rules'] as List).add({
        'conditions': [
          for (var j = 0; j < cats.length; j++)
            kRuleCategories.containsKey(cats[j].trim())
                ? {'category': cats[j].trim(), 'condition': j < conds.length ? conds[j].trim() : ''}
                : {'category': 'Custom', 'condition': '${cats[j].trim()}: ${j < conds.length ? conds[j].trim() : ''}'},
        ],
        'result': kRuleResults.contains(cell(9)) ? cell(9) : 'Allowed',
        if (num.tryParse(cell(10)) != null) 'price': num.parse(cell(10)),
        'per': kRulePer.contains(cell(8)) ? cell(8) : 'each',
      });
    }
  }
  return byName.values.toList();
}

// ============================================================================================================ the tab

/// The catalogue's Templates tab: search, Import and Export, + New template, and the saved templates. [onUse] starts a new service from
/// one (the catalogue opens the Add service form filled from it).
class TemplatesPane extends StatefulWidget {
  const TemplatesPane({super.key, required this.api, required this.onUse, this.pickOnly = false});

  /// "Add from existing templates": a tap uses the template at once, and there is no New, Import or Export.
  final bool pickOnly;
  final ServiceApi api;
  final ValueChanged<ServiceTemplate> onUse;
  @override
  State<TemplatesPane> createState() => TemplatesPaneState();
}

class TemplatesPaneState extends State<TemplatesPane> {
  TemplateListData? _d;
  NeedsOptions _options = const NeedsOptions();
  String? _error;
  String _q = '';
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    reload();
    widget.api.listingView().then((o) {
      if (mounted) setState(() => _options = NeedsOptions.of(o));
    }).catchError((_) {});
  }

  Future<void> reload() async {
    final mine = ++_seq;
    try {
      final d = await widget.api.templates(q: _q);
      if (mounted && mine == _seq) {
        setState(() {
          _d = d;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && mine == _seq) setState(() => _error = e is ServiceApiException ? e.message : e.toString());
    }
  }

  Future<void> _edit([ServiceTemplate? t]) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => TemplateEditorScreen(api: widget.api, template: t)));
    if (saved == true && mounted) reload();
  }

  Future<void> _actions(BuildContext from, ServiceTemplate t) async {
    final canEdit = _d?.canEdit ?? false;
    final pick = await showActionBox<String>(from, over: true, title: t.name, actions: [
      ('use', 'Use for a new service', const ValueKey('tpl-use')),
      if (canEdit) ...[
        ('edit', 'Edit template', const ValueKey('tpl-edit')),
        ('delete', 'Delete template', const ValueKey('tpl-delete')),
      ],
    ]);
    if (!mounted || pick == null) return;
    if (pick == 'use') return widget.onUse(t);
    if (pick == 'edit') return _edit(t);
    try {
      final d = await widget.api.saveTemplate({'id': t.id, 'archived': true}, key: ServiceApi.newKey());
      if (mounted) {
        setState(() => _d = d);
        showToast(context, '${t.name} deleted.');
      }
    } catch (e) {
      if (mounted) showServiceError(context, e);
    }
  }

  Future<void> _export() async {
    try {
      final all = await widget.api.templates();
      if (all.templates.isEmpty) {
        if (mounted) showToast(context, 'No templates to export yet.');
        return;
      }
      await saveTemplatesFile(buildXlsx('Templates', templateRows(all.templates), widths: const [22, 12, 18, 11, 8, 20, 24, 6, 8, 16, 9, 30]), 'service-templates.xlsx');
      if (mounted) showToast(context, '${all.templates.length} ${all.templates.length == 1 ? 'template' : 'templates'} exported.');
    } catch (e) {
      if (mounted) showServiceError(context, e);
    }
  }

  Future<void> _import() async {
    final how = await showOrderSheet<String>(context, title: 'Import templates', body: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('An Excel or CSV file with one row per need or rule: Template, Category, Subcategory, Length (min), Line (Needs or Rule), Type or rule category, '
              'Item or condition, Qty, Unit, Result, Price, Notes. A template with the same name is replaced.', style: inter(13, 400, color: kMuted)),
          const SizedBox(height: 12),
          DarkCta(key: const ValueKey('tpl-import-pick'), label: 'Choose a file', onPressed: () => Navigator.pop(ctx, 'pick')),
          const SizedBox(height: 8),
          LightCta(key: const ValueKey('tpl-import-sample'), label: 'Download a sample', onPressed: () => Navigator.pop(ctx, 'sample')),
        ]));
    if (!mounted || how == null) return;
    if (how == 'sample') {
      final sample = ServiceTemplate({
        'name': 'Manicure', 'category': 'service', 'subcategory': 'Beauty parlour', 'duration_min': 45, 'notes': 'Classic manicure',
        'requirements': [
          {'type': 'person', 'name': 'Any staff', 'qty': 1},
          {'type': 'material', 'name': 'Nail paint', 'qty': 1, 'unit': 'bottle'},
          {'type': 'tool', 'name': 'Nail filer', 'qty': 1},
        ],
        'rules': [
          {'category': 'Gender', 'condition': 'Anyone', 'result': 'Allowed'},
        ],
      });
      await saveTemplatesFile(buildXlsx('Templates', templateRows([sample]), widths: const [22, 12, 18, 11, 8, 20, 24, 6, 8, 16, 9, 30]), 'service-templates-sample.xlsx');
      return;
    }
    final file = await pickTemplatesFile();
    if (file == null || !mounted) return;
    try {
      final table = file.name.toLowerCase().endsWith('.csv') ? readCsv(String.fromCharCodes(file.bytes)) : readXlsx(file.bytes);
      final templates = templatesFromRows(table, _options);
      if (templates.isEmpty) {
        showToast(context, 'No templates found in ${file.name}. The first column must be Template.');
        return;
      }
      final d = await widget.api.importTemplates(templates, key: ServiceApi.newKey());
      if (!mounted) return;
      setState(() => _d = d);
      showToast(context, '${d.added} added · ${d.updated} replaced.');
    } catch (e) {
      if (mounted) showServiceError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    if (_error != null) {
      return OrderCardBox(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_error!, style: inter(13.5, 500)),
        const SizedBox(height: 8),
        SmallPill('Try again', onTap: reload),
      ]));
    }
    if (d == null) return const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: kGreenText)));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(
          child: SvcSearch(hint: 'Search templates', fieldKey: const ValueKey('tpl-search'), onChanged: (v) {
            _q = v;
            reload();
          }),
        ),
        const SizedBox(width: 8),
        if (!widget.pickOnly) ...[
          if (d.canEdit) _iconPill('tpl-import', LucideIcons.upload, 'Import', _import),
          const SizedBox(width: 6),
          _iconPill('tpl-export', LucideIcons.download, 'Export', _export),
        ],
      ]),
      const SizedBox(height: 12),
      SvcSectionHead('Templates', count: '${d.total} saved'),
      if (d.templates.isEmpty)
        OrderCardBox(
          child: Text(
            d.total == 0
                ? 'No templates yet. In Add service, fill the form and tap "Save as a template" at the end, or import templates from Excel.'
                : 'No template matches.',
            style: inter(14, 400, color: kMuted),
          ),
        ),
      for (var i = 0; i < d.templates.length; i++) Entrance(key: ValueKey('in-tpl-${d.templates[i].id}'), index: i, child: _card(d.templates[i])),
    ]);
  }

  Widget _iconPill(String key, IconData icon, String label, VoidCallback onTap) => Material(
        color: Colors.white,
        shape: const StadiumBorder(side: BorderSide(color: Color(0xFFD9DBD3))),
        child: InkWell(
          key: ValueKey(key),
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 16, color: kInk), const SizedBox(width: 6), Text(label, style: inter(13.5, 600))]),
          ),
        ),
      );

  Widget _card(ServiceTemplate t) {
    final cat = listingCategory(t.category);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Builder(builder: (from) => InkWell(
        key: ValueKey('tpl-${t.id}'),
        borderRadius: BorderRadius.circular(16),
        onTap: () => widget.pickOnly ? widget.onUse(t) : _actions(from, t),
        child: OrderCardBox(
          radius: 16,
          padding: const EdgeInsets.all(12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: kBg, shape: BoxShape.circle, border: Border.all(color: kLine)),
              child: Icon(cat?.icon ?? LucideIcons.clipboardList, size: 19, color: kInk),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(t.name, style: inter(15.5, 700))),
                  if (t.usedBy > 0) svcStatus('Used by ${t.usedBy}', 'good'),
                ]),
                Text(
                  [if (cat != null) cat.name, if ((t.subcategory ?? '').isNotEmpty) t.subcategory!, if (t.durationMin != null) lengthLabel(t.durationMin!)].join(' · '),
                  style: inter(12.5, 400, color: kMuted),
                ),
                const SizedBox(height: 6),
                Text(t.requirements.isEmpty ? 'Needs nothing set yet' : needsSummary(t.requirements), style: inter(12.5, 600)),
                if (t.rules.isNotEmpty) Text('${t.rules.length} ${t.rules.length == 1 ? 'rule' : 'rules'} · ${ruleSummary(t.rules.first)}', style: inter(12, 400, color: kMuted)),
              ]),
            ),
          ]),
        ),
      )),
    );
  }
}

// ============================================================================================================ the editor

/// New or edit template, laid out like the recipe master: name, category, subcategory and length at the top; what it needs (per
/// booking) as rows of type, item, qty and unit; its rules; the summary; notes; Cancel and Save template.
class TemplateEditorScreen extends StatefulWidget {
  const TemplateEditorScreen({super.key, required this.api, this.template});
  final ServiceApi api;
  final ServiceTemplate? template;
  @override
  State<TemplateEditorScreen> createState() => _TemplateEditorScreenState();
}

class _TemplateEditorScreenState extends State<TemplateEditorScreen> {
  late final t = widget.template;
  late final _name = TextEditingController(text: t?.name ?? '');
  late final _notes = TextEditingController(text: t?.notes ?? '');
  late String? _category = t?.category;
  late String? _sub = t?.subcategory;
  late String? _length = t?.durationMin == null ? null : lengthLabel(t!.durationMin!);
  late List<Map<String, dynamic>> _needs = [...?t?.requirements.map((r) => {...r})];
  late List<Map<String, dynamic>> _rules = [...?t?.rules.map((r) => {...r})];
  NeedsOptions _options = const NeedsOptions();
  final _key = ServiceApi.newKey();
  bool _busy = false;
  int _step = 0; // Template, What it needs, Rules, Notes

  @override
  void initState() {
    super.initState();
    CustomOptions.load();
    widget.api.listingView().then((o) {
      if (mounted) setState(() => _options = NeedsOptions.of(o));
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _name.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().length < 2) {
      setState(() => _step = 0);
      return showToast(context, 'Give the template a name.');
    }
    setState(() => _busy = true);
    try {
      await widget.api.saveTemplate({
        if (t != null) 'id': t!.id,
        'name': _name.text.trim(),
        'category': _category,
        'subcategory': _sub,
        'duration_min': _length == null ? null : listingMinutes(_length),
        'requirements': _needs,
        'rules': _rules,
        'notes': _notes.text.trim(),
      }, key: _key);
      if (!mounted) return;
      showToast(context, '${_name.text.trim()} saved.');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showServiceError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static const _steps = [
    ('Template', LucideIcons.clipboardList, 'A name you will search for, like Manicure or AC service.'),
    ('What it needs', LucideIcons.boxes, 'Pick each person, place, tool or material, and how many (per booking).'),
    ('Rules', LucideIcons.listChecks, 'Pick any category: gender, age, group, people going, day ... The first rule that fits wins.'),
    ('Notes', LucideIcons.notebookPen, 'Anything the team should know. Then save the template.'),
  ];

  // In steps like every form (founder, 4 Nov 2026): Template, What it needs, Rules, Notes; Save template on the last.
  @override
  Widget build(BuildContext context) => StepFormPage(
        title: t == null ? 'New template' : 'Edit template',
        keyPrefix: 'te',
        steps: [for (final st in _steps) st.$1],
        step: _step,
        onStep: (i) => setState(() => _step = i),
        body: [_stepCard()],
        finish: Row(children: [
          Expanded(child: LightCta(key: const ValueKey('te-cancel'), label: 'Cancel', onPressed: () => Navigator.of(context).maybePop())),
          const SizedBox(width: 10),
          Expanded(child: DarkCta(key: const ValueKey('te-save'), label: 'Save template', busy: _busy, onPressed: _busy ? null : _save)),
        ]),
      );

  Widget _stepCard() {
    final cat = listingCategory(_category);
    final (title, icon, line) = _steps[_step];
    return FormCard(
      title: title,
      line: line,
      icon: icon,
      child: switch (_step) {
        0 => FieldGrid(children: [
            (false, Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              fieldLabel('Template name'),
              TextField(key: const ValueKey('te-name'), controller: _name, style: inter(14, 500), decoration: formBox(hint: 'e.g. ${listingExamples(_category, _sub).name}')),
            ])),
            (true, Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              fieldLabel('Category'),
              PickBox(fieldKey: const ValueKey('te-category'), value: cat?.name, hint: 'Any', onTap: () async {
                final p = await pickOne(context, 'Category', [for (final c in listingCategories) c.name], current: cat?.name, canAdd: false);
                if (p != null) {
                  setState(() {
                    _category = listingCategories.firstWhere((c) => c.name == p).key;
                    _sub = null;
                  });
                }
              }),
            ])),
            (true, Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              fieldLabel('Subcategory'),
              PickBox(fieldKey: const ValueKey('te-subcategory'), value: _sub, hint: cat == null ? 'Pick a category' : 'Choose', onTap: cat == null ? null : () async {
                final p = await pickOne(context, 'Subcategory', cat.allSubcategories, current: _sub, groups: cat.subcategories.length > 1 ? cat.subcategories : null, addKey: 'Subcategory:${cat.key}');
                if (p != null) setState(() => _sub = p);
              }),
            ])),
            (true, Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              fieldLabel('Length'),
              PickBox(fieldKey: const ValueKey('te-length'), value: _length, hint: 'Choose', onTap: () async {
                final p = await pickOne(context, 'Length', kLengths, current: _length, input: OwnInput.length);
                if (p != null) setState(() => _length = p);
              }),
            ])),
          ]),
        1 => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            NeedsEditor(rows: _needs, options: _options, keyPrefix: 'te-need', onChanged: (r) => setState(() => _needs = r)),
            needsTotal(_needs, _rules, key: const ValueKey('te-total')),
          ]),
        2 => RulesEditor(rows: _rules, keyPrefix: 'te-rule', api: widget.api, onChanged: (r) => setState(() => _rules = r)),
        _ => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: TextField(key: const ValueKey('te-notes'), controller: _notes, maxLines: 3, minLines: 2, style: inter(14, 500), decoration: formBox(hint: 'Prep notes (optional)')),
          ),
      },
    );
  }
}

/// "Add from existing templates" (founder, 4 Nov 2026): the saved templates with a search; a tap opens the Add service form filled from
/// that template, and saving it comes back to the catalogue.
class TemplatePickScreen extends StatelessWidget {
  const TemplatePickScreen({super.key, required this.api, this.business = ''});
  final ServiceApi api;
  final String business;
  @override
  Widget build(BuildContext context) => ServicePage(
        title: 'Add from existing templates',
        subtitle: 'Pick one; it fills what the service needs, its rules and length',
        business: business,
        body: [
          TemplatesPane(
            api: api,
            pickOnly: true,
            onUse: (t) async {
              final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => ServiceFormScreen(api: api, template: t, business: business)));
              if (saved == true && context.mounted) Navigator.of(context).pop(true);
            },
          ),
        ],
      );
}
