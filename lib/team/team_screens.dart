import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_api.dart' show Facts;
import '../inventory/inventory_widgets.dart' show pickOne;
import '../orders/order_widgets.dart';
import '../ui/theme.dart';
import 'activity_tasks_screens.dart';
import 'roles_screen.dart';
import 'team_api.dart';
import 'team_widgets.dart';

/// Loads one answer and keeps it for the screen; every Team screen uses the same three-state pattern (loading, error with retry, content).
mixin TeamLoader<W extends StatefulWidget, T> on State<W> {
  T? data;
  String? error;
  Future<T> fetch();

  Future<void> load() async {
    try {
      final d = await fetch();
      if (!mounted) return;
      setState(() {
        data = d;
        error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => error = errorText(e));
    }
  }
}

/// "Role · Place" line of a person.
String personSub(Facts p) => '${p.m('role').s('name')} · ${p.s('place_text')}';

/// Figma "Team Dashboard": counts, quick actions, who is on shift.
class TeamDashboardScreen extends StatefulWidget {
  const TeamDashboardScreen({super.key, required this.env});
  final TeamEnv env;
  static const routeName = '/team';
  static Route<void> route(TeamEnv env) => MaterialPageRoute(
    settings: const RouteSettings(name: routeName),
    builder: (_) => TeamDashboardScreen(env: env),
  );
  @override
  State<TeamDashboardScreen> createState() => _TeamDashboardState();
}

class _TeamDashboardState extends State<TeamDashboardScreen>
    with TeamLoader<TeamDashboardScreen, Facts> {
  TeamEnv get env => widget.env;
  @override
  Future<Facts> fetch() => env.api.dashboard();
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
  Widget build(BuildContext context) => TeamPage(
    env: env,
    title: 'Team dashboard',
    subtitle: data == null
        ? null
        : '${data!.n('members')} staff · ${data!.n('locations')} ${data!.n('locations') == 1 ? 'location' : 'locations'}${data!.s('place').isEmpty ? '' : ' · ${data!.s('place')}'}',
    onRefresh: load,
    children: [
      TeamLoad<Facts>(data: data, error: error, onRetry: load, builder: _body),
    ],
  );

  List<Widget> _body(Facts d) {
    final members = d.n('members').toInt(), active = d.n('active_now').toInt();
    return [
      Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: kChipGreen,
            borderRadius: BorderRadius.circular(99),
          ),
          child: Text(
            'LIVE · $active ACTIVE NOW',
            style: inter(11.5, 600, color: kGreenDeep),
          ),
        ),
      ),
      const SizedBox(height: 12),
      GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 2.3, // Figma's tiles are short: number beside a two-line label, no empty space below
        children: [
          StatTile(
            value: '$members',
            label: 'Team members',
            note:
                'Across ${d.n('locations')} ${d.n('locations') == 1 ? 'location' : 'locations'}',
            onTap: () => _go(UsersScreen(env: env)),
          ),
          StatTile(
            value: '$active',
            label: 'Active now',
            note: 'On shift today',
            color: kGreenDeep,
            onTap: () => _go(UsersScreen(env: env, filter: 'active')),
          ),
          StatTile(
            value: '${d.n('invitations')}',
            label: 'Invitations',
            note: 'Awaiting response',
            color: kAmber,
            onTap: () => _go(UsersScreen(env: env, filter: 'invited')),
          ),
          StatTile(
            value: '${d.n('tasks_due')}',
            label: 'Tasks due',
            note: 'Needs attention',
            color: kBadText,
            onTap: () => _go(TasksScreen(env: env, filter: 'overdue')),
          ),
        ],
      ),
      const SizedBox(height: 18),
      Text('Quick actions', style: inter(17, 600)),
      const SizedBox(height: 10),
      if (d.b('can_invite'))
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: LimeButton(
            'Invite team member',
            onPressed: () => _go(InviteScreen(env: env)),
          ),
        ),
      LightCta(
        label: 'Staff tasks',
        icon: LucideIcons.listChecks,
        onPressed: () => _go(TasksScreen(env: env)),
      ),
      const SizedBox(height: 8),
      LightCta(
        label: 'Staff activity',
        icon: LucideIcons.activity,
        onPressed: () => _go(ActivityScreen(env: env)),
      ),
      const SizedBox(height: 8),
      LightCta(
        label: 'Roles & permissions',
        icon: LucideIcons.shieldCheck,
        onPressed: () => _go(RolesScreen(env: env)),
      ),
      const SizedBox(height: 18),
      Text('Team on shift', style: inter(17, 600)),
      const SizedBox(height: 10),
      if (d.l('on_shift').isEmpty)
        OrderCardBox(
          child: Text(
            'Nobody has clocked in today.',
            style: inter(14, 400, color: kMuted),
          ),
        ),
      for (final s in d.l('on_shift'))
        PersonCard(
          name: s.s('name'),
          initials: s.s('initials'),
          sub: '${s.s('designation')} · ${s.s('place')}',
          status: 'active',
        ),
      const SizedBox(height: 4),
      Semantics(
        button: true,
        label: 'View all $members members',
        child: InkWell(
          onTap: () => _go(UsersScreen(env: env)),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: ExcludeSemantics(
              child: Text(
                'View all $members members →',
                style: inter(14, 600, color: kGreenDeep),
              ),
            ),
          ),
        ),
      ),
    ];
  }
}

/// Figma "Users": everyone who can sign in or has been invited, with search and filters.
class UsersScreen extends StatefulWidget {
  const UsersScreen({super.key, required this.env, this.filter = 'all'});
  final TeamEnv env;
  final String filter;
  @override
  State<UsersScreen> createState() => _UsersState();
}

class _UsersState extends State<UsersScreen>
    with TeamLoader<UsersScreen, Facts> {
  TeamEnv get env => widget.env;
  late String _filter = widget.filter;
  final _q = TextEditingController();

  @override
  Future<Facts> fetch() => env.api.users(filter: _filter, q: _q.text);
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
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
      title: 'Users',
      subtitle: 'Manage access across your locations',
      onRefresh: load,
      bottom: data != null && data!.b('can_invite')
          ? LimeButton(
              'Invite user',
              onPressed: () => _go(InviteScreen(env: env)),
            )
          : null,
      children: [
        TextField(
          controller: _q,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => load(),
          style: inter(15, 400),
          decoration: InputDecoration(
            hintText: 'Search name, email or number',
            hintStyle: inter(15, 400, color: kKicker),
            prefixIcon: const Icon(LucideIcons.search, size: 20, color: kMuted),
            filled: true,
            fillColor: Colors.white,
            contentPadding: const EdgeInsets.symmetric(vertical: 14),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(99),
              borderSide: const BorderSide(color: kTileLine),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(99),
              borderSide: const BorderSide(color: kInk),
            ),
          ),
        ),
        const SizedBox(height: 12),
        TeamChips(
          items: [
            ('all', 'All', c?.n('all')),
            ('active', 'Active', c?.n('active')),
            ('invited', 'Invited', c?.n('invited')),
            ('paused', 'Paused', c?.n('paused')),
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
                    _q.text.isEmpty
                        ? 'Nobody here yet.'
                        : 'No one matches that search.',
                    style: inter(14, 400, color: kMuted),
                  ),
                ),
              ];
            }
            return [
              for (final p in items)
                PersonCard(
                  name: p.s('name'),
                  initials: p.s('initials'),
                  sub: personSub(p),
                  status: p.s('status'),
                  onTap: () => _go(UserDetailScreen(env: env, id: p.s('id'))),
                ),
            ];
          },
        ),
      ],
    );
  }
}

/// Figma "Invite User" and "Invite User · Validation Error". The server decides what is valid; a refused number or email is shown under its field.
class InviteScreen extends StatefulWidget {
  const InviteScreen({super.key, required this.env});
  final TeamEnv env;
  @override
  State<InviteScreen> createState() => _InviteState();
}

class _InviteState extends State<InviteScreen> {
  TeamEnv get env => widget.env;
  final _name = TextEditingController(),
      _mobile = TextEditingController(),
      _email = TextEditingController();
  Facts? _options;
  String? _loadError, _role, _roleName, _location, _locationName;
  bool _busy = false;
  String? _bannerBody, _mobileError, _emailError;
  bool _canResend = false;

  @override
  void initState() {
    super.initState();
    _loadOptions();
  }

  @override
  void dispose() {
    _name.dispose();
    _mobile.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _loadOptions() async {
    try {
      final o = await env.api.options();
      if (!mounted) return;
      setState(() {
        _options = o;
        _loadError = null;
        final locs = o.l('locations');
        if (locs.length == 1) {
          _location = locs.first.s('id');
          _locationName = locs.first.s('name');
        }
      });
    } catch (e) {
      if (mounted) setState(() => _loadError = errorText(e));
    }
  }

  Future<void> _pickRole() async {
    final roles = _options!.l('roles');
    final v = await pickTeamRole(context, title: 'Role', roles: roles, current: _role, kind: env.kind);
    if (v != null) {
      setState(() {
        _role = v;
        _roleName = roles.firstWhere((r) => r.s('slug') == v).s('name');
      });
    }
  }

  Future<void> _pickLocation() async {
    final locs = _options!.l('locations');
    final v = await pickOne<String>(context, 'Location', [
      for (final l in locs) (l.s('id'), l.s('name'), null),
    ], current: _location);
    if (v != null) {
      setState(() {
        _location = v;
        _locationName = locs.firstWhere((l) => l.s('id') == v).s('name');
      });
    }
  }

  Future<void> _send({bool resend = false}) async {
    setState(() {
      _busy = true;
      _bannerBody = _mobileError = _emailError = null;
    });
    try {
      final r = await env.api.invite(
        fullName: _name.text,
        mobile: _mobile.text,
        email: _email.text,
        roleSlug: _role ?? '',
        locationId: _location,
        resend: resend,
      );
      if (!mounted) return;
      showToast(
        context,
        r.b('resent')
            ? 'Invitation sent again to ${r.s('name')}.'
            : 'Invitation sent to ${r.s('name')}.',
      );
      Navigator.of(context).pop(true);
    } on TeamApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        // Figma's banner also says what to do next when the number or email is already invited.
        _bannerBody = e.duplicateMobile
            ? '${e.message} Resend it or use another number.'
            : e.duplicateEmail
                ? '${e.message} Resend it or use another email.'
                : e.message;
        _mobileError = e.duplicateMobile ? e.message : null;
        _emailError = e.duplicateEmail ? e.message : null;
        _canResend = e.duplicateMobile || e.duplicateEmail;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _bannerBody = errorText(e);
        _canResend = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasError = _bannerBody != null;
    final locs = _options?.l('locations') ?? const <Facts>[];
    return TeamPage(
      env: env,
      title: 'Invite user',
      subtitle: hasError
          ? 'Fix the details and try again'
          : 'They get an invitation to join your team',
      bottom: _options == null
          ? null
          : (_canResend
                ? OutlineButton2(
                    'Resend invitation',
                    busy: _busy,
                    onPressed: () => _send(resend: true),
                  )
                : LimeButton(
                    'Send invitation',
                    busy: _busy,
                    onPressed: () => _send(),
                  )),
      children: [
        if (hasError)
          TeamBanner(
            title: 'Invitation couldn\'t be sent',
            body: _bannerBody!,
            onClose: () => setState(() => _bannerBody = null),
          ),
        if (_loadError != null)
          TeamBanner(title: 'Could not load roles', body: _loadError!),
        TeamField(label: 'Full name', controller: _name, hint: 'e.g. Pooja Nair'),
        TeamField(
          label: 'Mobile number',
          controller: _mobile,
          prefix: '+91',
          keyboard: TextInputType.phone,
          hint: '98765 43210',
          formatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]')),
            LengthLimitingTextInputFormatter(11),
          ],
          error: _mobileError,
        ),
        TeamField(
          label: 'Email address',
          controller: _email,
          keyboard: TextInputType.emailAddress,
          hint: 'name@example.com',
          error: _emailError,
          action: TextInputAction.done,
        ),
        TeamSelect(
          label: 'Role',
          value: _roleName,
          onTap: _options == null ? null : _pickRole,
        ),
        if (locs.length > 1)
          TeamSelect(
            label: 'Location',
            value: _locationName,
            onTap: _pickLocation,
          ),
      ],
    );
  }
}

/// Figma "User Detail" (team member) and its invitation twin: contact, places, role, and what the person may do to them.
class UserDetailScreen extends StatefulWidget {
  const UserDetailScreen({super.key, required this.env, required this.id});
  final TeamEnv env;
  final String id;
  @override
  State<UserDetailScreen> createState() => _UserDetailState();
}

class _UserDetailState extends State<UserDetailScreen>
    with TeamLoader<UserDetailScreen, Facts> {
  TeamEnv get env => widget.env;
  bool _busy = false;
  @override
  Future<Facts> fetch() => env.api.user(widget.id);
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> _run(Future<Facts> Function() act, String done) async {
    setState(() => _busy = true);
    try {
      final r = await act();
      if (!mounted) return;
      setState(() {
        data = r;
        _busy = false;
      });
      showToast(context, done);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, errorText(e));
    }
  }

  Future<void> _editRole(Facts d) async {
    final o = await env.api.options();
    if (!mounted) return;
    final roles = o.l('roles').where((r) => r.b('assignable')).toList();
    final v = await pickTeamRole(context, title: 'Edit role', roles: roles, current: d.m('role').s('slug'), kind: env.kind);
    if (v == null || v == d.m('role').s('slug') || !mounted) return;
    final role = roles.firstWhere((r) => r.s('slug') == v);
    List<String>? places;
    if (role.b('location_bound') && d.l('places').isEmpty) {
      final locs = o.l('locations');
      final loc = await pickOne<String>(
        context,
        'Location for ${role.s('name')}',
        [for (final l in locs) (l.s('id'), l.s('name'), null)],
      );
      if (loc == null || !mounted) return;
      places = [loc];
    }
    await _run(
      () => env.api.userAct(
        d.s('id'),
        'set_role',
        roleSlug: v,
        locationIds: places,
      ),
      'Role changed to ${role.s('name')}.',
    );
  }

  Future<void> _editPlaces(Facts d) async {
    final o = await env.api.options();
    if (!mounted) return;
    final locs = o.l('locations');
    final chosen = {for (final p in d.l('places')) p.s('id')};
    final result = await showModalBottomSheet<Set<String>>(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Location access', style: inter(18, 700)),
                const SizedBox(height: 6),
                for (final l in locs)
                  CheckboxListTile(
                    value: chosen.contains(l.s('id')),
                    onChanged: (v) => set(
                      () => v == true
                          ? chosen.add(l.s('id'))
                          : chosen.remove(l.s('id')),
                    ),
                    title: Text(l.s('name'), style: inter(15, 500)),
                    activeColor: kInk,
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                  ),
                const SizedBox(height: 8),
                LimeButton(
                  'Save',
                  onPressed: () => Navigator.of(ctx).pop(chosen),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (result == null || !mounted) return;
    await _run(
      () => env.api.userAct(
        d.s('id'),
        'set_locations',
        locationIds: result.toList(),
      ),
      'Location access saved.',
    );
  }

  Future<void> _confirm(
    String title,
    String body,
    String yes,
    Future<void> Function() go,
  ) async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: inter(18, 700)),
              const SizedBox(height: 8),
              Text(body, style: inter(14.5, 400, color: kMuted, height: 1.4)),
              const SizedBox(height: 16),
              DarkCta(label: yes, onPressed: () => Navigator.of(ctx).pop(true)),
              const SizedBox(height: 8),
              LightCta(
                label: 'Cancel',
                onPressed: () => Navigator.of(ctx).pop(false),
              ),
            ],
          ),
        ),
      ),
    );
    if (ok == true) await go();
  }

  @override
  Widget build(BuildContext context) => TeamPage(
    env: env,
    title: data?.s('kind') == 'invitation' ? 'Invitation' : 'Team member',
    subtitle: data?.s('kind') == 'invitation'
        ? 'Waiting for them to accept'
        : 'Access and activity details',
    onRefresh: load,
    children: [
      TeamLoad<Facts>(data: data, error: error, onRetry: load, builder: _body),
    ],
  );

  List<Widget> _body(Facts d) {
    final (statusLabel, statusBg, statusFg) = personStatus(d.s('status'));
    final actions = d.ls('allowed_actions');
    final places = d.l('places');
    final last = d.t('last_active');
    final isInvite = d.s('kind') == 'invitation';
    return [
      OrderCardBox(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Avatar(d.s('initials'), size: 64),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(d.s('name'), style: inter(20, 600)),
                  const SizedBox(height: 2),
                  Text(
                    d.so('designation') ?? d.m('role').s('name'),
                    style: inter(14, 400, color: kMuted),
                  ),
                  const SizedBox(height: 8),
                  DotChip(
                    statusLabel.toUpperCase(),
                    bg: statusBg,
                    fg: statusFg,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 10),
      OrderCardBox(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('CONTACT', style: inter(11, 600, color: kMuted)),
            const SizedBox(height: 6),
            Text(
              d.so('mobile') == null || d.s('mobile').isEmpty
                  ? 'No number on file'
                  : _mobile(d.s('mobile')),
              style: inter(15, 600),
            ),
            const SizedBox(height: 4),
            Text(d.s('email'), style: inter(13, 400, color: kMuted)),
          ],
        ),
      ),
      const SizedBox(height: 10),
      Semantics(
        button: actions.contains('set_locations'),
        label: 'Location access',
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: actions.contains('set_locations')
              ? () => _editPlaces(d)
              : null,
          child: OrderCardBox(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Location access', style: inter(16, 600)),
                  const SizedBox(height: 6),
                  Text(
                    places.isEmpty
                        ? 'All locations'
                        : places.map((p) => p.s('name')).join(' · '),
                    style: inter(13.5, 400, color: kMuted),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      const SizedBox(height: 10),
      OrderCardBox(
        padding: const EdgeInsets.all(16),
        child: SizedBox(
          width: double.infinity,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Role & permissions', style: inter(16, 600)),
              const SizedBox(height: 6),
              Text(
                '${d.m('role').s('name')} · ${d.n('permission_count')} permissions enabled',
                style: inter(13.5, 400, color: kMuted),
              ),
              if (!isInvite) ...[
                const SizedBox(height: 10),
                Text(
                  last == null
                      ? 'No activity yet'
                      : 'Last active ${_lastActive(last)}',
                  style: inter(13.5, 400, color: kMuted),
                ),
              ] else if (d.t('expires_at') != null) ...[
                const SizedBox(height: 10),
                Text(
                  'Invitation sent ${d.n('send_count')} ${d.n('send_count') == 1 ? 'time' : 'times'}',
                  style: inter(13.5, 400, color: kMuted),
                ),
              ],
            ],
          ),
        ),
      ),
      const SizedBox(height: 18),
      if (actions.contains('set_role'))
        LimeButton('Edit role', busy: _busy, onPressed: () => _editRole(d)),
      if (actions.contains('suspend')) ...[
        const SizedBox(height: 10),
        OutlineButton2(
          'Suspend access',
          danger: true,
          busy: _busy,
          onPressed: () => _confirm(
            'Suspend ${d.s('name')}?',
            'They will not be able to open this business until you restore access.',
            'Suspend access',
            () => _run(
              () => env.api.userAct(d.s('id'), 'suspend'),
              'Access suspended.',
            ),
          ),
        ),
      ],
      if (actions.contains('reactivate'))
        LimeButton(
          'Restore access',
          busy: _busy,
          onPressed: () => _run(
            () => env.api.userAct(d.s('id'), 'reactivate'),
            'Access restored.',
          ),
        ),
      if (actions.contains('resend'))
        LimeButton(
          'Resend invitation',
          busy: _busy,
          onPressed: () => _run(
            () => env.api.inviteAct(d.s('id'), 'resend'),
            'Invitation sent again.',
          ),
        ),
      if (actions.contains('revoke')) ...[
        const SizedBox(height: 10),
        OutlineButton2(
          'Withdraw invitation',
          danger: true,
          busy: _busy,
          onPressed: () => _confirm(
            'Withdraw this invitation?',
            'The link they were sent will stop working.',
            'Withdraw invitation',
            () async {
              setState(() => _busy = true);
              try {
                await env.api.inviteAct(d.s('id'), 'revoke');
                if (mounted) Navigator.of(context).pop();
              } catch (e) {
                if (mounted) {
                  setState(() => _busy = false);
                  showToast(context, errorText(e));
                }
              }
            },
          ),
        ),
      ],
    ];
  }

  static String _mobile(String m) =>
      m.length == 10 ? '+91 ${m.substring(0, 5)} ${m.substring(5)}' : m;

  String _lastActive(DateTime t) {
    final w = whenLabel(t);
    return w.contains('·') ? w : 'today at $w';
  }
}
