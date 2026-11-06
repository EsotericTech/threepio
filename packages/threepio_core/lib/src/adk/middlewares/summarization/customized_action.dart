/// The events the summarization middleware sends while it works.
///
/// Port of eino `adk/middlewares/summarization/customized_action.go`.
library;

import 'package:meta/meta.dart';

import '../../../schema/message.dart';
import '../../../schema/type_registry.dart';

/// What a [SummarizationAction] reports. Port of eino
/// `summarization.ActionType`.
enum SummarizationActionType {
  /// The trigger fired; the summary is about to be generated. Port of
  /// `ActionTypeBeforeSummarize` (`before_summarize`).
  beforeSummarize('before_summarize'),

  /// The summary replaced the history. Port of `ActionTypeAfterSummarize`
  /// (`after_summarize`).
  afterSummarize('after_summarize'),

  /// One attempt to generate the summary ended. Port of
  /// `ActionTypeGenerateSummary` (`generate_summary`).
  generateSummary('generate_summary');

  const SummarizationActionType(this.einoName);

  /// The value eino writes in JSON.
  final String einoName;

  /// The type eino writes as [name].
  static SummarizationActionType fromEinoName(String name) =>
      values.firstWhere((type) => type.einoName == name, orElse: () {
        throw FormatException('unknown summarization action type: $name');
      });
}

/// Which model an attempt used. Port of eino
/// `summarization.GenerateSummaryPhase`.
enum GenerateSummaryPhase {
  /// The configured model; attempt 1 is the first call, later ones are
  /// retries. Port of `GenerateSummaryPhasePrimary` (`primary`).
  primary('primary'),

  /// A failover model, after the primary one gave up. Port of
  /// `GenerateSummaryPhaseFailover` (`failover`).
  failover('failover');

  const GenerateSummaryPhase(this.einoName);

  /// The value eino writes in JSON.
  final String einoName;

  /// The phase eino writes as [name].
  static GenerateSummaryPhase fromEinoName(String name) =>
      values.firstWhere((phase) => phase.einoName == name, orElse: () {
        throw FormatException('unknown summary phase: $name');
      });
}

/// The history before the summary was made. Port of eino
/// `summarization.BeforeSummarizeAction`.
@immutable
final class BeforeSummarizeAction {
  /// The history [messages].
  const BeforeSummarizeAction({this.messages = const []});

  /// The agent's messages before summarization.
  final List<Message> messages;
}

/// The history the summary left. Port of eino
/// `summarization.AfterSummarizeAction`.
@immutable
final class AfterSummarizeAction {
  /// The history [messages].
  const AfterSummarizeAction({this.messages = const []});

  /// The agent's messages after summarization.
  final List<Message> messages;
}

/// One attempt to generate the summary, successful or not. Port of eino
/// `summarization.GenerateSummaryAction`.
@immutable
final class GenerateSummaryAction {
  /// Attempt [attempt] of [phase].
  const GenerateSummaryAction({
    required this.attempt,
    required this.phase,
    this.modelResponse,
    this.error,
  });

  /// The 1-based attempt within the phase.
  final int attempt;

  /// The phase of the attempt.
  final GenerateSummaryPhase phase;

  /// What the model answered; `null` when the call failed without an
  /// answer.
  final Message? modelResponse;

  /// What the call threw, if anything (Go `GetError()`; not written to
  /// JSON, as in Go).
  final Object? error;
}

/// The payload of the `customizedAction` of a summarization event.
///
/// Port of eino `summarization.CustomizedAction`; registered with
/// [TypeRegistry] under eino's name
/// `_eino_adk_summarization_mw_customized_action`. Exactly one of [before],
/// [after] and [generateSummary] is set, by [type].
@immutable
final class SummarizationAction {
  /// An action of [type].
  const SummarizationAction({
    required this.type,
    this.before,
    this.after,
    this.generateSummary,
  });

  /// The registered name of this type. Port of the name eino registers.
  static const String registeredName = '_eino_adk_summarization_mw_customized_action';

  /// What the action reports.
  final SummarizationActionType type;

  /// Set for [SummarizationActionType.beforeSummarize].
  final BeforeSummarizeAction? before;

  /// Set for [SummarizationActionType.afterSummarize].
  final AfterSummarizeAction? after;

  /// Set for [SummarizationActionType.generateSummary].
  final GenerateSummaryAction? generateSummary;

  /// The JSON of the action, with eino's field names.
  Map<String, Object?> toJson() => {
        'type': type.einoName,
        if (before != null && before!.messages.isNotEmpty)
          'before': {
            'messages': [for (final message in before!.messages) message.toJson()],
          },
        if (before != null && before!.messages.isEmpty) 'before': <String, Object?>{},
        if (after != null && after!.messages.isNotEmpty)
          'after': {
            'messages': [for (final message in after!.messages) message.toJson()],
          },
        if (after != null && after!.messages.isEmpty) 'after': <String, Object?>{},
        if (generateSummary != null)
          'generate_summary': {
            'attempt': generateSummary!.attempt,
            'phase': generateSummary!.phase.einoName,
            if (generateSummary!.modelResponse != null)
              'model_response': generateSummary!.modelResponse!.toJson(),
          },
      };

  /// The action [toJson] wrote.
  static SummarizationAction fromJson(Map<String, Object?> json) {
    List<Message> messages(Object? value) => [
          if (value is Map && value['messages'] is List)
            for (final message in value['messages'] as List)
              Message.fromJson(Map<String, dynamic>.from(message as Map)),
        ];
    final generate = json['generate_summary'];
    return SummarizationAction(
      type: SummarizationActionType.fromEinoName(json['type']! as String),
      before: json['before'] == null
          ? null
          : BeforeSummarizeAction(messages: messages(json['before'])),
      after: json['after'] == null ? null : AfterSummarizeAction(messages: messages(json['after'])),
      generateSummary: generate is Map
          ? GenerateSummaryAction(
              attempt: (generate['attempt'] as num?)?.toInt() ?? 0,
              phase: GenerateSummaryPhase.fromEinoName(generate['phase']! as String),
              modelResponse: generate['model_response'] == null
                  ? null
                  : Message.fromJson(
                      Map<String, dynamic>.from(generate['model_response'] as Map),
                    ),
            )
          : null,
    );
  }
}

/// Registers [SummarizationAction] with [TypeRegistry] (idempotent; again
/// after `TypeRegistry.reset()`).
void ensureSummarizationTypesRegistered() {
  if (TypeRegistry.isRegistered<SummarizationAction>()) return;
  TypeRegistry.registerName<SummarizationAction>(
    SummarizationAction.registeredName,
    fromJson: SummarizationAction.fromJson,
    toJson: (action) => action.toJson(),
  );
}
