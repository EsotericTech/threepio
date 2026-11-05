// The state a batch keeps when it is interrupted is registered when the node
// is created, not only when it runs: after a restart the checkpoint of the
// graph around the node is read before the node is reached. This file runs
// in an isolate of its own, so nothing has registered the type before.
import 'package:test/test.dart';
import 'package:threepio_core/compose.dart';

void main() {
  test('a batch node registers its state when it is created', () {
    final json = {
      r'$type': 'batch.NodeInterruptState',
      r'$value': {
        'original_inputs': ['a', 'b'],
        'completed_results': {'0': 'A'},
        'interrupted_indices': [1],
        'total_count': 2,
      },
    };
    expect(() => TypeRegistry.decode(json), throwsStateError);

    final workflow = Workflow<String, String>();
    workflow
        .addLambdaNode('up', Lambda.invokable((ctx, String s) => s.toUpperCase()))
        .addInput(Graph.start);
    workflow.end().addInput('up');
    BatchNode<String, String>(innerTask: workflow);

    expect(TypeRegistry.decode(json), isNotNull);
    expect(TypeRegistry.encode(TypeRegistry.decode(json)), json);
  });
}
