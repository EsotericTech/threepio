/// The plan of the plan-execute agents and the steps they executed.
///
/// Port of `Plan`, `NewPlan`, `defaultPlan`, `ExecutedStep`,
/// `ExecutionContext` and `Response` of eino `adk/prebuilt/planexecute`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';

import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../schema/message.dart';
import '../../../schema/type_registry.dart';

/// A plan: the steps still to do, of which the executor does the first.
///
/// Port of eino `planexecute.Plan`. The planner and the replanner build one
/// from the JSON the model wrote ([PlanDecoder]); the executor's and the
/// replanner's prompts show it as JSON ([toJson]). The default plan is
/// `{"steps": ["…", …]}`; a custom plan brings its own JSON shape, decoder
/// and, for checkpoints, a `TypeRegistry.registerName` registration (the plan
/// is a session value).
abstract interface class Plan {
  /// The step to execute next; `''` when there is none. Port of
  /// `Plan.FirstStep`.
  String firstStep();

  /// The JSON form of the plan, as the prompts show it. Port of
  /// `Plan.MarshalJSON`, limited to a JSON object (Go's may write any JSON
  /// value).
  Map<String, Object?> toJson();
}

/// Builds a [Plan] from the JSON the model wrote (the arguments of the plan
/// tool, or the content of a model with formatted output).
///
/// Port of eino `planexecute.NewPlan` followed by `Plan.UnmarshalJSON`: Dart
/// builds the immutable plan from the text instead of filling an empty one.
/// What it throws becomes the agent's error (`unmarshal plan error: …`).
typedef PlanDecoder = FutureOr<Plan> Function(RunContext ctx, String json);

/// The plan of the plan-execute agents unless a [PlanDecoder] says otherwise:
/// an ordered list of steps.
///
/// Port of eino's unexported `defaultPlan`; its JSON is `{"steps": [...]}`.
/// Registered with `TypeRegistry` as `_eino_adk_plan_execute_default_plan`.
@internal
@immutable
final class DefaultPlan implements Plan {
  /// A plan of [steps]; `null` is Go's nil slice (`{"steps":null}`).
  DefaultPlan(List<String>? steps)
      : steps = steps == null ? null : List.unmodifiable(steps);

  /// A plan from its JSON object, as [decode] reads it. Throws
  /// [ThreepioFormatException] when `steps` is not a list of strings.
  factory DefaultPlan.fromJson(Map<String, Object?> json) {
    final steps = json['steps'];
    if (steps == null) return DefaultPlan(null);
    if (steps is! List || steps.any((step) => step != null && step is! String)) {
      throw ThreepioFormatException(
        'mismatched type with value: "steps" must be a list of strings, '
        'got ${jsonEncode(steps)}',
      );
    }
    // A null element is the zero value, as sonic decodes it.
    return DefaultPlan([for (final step in steps) step as String? ?? '']);
  }

  /// The plan the model wrote as [json]. Port of `defaultNewPlan` and
  /// `defaultPlan.UnmarshalJSON` (sonic): unknown fields are ignored, a
  /// missing `steps` is an empty plan. Field names must match exactly (Go
  /// also accepts other letter cases).
  static DefaultPlan decode(RunContext ctx, String json) {
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException catch (error) {
      throw ThreepioFormatException(
        'invalid JSON: ${error.message}',
        source: json,
        cause: error,
      );
    }
    if (decoded == null) return DefaultPlan(null);
    if (decoded is! Map<String, Object?>) {
      throw ThreepioFormatException(
        'mismatched type with value: a plan is a JSON object, got $json',
      );
    }
    return DefaultPlan.fromJson(decoded);
  }

  /// The steps, in order; `null` when the JSON had none.
  final List<String>? steps;

  @override
  String firstStep() {
    final current = steps;
    return current == null || current.isEmpty ? '' : current.first;
  }

  @override
  Map<String, Object?> toJson() => {'steps': steps};

  @override
  bool operator ==(Object other) =>
      other is DefaultPlan &&
      _listEquals(other.steps, steps);

  @override
  int get hashCode => Object.hashAll(steps ?? const <String>[]);

  @override
  String toString() => 'DefaultPlan($steps)';
}

bool _listEquals(List<String>? a, List<String>? b) {
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// A step the executor did and what came of it.
///
/// Port of eino `planexecute.ExecutedStep`. The replanner appends one per
/// round to the session value `PlanExecute.executedStepsSessionKey`.
@immutable
final class ExecutedStep {
  /// The step [step] and its [result].
  const ExecutedStep({required this.step, required this.result});

  /// A step from its JSON form; see [toJson].
  factory ExecutedStep.fromJson(Map<String, Object?> json) => ExecutedStep(
        step: json['step'] as String? ?? '',
        result: json['result'] as String? ?? '',
      );

  /// The step, as the plan had it.
  final String step;

  /// What the executor answered.
  final String result;

  /// The JSON form, as checkpoints keep it.
  Map<String, Object?> toJson() => {'step': step, 'result': result};

  @override
  bool operator ==(Object other) =>
      other is ExecutedStep && other.step == step && other.result == result;

  @override
  int get hashCode => Object.hash(step, result);

  @override
  String toString() => 'ExecutedStep($step, $result)';
}

/// What the executor's and the replanner's input is built from.
///
/// Port of eino `planexecute.ExecutionContext`.
@immutable
final class ExecutionContext {
  /// The context of one round.
  ExecutionContext({
    required List<Message> userInput,
    required this.plan,
    List<ExecutedStep> executedSteps = const [],
  })  : userInput = List.unmodifiable(userInput),
        executedSteps = List.unmodifiable(executedSteps);

  /// The messages the plan-execute agent was started with.
  final List<Message> userInput;

  /// The current plan.
  final Plan plan;

  /// The steps done so far, in order.
  final List<ExecutedStep> executedSteps;
}

/// The final answer of the replanner's respond tool.
///
/// Port of eino `planexecute.Response`: the JSON shape of the default
/// respond tool's arguments, `{"response": "…"}`.
@immutable
final class PlanExecuteResponse {
  /// A response with [response].
  const PlanExecuteResponse(this.response);

  /// A response from the respond tool's arguments.
  factory PlanExecuteResponse.fromJson(Map<String, Object?> json) =>
      PlanExecuteResponse(json['response'] as String? ?? '');

  /// The complete response to the user.
  final String response;

  /// The JSON form.
  Map<String, Object?> toJson() => {'response': response};

  @override
  bool operator ==(Object other) =>
      other is PlanExecuteResponse && other.response == response;

  @override
  int get hashCode => response.hashCode;

  @override
  String toString() => 'PlanExecuteResponse($response)';
}

/// Registers the plan-execute session value types under eino's names.
/// Idempotent; survives `TypeRegistry.reset()` when called again. Port of
/// the `init` of eino `planexecute`.
@internal
void ensurePlanExecuteTypesRegistered() {
  if (!TypeRegistry.isRegistered<DefaultPlan>()) {
    TypeRegistry.registerName<DefaultPlan>(
      '_eino_adk_plan_execute_default_plan',
      fromJson: DefaultPlan.fromJson,
      toJson: (plan) => plan.toJson(),
    );
  }
  if (!TypeRegistry.isRegistered<ExecutedStep>()) {
    TypeRegistry.registerName<ExecutedStep>(
      '_eino_adk_plan_execute_executed_step',
      fromJson: ExecutedStep.fromJson,
      toJson: (step) => step.toJson(),
    );
  }
  if (!TypeRegistry.isRegistered<List<ExecutedStep>>()) {
    TypeRegistry.registerName<List<ExecutedStep>>(
      '_eino_adk_plan_execute_executed_steps',
      fromJson: (json) => [
        for (final item in json['items']! as List<Object?>)
          ExecutedStep.fromJson(item! as Map<String, Object?>),
      ],
      toJson: (steps) => {
        'items': [for (final step in steps) step.toJson()],
      },
    );
  }
}
