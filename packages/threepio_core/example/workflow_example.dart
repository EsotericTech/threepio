// ignore_for_file: avoid_print

/// A compose [Workflow]: nodes that say which fields of which nodes make up
/// their input.
///
/// Port of the patterns of Eino's `compose.NewWorkflow` (the guide
/// `eino-ext/skills/eino-compose/reference/workflow.md`). The workflow
/// answers a question and returns the answer with the keywords of the
/// question:
///
/// ```text
/// START ──▶ check                          rejects an empty question
///             ┆ control only
///             ├┄┄▶ keywords ── keywords ──┐
///             └┄┄▶ budget ─── max_words ──┤
/// START ─────────── question ─────────────┼─▶ prompt ─▶ model ─▶ END.answer
/// static value ──── language ─────────────┘
/// keywords ┄┄ data only ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄▶ END.keywords
/// ```
///
/// (`keywords` and `budget` also read the question from START, data only.)
///
/// What it shows:
///
/// * field mappings (`FieldMapping`, Go `compose.MapFields`, `FromField`,
///   `ToField`): a node takes one field of the workflow's input, the whole
///   output of another node as one of its fields, a field of a message; a
///   custom extractor (Go `compose.WithCustomExtractor`) turns a value on
///   the way;
/// * a fan-in: the prompt template takes its variables from two lambdas;
/// * lambda nodes and a template → chat model pair;
/// * a control-only dependency (`addDependency`, Go `AddDependency`): the two
///   lambdas wait for the input check without taking its output;
/// * data-only inputs (`addInputWithOptions(..., noDirectDependency: true)`,
///   Go `WithNoDirectDependency`): data taken from a node that ran earlier on
///   another path;
/// * a static value (`setStaticValue`, Go `SetStaticValue`).
///
/// Run it with an OpenRouter or OpenAI key (see `example/README.md`):
///
/// ```bash
/// OPENROUTER_API_KEY=... dart run example/workflow_example.dart
/// ```
library;

import 'package:threepio_core/compose.dart';

import 'support/example_model.dart';

/// Rejects an empty question. Its output is not used: the nodes behind it
/// only wait for it.
Lambda<Map<String, Object?>, bool> newCheckNode() =>
    Lambda.invokable((ctx, Map<String, Object?> input) {
      final question = input['question'];
      if (question is! String || question.trim().isEmpty) {
        throw ArgumentError.value(question, 'question', 'must not be empty');
      }
      return true;
    });

/// The keywords of a question: its words of five letters or more, in lower
/// case, each once. Takes the question itself as its input.
Lambda<String, List<String>> newKeywordsNode() =>
    Lambda.invokable((ctx, String question) => [
          ...{
            for (final word in question.toLowerCase().split(RegExp(r'\W+')))
              if (word.length >= 5) word,
          },
        ]);

/// How long the answer may be: ten words per word of the question, between
/// 30 and 120. Takes a map with the question under `text`, gives a map with
/// the budget under `max_words`.
Lambda<Map<String, Object?>, Map<String, Object?>> newBudgetNode() =>
    Lambda.invokable((ctx, Map<String, Object?> input) {
      final text = input['text']! as String;
      final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
      return {'max_words': (words.length * 10).clamp(30, 120)};
    });

/// The prompt: its variables come from the input of the workflow, from two
/// lambdas and from a static value.
final ChatTemplate answerTemplate = ChatTemplate.fromMessages(
  FormatType.fString,
  [
    Message.system(
      'Answer in {language}, in at most {max_words} words. '
      'Use these keywords: {keywords}.',
    ),
    Message.user('{question}'),
  ],
);

/// The question-answering workflow for [model], not compiled yet.
///
/// It takes `{'question': ...}` and gives `{'answer': ..., 'keywords':
/// [...]}`.
Workflow<Map<String, Object?>, Map<String, Object?>> newAnswerWorkflow(
  BaseChatModel model,
) {
  final wf = Workflow<Map<String, Object?>, Map<String, Object?>>();

  // The whole input of the workflow goes to the check (Go:
  // AddInput(compose.START)).
  wf.addLambdaNode('check', newCheckNode()).addInput(Graph.start);

  // Both lambdas run after the check (control only: Go AddDependency) and
  // read the question from the input of the workflow (data only: Go
  // WithNoDirectDependency). START comes before the check, so waiting for
  // the check is enough; a data-only input needs such a path.
  wf.addLambdaNode('keywords', newKeywordsNode())
    ..addDependency('check')
    ..addInputWithOptions(
      Graph.start,
      // Go: compose.FromField. The field `question` becomes the whole input.
      [FieldMapping.fromField('question')],
      noDirectDependency: true,
    );
  wf.addLambdaNode('budget', newBudgetNode())
    ..addDependency('check')
    ..addInputWithOptions(
      Graph.start,
      // Go: compose.MapFields. The field `question` becomes the field `text`.
      [FieldMapping.mapFields('question', 'text')],
      noDirectDependency: true,
    );

  // The fan-in: the template waits for both lambdas and puts their outputs
  // together into its variables.
  wf.addChatTemplateNode('prompt', answerTemplate)
    // Go: compose.ToField with WithCustomExtractor. The keyword list becomes
    // the variable `keywords`, written as one string.
    ..addInput('keywords', [
      FieldMapping.toField(
        'keywords',
        customExtractor: (keywords) => (keywords! as List<Object?>).join(', '),
      ),
    ])
    ..addInput('budget', [FieldMapping.mapFields('max_words', 'max_words')])
    ..addInput(Graph.start, [FieldMapping.mapFields('question', 'question')])
    // Go: SetStaticValue. A fixed value for the variable `language`.
    ..setStaticValue(['language'], 'English');

  // The template gives the messages, the model takes them: a whole output
  // to a whole input, as on a graph edge.
  wf.addChatModelNode('model', model).addInput('prompt');

  // The output of the workflow: a field of the model's message, and the
  // keyword list from a node that ran long before (data only: the path
  // keywords → prompt → model → END already orders them).
  // `content` is the Dart field name of Message; Go maps the struct field:
  // MapFields("Content", "answer").
  wf.end()
    ..addInput('model', [FieldMapping.mapFields('content', 'answer')])
    ..addInputWithOptions(
      'keywords',
      [FieldMapping.toField('keywords')],
      noDirectDependency: true,
    );

  return wf;
}

/// Compiles the workflow and asks it [question]. Returns what the workflow
/// gives.
Future<Map<String, Object?>> runWorkflowExample(
  BaseChatModel model, {
  String question = 'How do Dart isolates share memory?',
}) async {
  final ctx = RunContext.background();
  final runnable = await newAnswerWorkflow(model).compile(ctx);

  final result = await runnable.invoke(ctx, {'question': question});

  print('question: $question');
  print('keywords: ${result['keywords']}');
  print('answer:   ${result['answer']}');
  return result;
}

Future<void> main() async {
  final model = exampleChatModel();
  if (model == null) return;
  try {
    await runWorkflowExample(model);
  } finally {
    closeExampleModel(model);
  }
}
