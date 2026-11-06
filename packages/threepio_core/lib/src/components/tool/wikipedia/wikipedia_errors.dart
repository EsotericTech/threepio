/// The errors of the Wikipedia search tool.
///
/// Port of eino-ext `components/tool/wikipedia/internal/errors.go`.
library;

import 'package:meta/meta.dart';

import '../../../errors.dart';

/// Which of Go's error values a [WikipediaException] is.
///
/// Port of the sentinel errors of eino-ext
/// `wikipedia/internal/errors.go`; [message] is Go's text.
enum WikipediaErrorKind {
  /// Go `ErrPageNotFound`: the search found nothing, or a page it found does
  /// not exist.
  pageNotFound('page not found'),

  /// Go `ErrInvalidParameters`: the query is empty or only white space.
  invalidParameters('invalid parameters'),

  /// Go `ErrTooManyRedirects`: the API redirected more often than
  /// `WikipediaConfig.maxRedirect` allows.
  tooManyRedirects('too many redirects');

  const WikipediaErrorKind(this.message);

  /// The text of the Go error.
  final String message;
}

/// One of the error values of the Wikipedia search tool.
///
/// Port of `ErrPageNotFound`, `ErrInvalidParameters` and
/// `ErrTooManyRedirects` of eino-ext `wikipedia/internal`. Two exceptions of
/// the same [kind] are equal, as Go compares its error values with
/// `errors.Is`. A [WikipediaErrorKind.tooManyRedirects] reaches the caller
/// as the [ThreepioException.cause] of a `request failed: …` exception (find
/// it with [ThreepioException.findCause]); the other two are thrown as they
/// are.
@immutable
final class WikipediaException extends ThreepioException {
  /// The error value [kind].
  WikipediaException(this.kind) : super(kind.message);

  /// Which error value this is.
  final WikipediaErrorKind kind;

  @override
  bool operator ==(Object other) =>
      other is WikipediaException && other.kind == kind;

  @override
  int get hashCode => kind.hashCode;

  @override
  String toString() => 'WikipediaException: $message';
}

/// An error the Wikipedia API answered with (the `error` member of its
/// answer).
///
/// Port of eino-ext `wikipedia/internal.APIError`; [message] is Go's
/// `Error()` text, `API error: <info> (code: <code>)`.
final class WikipediaApiException extends ThreepioException {
  /// The API error [code] described by [info].
  WikipediaApiException({
    required this.code,
    required this.info,
    this.docRef = '',
  }) : super('API error: $info (code: $code)');

  /// The code of the error, for example `nosrsearch`.
  final String code;

  /// The description of the error.
  final String info;

  /// Where the documentation is (the `docref` member; empty when the API
  /// does not send one).
  final String docRef;

  @override
  String toString() => 'WikipediaApiException: $message';
}
