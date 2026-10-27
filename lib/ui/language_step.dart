import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'i18n.dart';
import 'theme.dart';

const _langKey = 'app_lang', _chosenForKey = 'lang_chosen_for', _beforeSignUpKey = 'lang_chosen_before_sign_up';

/// The language this phone last chose, applied as the app opens (before any screen), so it starts in it.
Future<void> restoreAppLanguage() async {
  try {
    final code = (await SharedPreferences.getInstance()).getString(_langKey);
    if (code != null) setAppLanguage(code);
  } catch (_) {} // English
}

/// Whether [userId] still has to choose a language on this phone. False when the phone cannot keep it (then nobody is held up).
Future<bool> languageStepNeeded(String? userId) async {
  if (userId == null) return false;
  try {
    final p = await SharedPreferences.getInstance();
    if (p.getBool(_beforeSignUpKey) == true) {
      // chosen on "Sign In" or "Become a seller", before the account was known: it belongs to this one
      await p.remove(_beforeSignUpKey);
      await p.setString(_chosenForKey, userId);
      return false;
    }
    return p.getString(_chosenForKey) != userId;
  } catch (_) {
    return false;
  }
}

Future<void> _remember(String code, String? userId) async {
  try {
    final p = await SharedPreferences.getInstance();
    await p.setString(_langKey, code);
    if (userId != null) await p.setString(_chosenForKey, userId);
  } catch (_) {}
}

/// "Sign In" and "Become a seller" (founder, 27 Oct 2026): the language first, then [next] (how to sign in, or name and mobile).
/// The choice is kept for the account that signs in or is made next, so it is not asked again after the code or password.
Route<void> languageThen(Widget next) => MaterialPageRoute(
      builder: (context) => LanguageStepScreen(onChosen: (code) async {
        try {
          final p = await SharedPreferences.getInstance();
          await p.setString(_langKey, code);
          await p.setBool(_beforeSignUpKey, true);
        } catch (_) {}
        if (context.mounted) await Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => next));
      }),
    );

/// First thing after signing in (founder, 27 Oct 2026): choose English, हिन्दी or Hinglish, once per account on each phone. Then
/// [child] (the welcome screen, or the application for a new partner). [saveToStore] also keeps it for the store, when there is one.
class LanguageGate extends StatefulWidget {
  const LanguageGate({super.key, required this.userId, required this.child, this.saveToStore});
  final String? userId;
  final Widget child;
  final Future<void> Function(String code)? saveToStore;
  @override
  State<LanguageGate> createState() => _LanguageGateState();
}

class _LanguageGateState extends State<LanguageGate> {
  late final Future<bool> _needed = languageStepNeeded(widget.userId);
  bool _done = false;

  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
        future: _needed,
        builder: (context, snap) {
          if (_done || snap.data == false) return widget.child;
          if (!snap.hasData) return const Scaffold(body: Center(child: CircularProgressIndicator(color: kLink)));
          return LanguageStepScreen(onChosen: (code) async {
            await _remember(code, widget.userId);
            try {
              await widget.saveToStore?.call(code);
            } catch (_) {} // no store yet, or a role that may not change it: this phone keeps it
            if (mounted) setState(() => _done = true);
          });
        },
      );
}

/// Three big choices, each in its own words, and Continue.
class LanguageStepScreen extends StatefulWidget {
  const LanguageStepScreen({super.key, required this.onChosen});
  final Future<void> Function(String code) onChosen;
  @override
  State<LanguageStepScreen> createState() => _LanguageStepScreenState();
}

class _LanguageStepScreenState extends State<LanguageStepScreen> {
  String _code = appLang.value;
  bool _busy = false;

  @override
  Widget build(BuildContext context) => ScreenShell(
        gradient: kRegistrationGradient,
        children: [
          const BrandNav(),
          FormContent(children: [
            Kicker(tr('Language')),
            PageIntro(title: tr('Choose your language'), subtitle: tr('The app will use it everywhere. You can change it later in Settings.')),
            Column(key: const ValueKey('language-step'), children: [
              for (final (code, label, sample) in const [('en', 'English', 'Hello! Let’s get started.'), ('hi', 'हिन्दी', 'नमस्ते! चलिए शुरू करें।'), ('hi-en', 'Hinglish', 'Namaste! Chaliye shuru karein.')]) ...[
                Material(
                  color: _code == code ? const Color(0xFFA1FE2F) : Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: _code == code ? const Color(0xFF8BE800) : kLine, width: 1.5)),
                  child: InkWell(
                    key: ValueKey('login-language-$code'),
                    borderRadius: BorderRadius.circular(18),
                    onTap: () {
                      setAppLanguage(code); // the screen switches at once, so the choice can be seen
                      setState(() => _code = code);
                    },
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(18, 16, 16, 16),
                      child: Row(children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(label, style: inter(20, 700)),
                            const SizedBox(height: 2),
                            Text(sample, style: inter(13.5, 400, color: kMuted)),
                          ]),
                        ),
                        Icon(_code == code ? Icons.check_circle : Icons.circle_outlined, color: _code == code ? kInk : kMuted),
                      ]),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ]),
          ]),
        ],
        actions: [
          PrimaryAction(
            key: const ValueKey('language-continue'),
            label: _busy ? '…' : tr('Continue'),
            onPressed: _busy
                ? null
                : () async {
                    setState(() => _busy = true);
                    await widget.onChosen(_code);
                    if (mounted) setState(() => _busy = false);
                  },
          ),
        ],
      );
}
