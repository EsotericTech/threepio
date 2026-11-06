// An interrupted agentic tools node keeps the block extras of its calls in
// the checkpoint (P13 integration review finding). The node hands the
// `extra` of each function call block to the inner `ToolsNode` as the
// `ToolCall.extra`, and models put registered types there (the OpenAI
// Responses model keeps its item ids and statuses as
// `OpenAIResponsesItemId` / `OpenAIResponsesItemStatus`). Go's gob writes
// registered types in `ToolCall.Extra`; the tools node's interrupt state
// wrote the freezed JSON of its calls, whose `extra` values went to
// `jsonEncode` as they were, so the checkpoint could not be written.
//
// Not a port: eino has no test of an agentic tools node interrupt.
import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:test/test.dart';
import 'package:threepio_core/compose.dart';

/// A type a model keeps in a block's `extra`, registered for checkpoints.
@immutable
final class _ItemId {
  const _ItemId(this.value);

  final String value;

  @override
  bool operator ==(Object other) => other is _ItemId && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// A value with a `toJson()` that is not registered: `jsonEncode` writes it.
final class _Described {
  const _Described(this.value);

  final String value;

  Map<String, Object?> toJson() => {'described': value};
}

final class _Approval extends InvokableTool {
  int calls = 0;

  @override
  Future<ToolInfo> info() async => ToolInfo.function(name: 'approve');

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    calls++;
    final resumed = getResumeContext<String>(ctx);
    if (!resumed.isResumeTarget) throw interrupt(ctx, 'approve?');
    return 'approved by ${resumed.data}';
  }
}

ToolsInterruptAndRerunExtra _roundTrip(ToolsInterruptAndRerunExtra extra) =>
    ToolsInterruptAndRerunExtra.fromJson(
      jsonDecode(jsonEncode(extra.toJson())) as Map<String, Object?>,
    );

void main() {
  final ctx = RunContext.background();

  setUpAll(() {
    if (!TypeRegistry.isRegistered<_ItemId>()) {
      TypeRegistry.registerName<_ItemId>(
        'test_agentic_tools_node_item_id',
        fromJson: (json) => _ItemId(json['value']! as String),
        toJson: (id) => {'value': id.value},
      );
    }
  });

  test('an interrupted agentic tools node checkpoints the registered types '
      'in its block extras and resumes', () async {
    final approval = _Approval();
    final graph = Graph<AgenticMessage, List<AgenticMessage>>()
      ..addAgenticToolsNode(
        'tools',
        AgenticToolsNode(ToolsNodeConfig(tools: [approval])),
      )
      ..addEdge(Graph.start, 'tools')
      ..addEdge('tools', Graph.end);
    final store = InMemoryCheckpointStore();
    final runnable = await graph.compile(
      ctx,
      options: GraphCompileOptions(checkpointStore: store),
    );
    final input = AgenticMessage(
      role: AgenticRoleType.assistant,
      contentBlocks: [
        ContentBlock(
          const FunctionToolCall(callId: 'c1', name: 'approve', arguments: '{}'),
          extra: const {'item_id': _ItemId('fc_1'), 'status': 'completed'},
        ),
      ],
    );

    GraphInterruptInfo? info;
    try {
      await runnable.invoke(
        ctx,
        input,
        options: [CallOption.checkpointId('cp')],
      );
    } on Object catch (error) {
      info = extractInterruptInfo(error);
      if (info == null) rethrow;
    }
    expect(info, isNotNull, reason: 'the tool interrupts');
    expect(await store.get('cp'), isNotNull);

    final rerun = info!.rerunNodesExtra['tools']! as ToolsInterruptAndRerunExtra;
    expect(rerun.toolCalls.single.extra, {
      'item_id': const _ItemId('fc_1'),
      'status': 'completed',
    });
    // The JSON form gives the registered type back.
    expect(_roundTrip(rerun).toolCalls.single.extra, {
      'item_id': const _ItemId('fc_1'),
      'status': 'completed',
    });

    final results = await runnable.invoke(
      ctx.resumeWithData(info.interruptContexts.single.id, 'the operator'),
      input,
      options: [CallOption.checkpointId('cp')],
    );
    expect(approval.calls, 2);
    final result = results.single.contentBlocks.single.functionToolResult!;
    expect(result.callId, 'c1');
    expect(
      (result.content.single.content as UserInputText).text,
      'approved by the operator',
    );
  });

  group('the JSON form of ToolsInterruptAndRerunExtra', () {
    ToolsInterruptAndRerunExtra withExtra(Map<String, dynamic>? extra) =>
        ToolsInterruptAndRerunExtra(
          toolCalls: [
            ToolCall(
              id: 'c1',
              function: const FunctionCall(name: 'approve', arguments: '{}'),
              extra: extra,
            ),
          ],
          rerunTools: const ['c1'],
        );

    /// The form the tools node wrote before registered extras were
    /// supported.
    String classicForm(ToolsInterruptAndRerunExtra extra) => jsonEncode({
          'tool_calls': [for (final call in extra.toolCalls) call.toJson()],
          'executed_tools': <String, Object?>{},
          'executed_enhanced_tools': <String, Object?>{},
          'rerun_tools': extra.rerunTools,
          'rerun_extra_map': <String, Object?>{},
        });

    test('is unchanged for a plain JSON extra and for none', () {
      for (final extra in [
        null,
        <String, dynamic>{
          'k': 'v',
          'n': [
            1,
            {'a': true},
          ],
        },
      ]) {
        final report = withExtra(extra);
        expect(jsonEncode(report.toJson()), classicForm(report));
        expect(_roundTrip(report).toolCalls.single.extra, extra);
      }
    });

    test('writes an unregistered value with a toJson() as before', () {
      final report = withExtra({'d': const _Described('x')});
      expect(jsonEncode(report.toJson()), classicForm(report));
      expect(_roundTrip(report).toolCalls.single.extra, {
        'd': {'described': 'x'},
      });
    });
  });
}
