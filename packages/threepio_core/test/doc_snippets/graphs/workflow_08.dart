// Mirrors "Workflow" of doc/GRAPHS.md.
import 'package:threepio_core/compose.dart';

Future<Map<String, Object?>> workflowExample(RunContext ctx) async {
  // #docregion workflow
  final workflow = Workflow<Map<String, Object?>, Map<String, Object?>>();

  // Takes the field 'text' of the workflow's input as its whole input.
  workflow
      .addLambdaNode(
        'upper',
        Lambda<String, String>.invokable((ctx, s) => s.toUpperCase()),
      )
      .addInput(Graph.start, [FieldMapping.fromField('text')]);

  // Assembles its input from three places: the output of 'upper', a field
  // of the workflow's input, and a constant.
  workflow.addLambdaNode(
    'join',
    Lambda<Map<String, Object?>, String>.invokable(
      (ctx, input) => '${input['a']}-${input['b']}-${input['c']}',
    ),
  )
    ..addInput('upper', [FieldMapping.toField('a')])
    ..addInput(Graph.start, [FieldMapping.mapFields('other', 'b')])
    ..setStaticValue(['c'], 'static');

  // What is mapped to end() is the output of the workflow.
  workflow.end()
    ..addInput('join', [FieldMapping.toField('result')])
    ..addInputWithOptions(
      Graph.start,
      [FieldMapping.mapFieldPaths(const ['nested', 'x'], const ['deep', 'x'])],
      noDirectDependency: true,
    );

  final runnable = await workflow.compile(ctx);
  final output = await runnable.invoke(ctx, {
    'text': 'hi',
    'other': 'o',
    'nested': {'x': 1},
  }); // {'result': 'HI-o-static', 'deep': {'x': 1}}
  // #enddocregion workflow
  return output;
}

// #docregion addressable
/// A class a workflow can map fields from and to.
final class Query implements FieldAddressable {
  const Query({this.text = '', this.limit = 10});

  final String text;
  final int limit;

  @override
  Object? getField(String name) => switch (name) {
        'text' => text,
        'limit' => limit,
        _ => throw ArgumentError.value(name, 'name', 'no such field'),
      };

  @override
  Query withField(String name, Object? value) => switch (name) {
        'text' => Query(text: value! as String, limit: limit),
        'limit' => Query(text: text, limit: value! as int),
        _ => throw ArgumentError.value(name, 'name', 'no such field'),
      };
}

void registerQuery() {
  // Needed for a class that mappings write to: the engine starts from it.
  FieldAddressable.registerBlank<Query>(Query.new);
}
// #enddocregion addressable
