import 'package:flutter/material.dart';

import '../inventory/inventory_api.dart' show Facts;
import '../orders/order_widgets.dart';
import '../states/state_kit.dart' show InfoBox;
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
      final roles = data?.l('roles') ?? const <Facts>[];
      if (roles.isNotEmpty) _pick(roles.first.s('slug'));
    });
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
          return [
            TeamChips(
              items: [for (final r in roles) (r.s('slug'), r.s('name'), null)],
              active: _slug ?? '',
              onTap: _pick,
            ),
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
            Text(
              r.s('description').isEmpty
                  ? '${r.n('permission_count')} permissions in total'
                  : '${r.s('description')} · ${r.n('permission_count')} permissions',
              style: inter(13.5, 400, color: kMuted),
            ),
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
    const SizedBox(height: 4),
    InfoBox(lines: [r.s('note')]),
  ];
}
