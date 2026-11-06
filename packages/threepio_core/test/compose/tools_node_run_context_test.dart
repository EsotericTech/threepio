// P9: a ToolsNode asks a tool whose info depends on the run
// (`RunContextToolInfo`) with the context it is created or called with, as
// Go's `NewToolNode(ctx, …)` and `convTools(ctx, …)` pass `ctx` to
// `Info(ctx)`. Found while porting the deep agent's tests (its `task` tool
// builds its description from the run).
import 'package:test/test.dart';
import 'package:threepio_core/compose.dart';
import 'package:threepio_core/src/components/tool/run_context_tool_info.dart';

final _key = ContextKey<String>('who');

final class _RunTool extends InvokableTool implements RunContextToolInfo {
  final List<String?> seen = [];

  @override
  Future<ToolInfo> info() => infoWithContext(RunContext.background());

  @override
  Future<ToolInfo> infoWithContext(RunContext ctx) async {
    seen.add(ctx.value(_key));
    return ToolInfo.fromParams(name: 'run_tool', desc: 'for ${ctx.value(_key)}', params: const {});
  }

  @override
  Future<String> run(String argumentsJson) async => 'ran';
}

Message _call() => Message(
      role: RoleType.assistant,
      content: '',
      toolCalls: [ToolCall(id: '1', function: FunctionCall(name: 'run_tool', arguments: '{}'))],
    );

void main() {
  test('create(ctx:) asks with that context; without it, with a background one', () async {
    final tool = _RunTool();
    final ctx = RunContext.background().withValue(_key, 'creator');
    final node = await ToolsNode.create(ToolsNodeConfig(tools: [tool]), ctx: ctx);
    expect(tool.seen, ['creator']);
    expect((await node.invoke(ctx, _call())).single.content, 'ran');
    expect(tool.seen, ['creator'], reason: 'the default tools are built once');
    await ToolsNode.create(ToolsNodeConfig(tools: [tool]));
    expect(tool.seen, ['creator', null]);
  });

  test('a node used without create asks with the first call\'s context', () async {
    final tool = _RunTool();
    final node = ToolsNode(ToolsNodeConfig(tools: [tool]));
    await node.invoke(RunContext.background().withValue(_key, 'first call'), _call());
    expect(tool.seen, ['first call']);
  });

  test('a tool list from the call options is asked with the call\'s context', () async {
    final tool = _RunTool();
    final node = await ToolsNode.create(const ToolsNodeConfig(tools: []));
    final ctx = RunContext.background().withValue(_key, 'caller');
    final results = await node.invoke(
      ctx,
      _call(),
      options: [CallOption.toolsNode(ToolsNodeOptions(toolList: [tool]))],
    );
    expect(results.single.content, 'ran');
    expect(tool.seen, ['caller']);
  });
}
