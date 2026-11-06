// What the P9 prebuilt agents export, and what they must not: the sequential
// and loop runners (eino's NOT RECOMMENDED workflow agents) are internal to
// the plan-execute port and are exported by no library. The negative check
// walks the export graph of `adk.dart` and of the umbrella library with
// `dart:mirrors` (in memory; no file is read).
@TestOn('vm')
library;

import 'dart:mirrors';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
// Loaded so that the mirror system knows the umbrella library.
import 'package:threepio_core/threepio_core.dart' as umbrella;

final _runnerLibraries = {
  Uri.parse('package:threepio_core/src/adk/prebuilt/plan_execute/sequential_runner.dart'),
  Uri.parse('package:threepio_core/src/adk/prebuilt/plan_execute/loop_runner.dart'),
};

const _internalNames = {
  #SequentialRunner,
  #LoopRunner,
  #LoopBreak,
  #SequentialRunnerState,
  #LoopRunnerState,
  #FlowWrappedAgent,
  #WorkflowRunnerAgent,
  #PlannerAgent,
  #ReplannerAgent,
  #DefaultPlan,
  #TaskTool,
  #AppendPromptToolMiddleware,
  #ExecutedStepOutputMiddleware,
};

/// Every library [root] exports, directly or through other exports, with the
/// names its `show`/`hide` combinators leave visible (`null`: all of them).
Map<Uri, Set<Symbol>?> _exports(LibraryMirror root) {
  final result = <Uri, Set<Symbol>?>{};
  void visit(LibraryMirror library) {
    for (final dependency in library.libraryDependencies) {
      if (!dependency.isExport) continue;
      final target = dependency.targetLibrary;
      if (target == null) continue;
      // The VM reports `show a, b` as one combinator per name.
      Set<Symbol>? shown;
      for (final combinator in dependency.combinators) {
        if (combinator.isShow) (shown ??= {}).addAll(combinator.identifiers);
      }
      final uri = target.uri;
      if (result.containsKey(uri)) continue;
      result[uri] = shown;
      visit(target);
    }
  }

  visit(root);
  return result;
}

LibraryMirror _library(String uri) => currentMirrorSystem().libraries[Uri.parse(uri)]!;

void main() {
  test('the umbrella library is loaded', () {
    expect(umbrella.Message.user('x').content, 'x');
  });

  for (final root in ['package:threepio_core/adk.dart', 'package:threepio_core/threepio_core.dart']) {
    test('$root does not export the sequential and loop runners, even transitively', () {
      final exported = _exports(_library(root));
      expect(exported, isNotEmpty);
      expect(exported.keys.toSet().intersection(_runnerLibraries), isEmpty);
    });

    test('$root does not make the internal prebuilt classes visible', () {
      final exported = _exports(_library(root));
      for (final MapEntry(key: uri, value: shown) in exported.entries) {
        if (!uri.path.contains('/prebuilt/')) continue;
        expect(shown, isNotNull, reason: '$uri is exported without a show list');
        expect(shown!.intersection(_internalNames), isEmpty, reason: '$uri');
      }
    });
  }

  test('the export walk sees the prebuilt libraries adk.dart does export', () {
    final exported = _exports(_library('package:threepio_core/adk.dart'));
    final planExecute =
        exported[Uri.parse('package:threepio_core/src/adk/prebuilt/plan_execute/plan_execute.dart')];
    expect(planExecute, {#PlanExecute, #PlanExecuteLoopConfig});
    final deep = exported[Uri.parse('package:threepio_core/src/adk/prebuilt/deep/deep_agent.dart')];
    expect(deep, {#DeepAgent, #DeepAgentConfig});
  });

  test('the umbrella library exports nothing of the prebuilt agents', () {
    final exported = _exports(_library('package:threepio_core/threepio_core.dart'));
    expect(exported.keys.where((uri) => uri.path.contains('/prebuilt/')), isEmpty);
  });

  test('adk.dart exports the public surface of the prebuilt agents', () {
    // Compiles only if every name is exported.
    final names = <Object>[
      PlanExecute,
      PlanExecuteLoopConfig,
      PlannerConfig,
      ExecutorConfig,
      ReplannerConfig,
      Plan,
      ExecutedStep,
      ExecutionContext,
      PlanExecuteResponse,
      DeepAgent,
      DeepAgentConfig,
      Todo,
    ];
    expect(names, hasLength(12));
    // The typedefs.
    PlannerModelInput? plannerInput;
    ExecutionModelInput? executionInput;
    PlanDecoder? decoder;
    TaskToolDescriptionGenerator? describe;
    expect([plannerInput, executionInput, decoder, describe], everyElement(isNull));
    expect(PlanExecute.planSessionKey, 'Plan');
    expect(DeepAgent.sessionKeyTodos, 'deep_agent_session_key_todos');
  });
}
