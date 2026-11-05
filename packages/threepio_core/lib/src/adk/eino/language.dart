/// The language of the prompts the ADK writes itself.
///
/// Port of eino `adk/config.go` and `adk/internal/config.go`.
library;

import 'package:meta/meta.dart';

/// The language of the prompts the ADK's built-in middlewares and tools use.
///
/// Port of eino `adk.Language`.
enum AdkLanguage {
  /// English, the default. Port of eino `adk.LanguageEnglish`.
  english,

  /// Chinese. Port of eino `adk.LanguageChinese`.
  chinese,
}

AdkLanguage _language = AdkLanguage.english;

/// Sets the language of the ADK's built-in prompts for the whole process.
///
/// Port of eino `adk.SetLanguage`. English when it is never set.
void setAdkLanguage(AdkLanguage language) => _language = language;

/// The language set with [setAdkLanguage].
AdkLanguage get adkLanguage => _language;

/// A prompt in both languages. Port of eino `internal.I18nPrompts`.
@internal
final class I18nPrompts {
  /// The [english] and [chinese] texts of one prompt.
  const I18nPrompts({required this.english, required this.chinese});

  /// The English text.
  final String english;

  /// The Chinese text.
  final String chinese;
}

/// The text of [prompts] in the current language. Port of eino
/// `internal.SelectPrompt`.
@internal
String selectPrompt(I18nPrompts prompts) => switch (_language) {
      AdkLanguage.english => prompts.english,
      AdkLanguage.chinese => prompts.chinese,
    };
