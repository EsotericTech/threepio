// Mirror of a ```dart block of doc/NEW_FEATURES.md (see
// test/unit/docs/doc_snippets_test.dart): the block is copied verbatim; the
// lines around it declare what it uses.
// Section 2, "WorkflowAgent", "Parallel Workflow" and "Loop Workflow".
// ignore_for_file: avoid_print

import 'package:threepio_core/threepio_core.dart';

Future<void> sequentialWorkflow(
  BaseAgent researchAgent,
  BaseAgent outlineAgent,
  BaseAgent writerAgent,
  BaseAgent reviewAgent,
) async {
  final workflow = WorkflowAgent(
    name: 'content-pipeline',
    description: 'Research, outline, write and review an article',
    steps: [
      WorkflowStep(
        name: 'research',
        agent: researchAgent,
        inputTransform: (input) => [
          Message.user('Research: ${input.last.content}'),
        ],
      ),
      WorkflowStep(
        name: 'outline',
        agent: outlineAgent,
        inputTransform: (input) => [
          Message.user('Create outline from: ${input.last.content}'),
        ],
      ),
      WorkflowStep(
        name: 'write',
        agent: writerAgent,
        // Skipped when the outline step produced no text
        condition: (messages) => messages.last.content.isNotEmpty,
      ),
      WorkflowStep(
        name: 'review',
        agent: reviewAgent,
      ),
    ],
    // WorkflowConfig(mode: WorkflowMode.sequential) is the default
  );

  // Execute workflow
  final result = await workflow.invoke([
    Message.user('Write an article about climate change'),
  ]);
  print(result.content);
}

Future<void> parallelWorkflow(
  BaseAgent webSearchAgent,
  BaseAgent paperSearchAgent,
  BaseAgent newsSearchAgent,
) async {
  final parallelWorkflow = WorkflowAgent(
    name: 'parallel-research',
    description: 'Searches three sources at once',
    steps: [
      WorkflowStep(name: 'search-web', agent: webSearchAgent),
      WorkflowStep(name: 'search-papers', agent: paperSearchAgent),
      WorkflowStep(name: 'search-news', agent: newsSearchAgent),
    ],
    config: const WorkflowConfig(
      mode: WorkflowMode.parallel,
    ),
  );

  final combined = await parallelWorkflow.invoke([
    Message.user('Recent results on solid-state batteries'),
  ]);
  print(combined.content); // "## search-web\n…\n\n## search-papers\n…"
}

WorkflowAgent loopWorkflow(
  BaseAgent generatorAgent,
  BaseAgent evaluatorAgent,
  BaseAgent refinerAgent,
) {
  final iterativeWorkflow = WorkflowAgent(
    name: 'refinement-loop',
    description: 'Generates, evaluates and refines a draft',
    steps: [
      WorkflowStep(name: 'generate', agent: generatorAgent),
      WorkflowStep(name: 'evaluate', agent: evaluatorAgent),
      WorkflowStep(name: 'refine', agent: refinerAgent),
    ],
    config: WorkflowConfig(
      mode: WorkflowMode.loop,
      maxLoopIterations: 5,
      // Called after each pass with the last step's output; true runs another pass.
      loopCondition: (result, iteration) =>
          !result.content.contains('APPROVED'),
    ),
  );
  return iterativeWorkflow;
}
