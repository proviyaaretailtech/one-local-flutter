import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_api.dart' show Facts;
import '../inventory/inventory_widgets.dart' show pickOne;
import '../orders/order_widgets.dart';
import '../ui/theme.dart';
import 'team_api.dart';
import 'team_screens.dart' show TeamLoader;
import 'team_widgets.dart';

/// Figma "Staff Activity": who did what, newest first. Read only.
class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key, required this.env});
  final TeamEnv env;
  @override
  State<ActivityScreen> createState() => _ActivityState();
}

class _ActivityState extends State<ActivityScreen>
    with TeamLoader<ActivityScreen, Facts> {
  TeamEnv get env => widget.env;
  String _range = 'today';
  String? _locName;

  @override
  Future<Facts> fetch() => env.api.activity(range: _range);
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> _pickLocation() async {
    final o = await env.api.options();
    if (!mounted) return;
    final locs = o.l('locations');
    final v = await pickOne<String>(context, 'Location', [
      ('', 'All locations', null),
      for (final l in locs) (l.s('id'), l.s('name'), null),
    ], current: env.api.locationId ?? '');
    if (v == null) return;
    env.api.locationId = v.isEmpty ? null : v;
    setState(
      () => _locName = v.isEmpty
          ? null
          : locs.firstWhere((l) => l.s('id') == v).s('name'),
    );
    load();
  }

  @override
  Widget build(BuildContext context) => TeamPage(
    env: env,
    title: 'Staff activity',
    subtitle: 'Recent changes across your team',
    onRefresh: load,
    children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (id, label) in const [
              ('today', 'Today'),
              ('7d', '7 days'),
            ])
              _Pill(
                label,
                active: _range == id,
                onTap: () {
                  setState(() => _range = id);
                  load();
                },
              ),
            _Pill(
              _locName ?? 'All locations',
              active: _locName != null,
              onTap: _pickLocation,
              chevron: true,
            ),
          ],
        ),
      ),
      TeamLoad<Facts>(
        data: data,
        error: error,
        onRetry: load,
        builder: (d) {
          final items = d.l('items');
          if (items.isEmpty) {
            return [
              OrderCardBox(
                child: Text(
                  'Nothing has happened in this time yet.',
                  style: inter(14, 400, color: kMuted),
                ),
              ),
            ];
          }
          return [
            for (final e in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Semantics(
                  container: true,
                  label:
                      '${e.s('actor')}, ${e.s('text')}, ${e.s('area')}, ${e.s('place')}, ${e.t('at') == null ? '' : whenLabel(e.t('at')!)}',
                  child: ExcludeSemantics(
                    child: OrderCardBox(
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Avatar(
                            e.s('initials'),
                            size: 38,
                            soft:
                                e.s('source') != 'task' &&
                                e.s('area') != 'Users',
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        e.s('actor'),
                                        style: inter(15, 600),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    Text(
                                      e.t('at') == null
                                          ? ''
                                          : whenLabel(e.t('at')!),
                                      style: inter(12, 400, color: kMuted),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  e.s('text'),
                                  style: inter(14, 400, height: 1.3),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${e.s('area')} · ${e.s('place')}',
                                  style: inter(12, 400, color: kMuted),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ];
        },
      ),
    ],
  );
}

class _Pill extends StatelessWidget {
  const _Pill(
    this.label, {
    required this.active,
    required this.onTap,
    this.chevron = false,
  });
  final String label;
  final bool active, chevron;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: active,
    label: label,
    child: InkWell(
      borderRadius: BorderRadius.circular(99),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: active ? kChipGreen : Colors.white,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: active ? kChipGreen : kTileLine),
        ),
        child: ExcludeSemantics(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: inter(12.5, 600, color: active ? kGreenText : kInk),
              ),
              if (chevron) ...[
                const SizedBox(width: 4),
                const Icon(LucideIcons.chevronDown, size: 14, color: kMuted),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

String dueLine(Facts t) {
  final due = t.t('due_at');
  if (due == null) return 'No due time';
  final time = t.b('has_time') ? clock12(due) : 'end of day';
  return t.b('overdue') ? 'Overdue · $time' : 'Due $time';
}

/// Figma "Staff Tasks": assign, track and verify team work.
class TasksScreen extends StatefulWidget {
  const TasksScreen({super.key, required this.env, this.filter = 'all'});
  final TeamEnv env;
  final String filter;
  @override
  State<TasksScreen> createState() => _TasksState();
}

class _TasksState extends State<TasksScreen>
    with TeamLoader<TasksScreen, Facts> {
  TeamEnv get env => widget.env;
  late String _filter = widget.filter;
  @override
  Future<Facts> fetch() => env.api.tasks(filter: _filter);
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> _go(Widget screen) async {
    await env.push(context, screen);
    if (mounted) load();
  }

  @override
  Widget build(BuildContext context) {
    final c = data?.m('counts');
    return TeamPage(
      env: env,
      title: 'Staff tasks',
      subtitle: 'Assign, track, and verify team work',
      onRefresh: load,
      bottom: data != null && data!.b('can_create')
          ? LimeButton(
              'Create task',
              onPressed: () => _go(TaskFormScreen(env: env)),
            )
          : null,
      children: [
        TeamChips(
          items: [
            ('all', 'All', c?.n('all')),
            ('in_progress', 'In progress', c?.n('in_progress')),
            ('overdue', 'Overdue', c?.n('overdue')),
            ('done', 'Done', c?.n('done')),
          ],
          active: _filter,
          onTap: (id) {
            setState(() => _filter = id);
            load();
          },
        ),
        TeamLoad<Facts>(
          data: data,
          error: error,
          onRetry: load,
          builder: (d) {
            final items = d.l('items');
            if (items.isEmpty) {
              return [
                OrderCardBox(
                  child: Text(
                    'No tasks here.',
                    style: inter(14, 400, color: kMuted),
                  ),
                ),
              ];
            }
            return [
              for (final t in items)
                _TaskCard(
                  t,
                  onTap: () => _go(TaskDetailScreen(env: env, id: t.s('id'))),
                ),
            ];
          },
        ),
      ],
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard(this.t, {required this.onTap});
  final Facts t;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final (label, bg, fg) = taskStatus(t.s('display_status'));
    final who = [
      t.s('assignee_name'),
      t.s('assignee_role'),
    ].where((s) => s.isNotEmpty).join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Semantics(
        button: true,
        label:
            '${t.s('title')}, ${who.isEmpty ? 'not assigned' : who}, ${dueLine(t)}, $label',
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: kTileLine),
              ),
              child: ExcludeSemantics(
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            t.s('title'),
                            style: inter(16, 600),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            who.isEmpty ? 'Not assigned' : who,
                            style: inter(13, 400, color: kMuted),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            dueLine(t),
                            style: inter(
                              12.5,
                              400,
                              color: t.b('overdue') ? kBadText : kMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: bg,
                        borderRadius: BorderRadius.circular(99),
                      ),
                      child: Text(label, style: inter(12.5, 600, color: fg)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One task: what it is, who has it, its story, and the buttons the server allows for this person right now.
class TaskDetailScreen extends StatefulWidget {
  const TaskDetailScreen({super.key, required this.env, required this.id});
  final TeamEnv env;
  final String id;
  @override
  State<TaskDetailScreen> createState() => _TaskDetailState();
}

class _TaskDetailState extends State<TaskDetailScreen>
    with TeamLoader<TaskDetailScreen, Facts> {
  TeamEnv get env => widget.env;
  bool _busy = false;
  @override
  Future<Facts> fetch() => env.api.task(widget.id);
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<String?> _ask(String title, String hint, {bool required = false}) {
    final c = TextEditingController();
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          20 + MediaQuery.viewInsetsOf(ctx).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: inter(18, 700)),
            const SizedBox(height: 12),
            TeamField(label: hint, controller: c, action: TextInputAction.done),
            DarkCta(
              label: 'Continue',
              onPressed: () {
                if (required && c.text.trim().isEmpty) return;
                Navigator.of(ctx).pop(c.text.trim());
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _act(
    Facts t,
    String action, {
    String? note,
    String? staffId,
  }) async {
    setState(() => _busy = true);
    try {
      final r = await env.api.taskAct(
        t.s('id'),
        action,
        version: t.n('version').toInt(),
        note: note,
        assigneeStaffId: staffId,
      );
      if (!mounted) return;
      if (action == 'cancel') {
        Navigator.of(context).pop();
        return;
      }
      setState(() {
        data = r;
        _busy = false;
      });
    } on TeamApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(
        context,
        e.stale ? 'Someone changed this task. Showing the latest.' : e.message,
      );
      if (e.stale) load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, errorText(e));
    }
  }

  Future<void> _reassign(Facts t) async {
    final o = await env.api.options();
    if (!mounted) return;
    final staff = o.l('staff');
    final v = await pickOne<String>(context, 'Assign to', [
      for (final s in staff)
        (
          s.s('id'),
          s.s('name'),
          s.s('designation').isEmpty ? null : s.s('designation'),
        ),
    ], current: t.s('assignee_staff_id'));
    if (v != null && mounted) await _act(t, 'reassign', staffId: v);
  }

  @override
  Widget build(BuildContext context) => TeamPage(
    env: env,
    title: 'Task',
    subtitle: 'Details and history',
    onRefresh: load,
    children: [
      TeamLoad<Facts>(data: data, error: error, onRetry: load, builder: _body),
    ],
  );

  List<Widget> _body(Facts t) {
    final (label, bg, fg) = taskStatus(t.s('display_status'));
    final a = t.ls('allowed_actions');
    final who = [
      t.s('assignee_name'),
      t.s('assignee_role'),
    ].where((s) => s.isNotEmpty).join(' · ');
    return [
      OrderCardBox(
        padding: const EdgeInsets.all(16),
        child: SizedBox(
          width: double.infinity,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.s('title'), style: inter(19, 600)),
              const SizedBox(height: 6),
              Text(
                who.isEmpty ? 'Not assigned' : who,
                style: inter(13.5, 400, color: kMuted),
              ),
              const SizedBox(height: 4),
              Text(
                dueLine(t),
                style: inter(
                  13,
                  400,
                  color: t.b('overdue') ? kBadText : kMuted,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                children: [
                  DotChip(label, bg: bg, fg: fg),
                  DotChip(
                    '${t.s('priority')[0].toUpperCase()}${t.s('priority').substring(1)} priority',
                  ),
                  if (t.b('approval_required')) const DotChip('Needs approval'),
                ],
              ),
              if (t.s('description').isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(t.s('description'), style: inter(14, 400, height: 1.4)),
              ],
              if (t.s('evidence_note').isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  'Note: ${t.s('evidence_note')}',
                  style: inter(13.5, 400, color: kMuted),
                ),
              ],
              if (t.s('failure_reason').isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  'Failed: ${t.s('failure_reason')}',
                  style: inter(13.5, 400, color: kBadText),
                ),
              ],
            ],
          ),
        ),
      ),
      const SizedBox(height: 14),
      if (a.contains('start'))
        LimeButton(
          'Start task',
          busy: _busy,
          onPressed: () => _act(t, 'start'),
        ),
      if (a.contains('submit'))
        LimeButton(
          'Mark as done',
          busy: _busy,
          onPressed: () async {
            final n = await _ask(
              'Mark as done',
              'What was done?',
              required: t.b('photo_required'),
            );
            if (n != null && mounted) {
              _act(t, 'submit', note: n.isEmpty ? null : n);
            }
          },
        ),
      if (a.contains('complete'))
        LimeButton(
          'Approve',
          busy: _busy,
          onPressed: () => _act(t, 'complete'),
        ),
      if (a.contains('reassign')) ...[
        const SizedBox(height: 8),
        OutlineButton2('Reassign', busy: _busy, onPressed: () => _reassign(t)),
      ],
      if (a.contains('edit')) ...[
        const SizedBox(height: 8),
        OutlineButton2(
          'Edit task',
          busy: _busy,
          onPressed: () async {
            await env.push(context, TaskFormScreen(env: env, task: t));
            if (mounted) load();
          },
        ),
      ],
      if (a.contains('fail')) ...[
        const SizedBox(height: 8),
        OutlineButton2(
          'Mark as failed',
          danger: true,
          busy: _busy,
          onPressed: () async {
            final n = await _ask(
              'Mark as failed',
              'Why did it fail?',
              required: true,
            );
            if (n != null && n.isNotEmpty && mounted) _act(t, 'fail', note: n);
          },
        ),
      ],
      if (a.contains('cancel')) ...[
        const SizedBox(height: 8),
        OutlineButton2(
          'Cancel task',
          danger: true,
          busy: _busy,
          onPressed: () => _act(t, 'cancel'),
        ),
      ],
      const SizedBox(height: 18),
      Text('History', style: inter(17, 600)),
      const SizedBox(height: 10),
      for (final e in t.l('events'))
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: OrderCardBox(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: double.infinity,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${_ev(e.s('event'))} · ${e.s('actor')}',
                    style: inter(14, 600),
                  ),
                  Text(
                    e.t('at') == null ? '' : whenLabel(e.t('at')!),
                    style: inter(12, 400, color: kMuted),
                  ),
                  if (e.s('note').isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        e.s('note'),
                        style: inter(13, 400, color: kMuted),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
    ];
  }

  static String _ev(String e) => switch (e) {
    'created' => 'Created',
    'edited' => 'Edited',
    'started' => 'Started',
    'submitted' => 'Marked as done',
    'completed' => 'Completed',
    'failed' => 'Failed',
    'reassigned' => 'Reassigned',
    'cancelled' => 'Cancelled',
    _ => e,
  };
}

/// Create (or edit) a task. Title, who, when, priority, whether a manager must approve it.
class TaskFormScreen extends StatefulWidget {
  const TaskFormScreen({super.key, required this.env, this.task});
  final TeamEnv env;
  final Facts? task;
  @override
  State<TaskFormScreen> createState() => _TaskFormState();
}

class _TaskFormState extends State<TaskFormScreen> {
  TeamEnv get env => widget.env;
  late final _title = TextEditingController(text: widget.task?.s('title'));
  late final _desc = TextEditingController(text: widget.task?.s('description'));
  late String _priority = widget.task?.so('priority') ?? 'medium';
  late bool _approval = widget.task?.b('approval_required') ?? false;
  late DateTime? _due = widget.task?.t('due_at');
  String? _staffId, _staffName, _error;
  bool _busy = false;
  String? _key;

  @override
  void initState() {
    super.initState();
    _staffId = widget.task?.so('assignee_staff_id');
    _staffName = widget.task?.so('assignee_name');
    if (_staffName != null && _staffName!.isEmpty) _staffName = null;
  }

  @override
  void dispose() {
    _title.dispose();
    _desc.dispose();
    super.dispose();
  }

  Future<void> _pickStaff() async {
    final o = await env.api.options();
    if (!mounted) return;
    final staff = o.l('staff');
    final v = await pickOne<String>(context, 'Assign to', [
      for (final s in staff)
        (
          s.s('id'),
          s.s('name'),
          s.s('designation').isEmpty ? null : s.s('designation'),
        ),
    ], current: _staffId);
    if (v == null) return;
    setState(() {
      _staffId = v;
      _staffName = staff.firstWhere((s) => s.s('id') == v).s('name');
    });
  }

  Future<void> _pickDue() async {
    final now = DateTime.now();
    final day = await showDatePicker(
      context: context,
      initialDate: _due ?? now,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (day == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(
        _due ?? now.add(const Duration(hours: 2)),
      ),
    );
    if (time == null) return;
    setState(
      () =>
          _due = DateTime(day.year, day.month, day.day, time.hour, time.minute),
    );
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    _key ??= TeamApi.newKey();
    try {
      await env.api.saveTask(
        id: widget.task?.so('id'),
        version: widget.task?.n('version').toInt(),
        title: _title.text,
        description: _desc.text,
        priority: _priority,
        assigneeStaffId: _staffId,
        dueAt: _due,
        approvalRequired: _approval,
        key: _key,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = errorText(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) => TeamPage(
    env: env,
    title: widget.task == null ? 'Create task' : 'Edit task',
    subtitle: 'Say what needs doing and who does it',
    bottom: LimeButton(
      widget.task == null ? 'Create task' : 'Save task',
      busy: _busy,
      onPressed: _save,
    ),
    children: [
      if (_error != null)
        TeamBanner(
          title: 'Task couldn\'t be saved',
          body: _error!,
          onClose: () => setState(() => _error = null),
        ),
      TeamField(label: 'Task', controller: _title, hint: 'What needs doing'),
      TeamField(label: 'Details (optional)', controller: _desc),
      TeamSelect(
        label: 'Assign to',
        value: _staffName,
        placeholder: 'Choose a person',
        onTap: _pickStaff,
      ),
      TeamSelect(
        label: 'Due',
        value: _due == null
            ? null
            : '${_due!.day.toString().padLeft(2, '0')}/${_due!.month.toString().padLeft(2, '0')} · ${clock12(_due!)}',
        placeholder: 'No due time',
        onTap: _pickDue,
      ),
      TeamChips(
        items: const [
          ('low', 'Low', null),
          ('medium', 'Medium', null),
          ('high', 'High', null),
        ],
        active: _priority,
        onTap: (p) => setState(() => _priority = p),
      ),
      SwitchListTile(
        value: _approval,
        onChanged: (v) => setState(() => _approval = v),
        title: Text('A manager approves it when done', style: inter(14.5, 500)),
        activeTrackColor: kGreenDeep,
        contentPadding: EdgeInsets.zero,
      ),
    ],
  );
}
