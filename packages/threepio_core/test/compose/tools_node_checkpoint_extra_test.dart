// The checkpoint form of the classic `ToolsNode` (its
// `ToolsInterruptAndRerunExtra` and its rerun state) after registered types
// in the `extra` of its tool calls were supported (P13 review). The classic
// node is what the ADK checkpoints when a tool interrupts, so every extra
// that could be written before must still be written byte for byte as
// before, and a checkpoint written before must be read exactly as it was:
// plain JSON, maps with a `$type` key (also one that names a registered
// type, or the registry's `$map` wrapper), typed lists a registered entry
// fits, objects with a `toJson()`. Only an extra `jsonEncode` cannot write
// (a registered type without a `toJson()`, as the agentic tools node hands
// over) is written through `TypeRegistry`, marked.
//
// The "before" forms are built by hand with the freezed `toJson()` of the
// calls and messages, which is what the tools node wrote before the change.
//
// Not a port: eino has no test of the serialized form of the tools node's
// state (its serializer is not JSON).
import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:test/test.dart';
import 'package:threepio_core/compose.dart';

/// A registered type without a `toJson()`: `jsonEncode` cannot write it.
@immutable
final class _ItemId {
  const _ItemId(this.value);

  final String value;

  @override
  bool operator ==(Object other) => other is _ItemId && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// An unregistered value with a `toJson()`: `jsonEncode` writes it.
final class _Described {
  const _Described(this.value);

  final String value;

  Map<String, Object?> toJson() => {'described': value};
}

/// A value nothing can write.
final class _Opaque {
  const _Opaque();
}

const _rerunStateName = '_eino_compose_tools_interrupt_and_rerun_state';

ToolCall _call(String id, String name, {Map<String, dynamic>? extra}) =>
    ToolCall(
      id: id,
      function: FunctionCall(name: name, arguments: '{}'),
      extra: extra,
    );

ToolsInterruptAndRerunExtra _report(Map<String, dynamic>? extra) =>
    ToolsInterruptAndRerunExtra(
      toolCalls: [_call('c0', 'echo'), _call('c1', 'approve', extra: extra)],
      executedTools: const {'c0': 'echoed'},
      rerunTools: const ['c1'],
      rerunExtraMap: const {'c1': 'approve?'},
    );

/// The JSON text the tools node wrote for [report] before registered extras
/// were supported.
String _beforeForm(ToolsInterruptAndRerunExtra report) => jsonEncode({
      'tool_calls': [for (final call in report.toolCalls) call.toJson()],
      'executed_tools': report.executedTools,
      'executed_enhanced_tools': <String, Object?>{},
      'rerun_tools': report.rerunTools,
      'rerun_extra_map': report.rerunExtraMap,
    });

/// The `$value` of every value tagged [name] in [json].
List<Map<String, Object?>> _tagged(Object? json, String name) {
  final found = <Map<String, Object?>>[];
  void walk(Object? node) {
    if (node is List) {
      node.forEach(walk);
    } else if (node is Map) {
      if (node[r'$type'] == name) {
        found.add((node[r'$value']! as Map).cast<String, Object?>());
      }
      node.values.forEach(walk);
    }
  }

  walk(json);
  return found;
}

final class _Approval extends InvokableTool {
  _Approval(this.interrupts);

  /// How many runs interrupt before one approves.
  final int interrupts;
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
    if (calls <= interrupts) throw interrupt(ctx, 'approve? $calls');
    return 'approved';
  }
}

final class _Echo extends InvokableTool {
  int calls = 0;

  @override
  Future<ToolInfo> info() async => ToolInfo.function(name: 'echo');

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    calls++;
    return 'echoed';
  }
}

void main() {
  final ctx = RunContext.background();

  setUpAll(() {
    if (!TypeRegistry.isRegistered<_ItemId>()) {
      TypeRegistry.registerName<_ItemId>(
        'test_tools_node_checkpoint_extra_item_id',
        fromJson: (json) => _ItemId(json['value']! as String),
        toJson: (id) => {'value': id.value},
      );
    }
  });

  /// Extras the classic path can write, by what they hold.
  final classicExtras = <String, Map<String, dynamic>?>{
    'nothing (null)': null,
    'an empty map': {},
    'nested JSON': {
      'k': 'v',
      'n': [
        1,
        2.5,
        null,
        true,
        {'a': false, 'e': <Object?>[], 'm': <String, Object?>{}},
      ],
      'z': null,
      'big': 1 << 40,
    },
    r'a $type key': {r'$type': 'reasoning.encrypted', 'data': 'abc'},
    r'a nested $type key': {
      'reasoning_details': [
        {'type': 'reasoning.text', r'$type': 'x', 'text': 'thinking'},
      ],
    },
    r'a $type key naming a registered type': {
      r'$type': '_eino_message',
      r'$value': {'role': 'user', 'content': 'hi'},
    },
    r"the registry's $map wrapper": {
      r'$type': r'$map',
      r'$value': {'a': 1},
    },
    r'a $type key that is no string': {r'$type': 3, 'v': 'w'},
    'a typed list a registered entry fits': {
      'history': [Message.user('hi')],
      'none': <Message>[],
    },
    'registered types with a toJson()': {
      'message': Message.user('hi'),
      'call': _call('c9', 'x'),
    },
    'an unregistered type with a toJson()': {'d': const _Described('x')},
    'typed collections': {
      'ints': <int>[1, 2],
      'strings': <String, String>{'a': 'b'},
      'bytes': Uint8List.fromList([1, 2, 3]),
    },
  };

  group('ToolsInterruptAndRerunExtra', () {
    classicExtras.forEach((what, extra) {
      test('with $what in an extra is written and read as before', () {
        final report = _report(extra);
        final before = _beforeForm(report);
        expect(jsonEncode(report.toJson()), before);

        // A checkpoint written before reads as it did then.
        final json = jsonDecode(before) as Map<String, Object?>;
        final restored = ToolsInterruptAndRerunExtra.fromJson(json);
        final calls = json['tool_calls']! as List<Object?>;
        expect(restored.toolCalls, [
          for (final call in calls) ToolCall.fromJson(call! as Map<String, dynamic>),
        ]);
        expect(restored.toolCalls.last.extra, jsonDecode(jsonEncode(extra)));
        expect(restored.executedTools, {'c0': 'echoed'});
        expect(restored.rerunTools, ['c1']);
        expect(restored.rerunExtraMap, {'c1': 'approve?'});
      });
    });

    test('with a registered type without a toJson() writes the extra through '
        'TypeRegistry, marked, and reads it back', () {
      final extra = <String, dynamic>{
        'item_id': const _ItemId('fc_1'),
        'status': 'completed',
        'meta': {r'$type': 'reasoning.text', 'n': <Object?>[1, null]},
        'ids': [const _ItemId('a'), const _ItemId('b')],
      };
      final json = jsonDecode(jsonEncode(_report(extra).toJson()))
          as Map<String, Object?>;
      final calls = (json['tool_calls']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(calls.first.containsKey(r'$typed_extra'), isFalse);
      expect(calls.last[r'$typed_extra'], isTrue);
      final restored = ToolsInterruptAndRerunExtra.fromJson(json);
      expect(restored.toolCalls.first.extra, isNull);
      expect(restored.toolCalls.last.extra, extra);
      expect(restored.toolCalls.last.extra!['item_id'], isA<_ItemId>());
    });

    test('fails to be written, as before, with a value nothing can write', () {
      for (final extra in [
        <String, dynamic>{'o': const _Opaque()},
        <String, dynamic>{'id': const _ItemId('x'), 'o': const _Opaque()},
      ]) {
        expect(
          () => jsonEncode(_report(extra).toJson()),
          throwsA(isA<JsonUnsupportedObjectError>()),
        );
      }
    });
  });

  group('the rerun state of an interrupted ToolsNode', () {
    Message input(Map<String, dynamic>? callExtra, Map<String, dynamic>? extra) =>
        Message(
          role: RoleType.assistant,
          toolCalls: [
            _call('c0', 'echo'),
            _call('c1', 'approve', extra: callExtra),
          ],
          extra: extra,
        );

    test('written before is read as it was, whatever its extras hold', () {
      final messages = [
        const Message(role: RoleType.assistant),
        for (final extra in classicExtras.values) input(extra, extra),
      ];
      for (final message in messages) {
        final before = jsonEncode({
          r'$type': _rerunStateName,
          r'$value': {
            'input': message.toJson(),
            'executed_tools': {'c0': 'echoed'},
            'executed_enhanced_tools': <String, Object?>{},
            'rerun_tools': ['c1'],
          },
        });
        final state = JsonCheckpointSerializer.fromJson(jsonDecode(before));
        // Read back and written again: the same text, so the message read
        // is the one that was written.
        expect(jsonEncode(JsonCheckpointSerializer.toJson(state)), before);
      }
    });

    test('of a graph is written as before, and a run resumed from it '
        'interrupts again with the same state and then finishes', () async {
      final approval = _Approval(2);
      final echo = _Echo();
      final graph = Graph<Message, List<Message>>()
        ..addToolsNode(
          'tools',
          await ToolsNode.create(ToolsNodeConfig(tools: [echo, approval])),
        )
        ..addEdge(Graph.start, 'tools')
        ..addEdge('tools', Graph.end);
      final store = InMemoryCheckpointStore();
      final runnable = await graph.compile(
        ctx,
        options: GraphCompileOptions(checkpointStore: store),
      );
      final message = input(
        {
          r'$type': 'reasoning.encrypted',
          'signature': 'abc',
          'n': [1, 2.5, null, <String, Object?>{}],
        },
        {
          'reasoning_details': [
            {'type': 'reasoning.text', r'$type': 'x', 'text': 'thinking'},
          ],
          r'$type': '_eino_message',
          r'$value': {'role': 'user', 'content': 'hi'},
        },
      );
      final beforeInput = jsonEncode(message.toJson());
      final options = [CallOption.checkpointId('cp')];

      Future<GraphInterruptInfo> interrupted(RunContext runCtx) async {
        try {
          await runnable.invoke(runCtx, message, options: options);
        } on Object catch (error) {
          final info = extractInterruptInfo(error);
          if (info != null) return info;
          rethrow;
        }
        fail('the tool interrupts');
      }

      /// The stored checkpoint holds the rerun state with its input in the
      /// form written before; with the input replaced by that form it is
      /// unchanged. (The report, `ToolsInterruptAndRerunExtra`, is not part
      /// of the checkpoint; its form is checked above.)
      Future<void> expectBeforeForm() async {
        final bytes = (await store.get('cp'))!;
        final json = jsonDecode(utf8.decode(bytes));
        final states = _tagged(json, _rerunStateName);
        expect(states, hasLength(1));
        expect(jsonEncode(states.single['input']), beforeInput);
        states.single['input'] = jsonDecode(beforeInput);
        expect(utf8.encode(jsonEncode(json)), bytes);
      }

      var info = await interrupted(ctx);
      await expectBeforeForm();

      // Resumed from it, the node reads its state and writes it again.
      info = await interrupted(ctx.resume([info.interruptContexts.single.id]));
      await expectBeforeForm();
      expect(approval.calls, 2);

      final results = await runnable.invoke(
        ctx.resume([info.interruptContexts.single.id]),
        message,
        options: options,
      );
      expect(results.map((m) => (m.toolCallId, m.content)), [
        ('c0', 'echoed'),
        ('c1', 'approved'),
      ]);
      expect(echo.calls, 1, reason: 'a finished call is not run again');
      expect(approval.calls, 3);
    });
  });
}
