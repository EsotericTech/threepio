/// A tool with which the model asks the user questions.
///
/// Port of eino-examples `adk/common/tool/follow_up_tool.go`.
library;

import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../../components/tool/invokable_tool.dart';
import '../../components/tool/tool_options.dart';
import '../../compose/interrupt.dart';
import '../../compose/resume.dart';
import '../../core/run_context.dart';
import '../../errors.dart';
import '../../schema/tool_info.dart';
import '../../schema/type_registry.dart';

/// What a [FollowUpTool] shows the user; the caller resumes it with the same
/// questions and [userAnswer] filled in. Port of eino-examples
/// `FollowUpInfo`.
@immutable
final class FollowUpInfo {
  /// The [questions] to answer.
  FollowUpInfo({required List<String> questions, this.userAnswer = ''})
      : questions = List.unmodifiable(questions);

  /// The questions from their JSON form.
  factory FollowUpInfo.fromJson(Map<String, Object?> json) => FollowUpInfo(
        questions: (json['questions']! as List<Object?>).cast<String>(),
        userAnswer: json['user_answer'] as String? ?? '',
      );

  final List<String> questions;

  /// The user's answer.
  final String userAnswer;

  /// These questions with the user's [answer].
  FollowUpInfo withAnswer(String answer) =>
      FollowUpInfo(questions: questions, userAnswer: answer);

  /// The JSON form.
  Map<String, Object?> toJson() => {
        'questions': questions,
        if (userAnswer.isNotEmpty) 'user_answer': userAnswer,
      };

  @override
  bool operator ==(Object other) =>
      other is FollowUpInfo &&
      other.userAnswer == userAnswer &&
      const ListEquality<String>().equals(other.questions, questions);

  @override
  int get hashCode => Object.hash(Object.hashAll(questions), userAnswer);

  @override
  String toString() {
    final text = StringBuffer(
      'We need more information. Please answer the following questions:\n',
    );
    for (final (index, question) in questions.indexed) {
      text.writeln('${index + 1}. $question');
    }
    return text.toString();
  }
}

/// What a [FollowUpTool] keeps while it waits. Port of eino-examples
/// `FollowUpState`.
@immutable
final class FollowUpState {
  /// The state of a wait for answers to [questions].
  FollowUpState({required List<String> questions})
      : questions = List.unmodifiable(questions);

  /// A state from its JSON form.
  factory FollowUpState.fromJson(Map<String, Object?> json) => FollowUpState(
        questions: (json['questions']! as List<Object?>).cast<String>(),
      );

  final List<String> questions;

  /// The JSON form.
  Map<String, Object?> toJson() => {'questions': questions};
}

/// A tool the model calls with `{"questions": [...]}`: the run interrupts
/// with a [FollowUpInfo], and the resume data (a [FollowUpInfo] with the
/// user's answer) is the tool's result. Not targeted on a resume, it asks
/// again.
///
/// Port of eino-examples `GetFollowUpTool` (`FollowUpTool`).
final class FollowUpTool extends InvokableTool {
  /// The follow-up tool.
  FollowUpTool() {
    registerFollowUpTypes();
  }

  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(
        name: 'FollowUpTool',
        desc: 'Asks the user for more information by providing a list of '
            'questions.',
        params: const {
          'questions': ParameterInfo(
            type: DataType.array,
            elemInfo: ParameterInfo(type: DataType.string),
          ),
        },
      );

  @override
  Future<String> run(String argumentsJson) =>
      invokableRun(RunContext.background(), argumentsJson);

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    final saved = getInterruptState<FollowUpState>(ctx);
    if (!saved.wasInterrupted) {
      final questions = _questionsOf(argumentsJson);
      throw statefulInterrupt(
        ctx,
        FollowUpInfo(questions: questions),
        FollowUpState(questions: questions),
      );
    }
    final state = saved.state ?? FollowUpState(questions: const []);
    final answer = getResumeContext<FollowUpInfo>(ctx);
    if (!answer.isResumeTarget) {
      throw statefulInterrupt(
        ctx,
        FollowUpInfo(questions: state.questions),
        state,
      );
    }
    final data = answer.data;
    if (!answer.hasData || data == null || data.userAnswer.isEmpty) {
      throw const ThreepioException('tool resumed without a user answer');
    }
    return data.userAnswer;
  }

  static List<String> _questionsOf(String argumentsJson) {
    final Object? decoded;
    try {
      decoded = argumentsJson.trim().isEmpty ? const {} : jsonDecode(argumentsJson);
    } on FormatException catch (error) {
      throw ThreepioFormatException(
        'FollowUpTool arguments are not JSON: ${error.message}',
        cause: error,
      );
    }
    final questions = decoded is Map ? decoded['questions'] : null;
    if (questions is! List) return const [];
    return [for (final question in questions) question.toString()];
  }
}

/// Registers [FollowUpInfo] and [FollowUpState] with [TypeRegistry].
/// Idempotent.
@internal
void registerFollowUpTypes() {
  if (!TypeRegistry.isRegistered<FollowUpInfo>()) {
    TypeRegistry.registerName<FollowUpInfo>(
      'eino_examples_follow_up_info',
      fromJson: FollowUpInfo.fromJson,
      toJson: (info) => info.toJson(),
    );
  }
  if (!TypeRegistry.isRegistered<FollowUpState>()) {
    TypeRegistry.registerName<FollowUpState>(
      'eino_examples_follow_up_state',
      fromJson: FollowUpState.fromJson,
      toJson: (state) => state.toJson(),
    );
  }
}
