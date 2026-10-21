import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../inventory/inventory_api.dart' show Facts;
import '../orders/order_widgets.dart';
import '../ui/theme.dart';
import 'team_screens.dart' show TeamLoader;
import 'team_widgets.dart';

/// Figma "Roles & Permissions". Read only: roles are the same for every business and set by Proviyaa, so the switches show what the role has
/// (from real permission keys) and cannot be flipped; there is no "Save changes". The server says so in `editable` and `note`.
class RolesScreen extends StatefulWidget {
  const RolesScreen({super.key, required this.env});
  final TeamEnv env;
  @override
  State<RolesScreen> createState() => _RolesState();
}

class _RolesState extends State<RolesScreen>
    with TeamLoader<RolesScreen, Facts> {
  TeamEnv get env => widget.env;
  String? _slug;
  Facts? _role;
  String? _roleError;

  @override
  Future<Facts> fetch() => env.api.options();

  @override
  void initState() {
    super.initState();
    load().then((_) {
      // start on the first usual role for this business (Manager), not on Owner or a role that does not fit
      final (:common, :more) = teamRolesFor(data?.l('roles') ?? const <Facts>[], kind: env.kind, onlyAssignable: false);
      final first = [...common, ...more];
      if (first.isNotEmpty) _pick(first.first.s('slug'));
    });
  }

  Future<void> _choose(List<Facts> roles) async {
    final v = await pickTeamRole(context, title: 'Choose a role', roles: roles, current: _slug, kind: env.kind, onlyAssignable: false);
    if (v != null && v != _slug) _pick(v);
  }

  Future<void> _pick(String slug) async {
    setState(() {
      _slug = slug;
      _role = null;
      _roleError = null;
    });
    try {
      final r = await env.api.role(slug);
      if (mounted && _slug == slug) setState(() => _role = r);
    } catch (e) {
      if (mounted && _slug == slug) setState(() => _roleError = errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) => TeamPage(
    env: env,
    title: 'Roles & permissions',
    subtitle: 'Choose a role to review access',
    onRefresh: load,
    children: [
      TeamLoad<Facts>(
        data: data,
        error: error,
        onRetry: load,
        builder: (o) {
          final roles = o.l('roles');
          final name = roles.firstWhere((r) => r.s('slug') == _slug, orElse: () => const Facts({})).s('name');
          return [
            // One full-width field instead of a sideways-scrolling row of small chips: easy to tap and to find every role.
            Semantics(
              button: true,
              label: 'Role: ${name.isEmpty ? 'none' : name}. Change role',
              child: ExcludeSemantics(
                child: Material(
                  color: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: kTileLine)),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => _choose(roles),
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 56),
                      padding: const EdgeInsets.fromLTRB(16, 8, 14, 8),
                      child: Row(children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                            Text('Role', style: inter(12, 500, color: kMuted)),
                            const SizedBox(height: 2),
                            Text(name.isEmpty ? 'Choose a role' : name, style: inter(16, 600)),
                          ]),
                        ),
                        const Icon(LucideIcons.chevronDown, size: 20, color: kInk),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            if (_roleError != null)
              OrderCardBox(
                child: Text(
                  _roleError!,
                  style: inter(14, 400, color: kBadText),
                ),
              ),
            if (_role == null && _roleError == null)
              const Padding(
                padding: EdgeInsets.all(30),
                child: Center(child: CircularProgressIndicator(color: kInk)),
              ),
            if (_role != null)
              ..._roleBody(
                _role!,
                roles.firstWhere(
                  (r) => r.s('slug') == _slug,
                  orElse: () => const Facts({}),
                ),
              ),
          ];
        },
      ),
    ],
  );

  List<Widget> _roleBody(Facts r, Facts summary) => [
    OrderCardBox(
      padding: const EdgeInsets.all(16),
      child: SizedBox(
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(r.s('name'), style: inter(18, 600)),
            const SizedBox(height: 4),
            if (r.s('description').isNotEmpty) Text(r.s('description'), style: inter(13.5, 400, color: kMuted)),
            // Count what the switches below show (5 areas), not the raw permission keys behind them: "7 permissions" next to
            // two switches that are on read as a contradiction.
            Builder(builder: (_) {
              final caps = r.l('capabilities');
              final on = caps.where((c) => c.b('enabled')).length;
              return Text('$on of ${caps.length} areas switched on', style: inter(13.5, 500, color: kInk));
            }),
            if (summary.has('members')) ...[
              const SizedBox(height: 4),
              Text(
                '${summary.n('members')} active ${summary.n('members') == 1 ? 'person' : 'people'} in your team',
                style: inter(13, 400, color: kMuted),
              ),
            ],
          ],
        ),
      ),
    ),
    const SizedBox(height: 14),
    Text('Permissions', style: inter(17, 600)),
    const SizedBox(height: 10),
    for (final c in r.l('capabilities'))
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: OrderCardBox(
          padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(c.s('title'), style: inter(15.5, 600)),
                    const SizedBox(height: 2),
                    Text(c.s('subtitle'), style: inter(13, 400, color: kMuted)),
                  ],
                ),
              ),
              Semantics(
                label:
                    '${c.s('title')}, ${c.b('enabled') ? 'on' : 'off'}, cannot be changed',
                child: ExcludeSemantics(
                  child: Switch(
                    value: c.b('enabled'),
                    onChanged: null,
                    activeThumbColor: Colors.white,
                    activeTrackColor: kGreenDeep,
                    inactiveTrackColor: const Color(0xFFD1D5DB),
                    inactiveThumbColor: Colors.white,
                    trackOutlineColor: const WidgetStatePropertyAll(
                      Colors.transparent,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
  ];
}
