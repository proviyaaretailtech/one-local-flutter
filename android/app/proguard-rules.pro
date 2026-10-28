# ML Kit text recognition (PAN card check, 28 Oct 2026): only the Latin script is used. The plugin also names the Chinese, Devanagari,
# Japanese and Korean script packs, which are not added to keep the APK small, so the release shrinker (R8) is told not to look for them.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
