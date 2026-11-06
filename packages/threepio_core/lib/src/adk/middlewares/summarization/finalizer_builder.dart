/// Finalizers for the summarization middleware: the default one, and a
/// builder that adds steps such as preserving loaded skills.
///
/// Port of eino `adk/middlewares/summarization/finalizer_builder.go`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';

import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../schema/message.dart';
import '../internal/go_compat.dart';
import 'prompt.dart';
import 'summarization.dart';

/// The default finalizer: the summary's `<all_user_messages>` block gets the
/// user's latest messages, the text gets a preamble and a closing
/// instruction, and the new history is the original system messages plus
/// the summary as a user message.
///
/// Port of eino `summarization.DefaultFinalize`. Unlike the middleware's
/// built-in finalizer it does not mention a transcript path.
Future<List<Message>> defaultSummaryFinalize(
  RunContext ctx,
  List<Message> originalMessages,
  Message summary,
) async {
  final (system, context) = splitSystemAndContextMessages(originalMessages);
  final processed = postProcessSummary(
    contextMessages: context,
    summaryContent: assistantTextContent(summary),
  );
  return [...system, processed];
}

/// Builds a [SummaryFinalizer] from steps that run in order, then
/// post-processes the summary as [defaultSummaryFinalize] does.
///
/// Port of eino `summarization.FinalizerBuilder`. Each step gets the
/// original messages and the summary so far and returns messages whose last
/// one is the (possibly changed) summary; the others are kept, in order,
/// between the system messages and the summary:
///
/// ```dart
/// final finalize = (SummaryFinalizerBuilder()
///       ..preserveSkills(const PreserveSkillsConfig()))
///     .build();
/// // [system messages, preserved skills, summary]
/// ```
final class SummaryFinalizerBuilder {
  /// A builder without steps. Port of eino `summarization.NewFinalizer`.
  SummaryFinalizerBuilder();

  final List<SummaryFinalizer> _handlers = [];
  final List<String> _errors = [];

  /// Adds a step that keeps the contents of skills the skill middleware
  /// loaded, as a user message before the summary. Port of
  /// `FinalizerBuilder.PreserveSkills`.
  ///
  /// It looks at the summary model's input when there is one, the original
  /// messages otherwise; finds the calls of the skill tool and their
  /// results; keeps the most recent call of each skill, at most
  /// [PreserveSkillsConfig.maxSkills] of them, each cut to
  /// [PreserveSkillsConfig.maxTokensPerSkill] and all of them within
  /// [PreserveSkillsConfig.skillsTokenBudget].
  void preserveSkills(PreserveSkillsConfig config) {
    final problem = config._check();
    if (problem != null) {
      _errors.add('PreserveSkills: $problem');
      return;
    }
    _handlers.add((ctx, originalMessages, summary) {
      final modelInput = summarizationModelInputOf(ctx);
      final messages =
          modelInput != null && modelInput.isNotEmpty ? modelInput : originalMessages;
      if (messages.isEmpty) return [summary];
      final skillText = buildPreservedSkillsText(messages, config);
      if (skillText.isEmpty) return [summary];
      return [withSummarizationContentType(Message.user(skillText), contentTypeSkills), summary];
    });
  }

  /// Adds [step] as it is, the way eino's own tests append to the builder's
  /// handler list. Not part of eino's public API (its steps are private),
  /// hence only for tests.
  @visibleForTesting
  void addStep(SummaryFinalizer step) => _handlers.add(step);

  /// The finalizer of the steps added so far. Port of
  /// `FinalizerBuilder.Build`.
  ///
  /// Throws [ArgumentError] when a step was given an invalid configuration,
  /// and [StateError] when there is no step.
  SummaryFinalizer build() {
    if (_errors.isNotEmpty) {
      throw ArgumentError('failed to build finalizer:\n${_errors.join('\n')}');
    }
    if (_handlers.isEmpty) throw StateError('at least one handler is required');
    final handlers = List<SummaryFinalizer>.of(_handlers);
    return (ctx, originalMessages, summary) async {
      final extra = <Message>[];
      var current = summary;
      for (final handler in handlers) {
        final result = await handler(ctx, originalMessages, current);
        if (result.isEmpty) {
          throw const ThreepioException('finalizer handler returned no messages');
        }
        extra.addAll(result.sublist(0, result.length - 1));
        current = result.last;
      }
      final (system, context) = splitSystemAndContextMessages(originalMessages);
      final processed = postProcessSummary(
        contextMessages: context,
        summaryContent: assistantTextContent(current),
      );
      return [...system, ...extra, processed];
    };
  }
}

/// What [SummaryFinalizerBuilder.preserveSkills] keeps. Port of eino
/// `summarization.PreserveSkillsConfig`.
@immutable
final class PreserveSkillsConfig {
  /// A configuration; `null` fields take their defaults.
  const PreserveSkillsConfig({
    this.skillToolName = '',
    this.maxSkills,
    this.maxTokensPerSkill,
    this.skillsTokenBudget,
  });

  /// The name of the skill tool; `''` is `skill`, the skill middleware's
  /// default.
  final String skillToolName;

  /// How many skills to keep, the most recent ones; 0 keeps none; `null` is
  /// 5.
  final int? maxSkills;

  /// The tokens of one skill; a longer one is cut and marked; `null` is
  /// 5000.
  final int? maxTokensPerSkill;

  /// The tokens of all kept skills together; older skills that do not fit
  /// are dropped; `null` is 25 000.
  final int? skillsTokenBudget;

  String? _check() {
    if ((maxSkills ?? 0) < 0) return 'MaxSkills must be non-negative';
    if ((maxTokensPerSkill ?? 0) < 0) return 'MaxTokensPerSkill must be non-negative';
    if ((skillsTokenBudget ?? 0) < 0) return 'SkillsTokenBudget must be non-negative';
    return null;
  }
}

/// A skill found in the history: its name and the tool result. Port of
/// `skillInfo`.
@visibleForTesting
@immutable
final class PreservedSkillInfo {
  /// The skill [name] with [content].
  const PreservedSkillInfo(this.name, this.content);

  /// The skill's name, from the tool call's arguments.
  final String name;

  /// The tool result.
  final String content;
}

/// The skills loaded through the tool [skillTool] in [messages], in order.
/// Port of `extractSkillInfos`.
@visibleForTesting
List<PreservedSkillInfo> extractSkillInfos(List<Message> messages, String skillTool) {
  final skills = <PreservedSkillInfo>[];
  final argumentsById = <String, String>{};
  for (final message in messages) {
    if (message.role == RoleType.assistant) {
      for (final call in message.toolCalls ?? const <ToolCall>[]) {
        if (call.function.name == skillTool) argumentsById[call.id] = call.function.arguments;
      }
    } else if (message.role == RoleType.tool) {
      final arguments = argumentsById[message.toolCallId ?? ''];
      if (arguments == null) continue;
      skills.add(PreservedSkillInfo(_skillName(arguments, message.toolCallId ?? ''), userTextContent(message)));
    }
  }
  return skills;
}

String _skillName(String arguments, String toolCallId) {
  Object? decoded;
  try {
    decoded = jsonDecode(arguments);
  } on FormatException catch (error) {
    throw ThreepioException(
      'failed to parse skill arguments from tool call $toolCallId: ${error.message}',
      cause: error,
    );
  }
  if (decoded == null) return '';
  if (decoded is! Map) {
    throw ThreepioException(
      'failed to parse skill arguments from tool call $toolCallId: not a JSON object',
    );
  }
  final skill = decoded['skill'];
  if (skill == null) return '';
  if (skill is! String) {
    throw ThreepioException(
      'failed to parse skill arguments from tool call $toolCallId: "skill" is not a string',
    );
  }
  return skill;
}

/// The text of the preserved-skills message, or `''`. Port of
/// `buildPreservedSkillsText`.
@visibleForTesting
String buildPreservedSkillsText(List<Message> messages, PreserveSkillsConfig config) {
  final maxSkills = config.maxSkills ?? 5;
  if (maxSkills <= 0) return '';
  final skillTool = config.skillToolName.isEmpty ? 'skill' : config.skillToolName;
  final maxTokensPerSkill = config.maxTokensPerSkill ?? 5000;
  final skillsTokenBudget = config.skillsTokenBudget ?? 25000;

  var skills = extractSkillInfos(messages, skillTool);
  if (skills.isEmpty) return '';

  final unique = <PreservedSkillInfo>[];
  final seen = <String>{};
  for (var i = skills.length - 1; i >= 0; i--) {
    if (seen.add(skills[i].name)) unique.add(skills[i]);
  }
  skills = unique.reversed.toList();
  if (skills.length > maxSkills) skills = skills.sublist(skills.length - maxSkills);

  var totalTokens = 0;
  final budgeted = <PreservedSkillInfo>[];
  for (var i = skills.length - 1; i >= 0; i--) {
    var skill = skills[i];
    var tokens = estimateTokenCount(utf8Length(skill.content));
    if (tokens > maxTokensPerSkill) {
      skill = PreservedSkillInfo(skill.name, truncateSkillContent(skill.content, maxTokensPerSkill));
      tokens = maxTokensPerSkill;
    }
    if (totalTokens + tokens > skillsTokenBudget) break;
    totalTokens += tokens;
    budgeted.add(skill);
  }
  if (budgeted.isEmpty) return '';

  final sections = [
    for (final skill in budgeted.reversed) goSprintf(skillSectionFormat, [skill.name, skill.content]),
  ];
  final text = goSprintf(getSkillPreamble(), [sections.join('\n\n---\n\n')]);
  return '<system-reminder>\n$text\n</system-reminder>';
}

/// [content] cut to about [maxTokens] tokens with a marker at the end; only
/// the marker when it alone is longer. Port of `truncateSkillContent`.
@visibleForTesting
String truncateSkillContent(String content, int maxTokens) {
  if (content.isEmpty) return content;
  final length = utf8Length(content);
  if (estimateTokenCount(length) <= maxTokens) return content;
  final marker = getSkillTruncationMarker();
  var targetBytes = estimateTokenBytes(maxTokens) - utf8Length(marker);
  if (targetBytes < 0) targetBytes = 0;
  if (targetBytes > length) targetBytes = length;
  return utf8Prefix(content, targetBytes) + marker;
}
