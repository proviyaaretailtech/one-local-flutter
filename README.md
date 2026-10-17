# One Local POS — new mobile Flutter app

Rebuild from Figma `FINAL-PARTNER-APP` section by section. Old app: `Pos flutter/` (archived on `archive/pos-flutter-pre-rebuild`).

Run (local Supabase only):

```bash
flutter run --dart-define-from-file=.env.local
```

Database: the shared canonical schema in `database/migrations` at the workspace root. No new tables here without a migration there.
