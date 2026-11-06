// Port of eino-ext `components/tool/sequentialthinking/sequentialthinking_test.go`:
// TestNewThinkingServer, TestValidate, TestFormatThought, TestProcessThought
// (its three cases), TestNewTool (the success case), TestHelperFunctions
// (padEnd and getKeys).
//
// Not ported: TestNewTool's failure case (mockey makes newThinkingServer
// return nil; the Dart constructor cannot fail) and TestHelperFunctions' `max`
// case (it tests Go's builtin, nothing of the port). Go's map order is random,
// so its getKeys test only checks membership; the port lists branches in the
// order they were first seen and the test checks that order.
//
// The tests after the ported groups were written for the port: the exact
// tool info (Go's reflected schema, derived from the Go code), the exact box
// drawn for a thought (Go measures it in bytes of UTF-8), the JSON answer,
// the state across calls, sonic's key matching, and invalid arguments.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/src/components/component_type.dart';
import 'package:threepio_core/src/components/tool/sequential_thinking/sequential_thinking_tool.dart';
import 'package:threepio_core/src/core/run_context.dart';
import 'package:threepio_core/src/errors.dart';

final String _thoughtIcon = String.fromCharCode(0x1F4AD);
final String _revisionIcon = String.fromCharCode(0x1F504);
final String _branchIcon = String.fromCharCode(0x1F33F);

/// The box Go's formatThought draws, from its parts.
String _box(String header, String thought, int width) {
  String c(int code) => String.fromCharCode(code);
  final border = '-' * width;
  final v = c(0x2502);
  return '\n${c(0x250C)}$border${c(0x2510)}\n'
      '$v $header $v\n'
      '${c(0x251C)}$border${c(0x2524)}\n'
      '$v $thought $v\n'
      '${c(0x2514)}$border${c(0x2518)}';
}

void main() {
  final ctx = RunContext.background();

  group('TestNewThinkingServer', () {
    test('a new tool has no thoughts and no branches', () {
      final tool = SequentialThinkingTool();
      expect(tool.thoughtHistory, isEmpty);
      expect(tool.branches, isEmpty);
    });
  });

  group('TestValidate', () {
    test('Test validate with valid input', () {
      const input = SequentialThoughtRequest(
        thought: 'This is a test thought',
        thoughtNumber: 1,
        totalThoughts: 3,
        nextThoughtNeeded: true,
      );
      final td = SequentialThinkingTool.validateThought(input);
      expect(td.thought, 'This is a test thought');
      expect(td.thoughtNumber, 1);
      expect(td.totalThoughts, 3);
      expect(td.nextThoughtNeeded, isTrue);
      expect(td.isRevision, isFalse);
      expect(td, input);
    });

    test('Test validate with missing required fields', () {
      // Missing thought
      var td = SequentialThinkingTool.validateThought(
        const SequentialThoughtRequest(
          thoughtNumber: 1,
          totalThoughts: 3,
          nextThoughtNeeded: true,
        ),
      );
      expect(td.thought, "The Parameter's thought should not empty");
      expect(td.thoughtNumber, 1);
      expect(td.totalThoughts, 3);
      expect(td.isRevision, isTrue);
      expect(td.revisesThought, 1);
      expect(td.nextThoughtNeeded, isTrue);

      // Invalid thought number
      td = SequentialThinkingTool.validateThought(
        const SequentialThoughtRequest(
          thought: 'This is a test thought',
          totalThoughts: 3,
          nextThoughtNeeded: true,
        ),
      );
      expect(td.thought, 'Thought number must be greater than 0');
      expect(td.thoughtNumber, 0);
      expect(td.totalThoughts, 3);
      expect(td.isRevision, isTrue);
      expect(td.revisesThought, 0);

      // Invalid total thoughts
      td = SequentialThinkingTool.validateThought(
        const SequentialThoughtRequest(
          thought: 'This is a test thought',
          thoughtNumber: 1,
          nextThoughtNeeded: true,
        ),
      );
      expect(td.thought, 'Thought number cannot exceed total thoughts');
      expect(td.thoughtNumber, 1);
      expect(td.totalThoughts, 0);
      expect(td.isRevision, isTrue);
      expect(td.revisesThought, 1);
    });
  });

  group('TestFormatThought', () {
    test('Test formatThought with regular thought', () {
      final formatted = SequentialThinkingTool.formatThought(
        const SequentialThoughtRequest(
          thought: 'This is a regular thought',
          thoughtNumber: 1,
          totalThoughts: 3,
          nextThoughtNeeded: true,
        ),
      );
      expect(formatted, contains('$_thoughtIcon Thought 1/3'));
      expect(formatted, contains('This is a regular thought'));
    });

    test('Test formatThought with revision thought', () {
      final formatted = SequentialThinkingTool.formatThought(
        const SequentialThoughtRequest(
          thought: 'This is a revision thought',
          thoughtNumber: 2,
          totalThoughts: 3,
          isRevision: true,
          revisesThought: 1,
          nextThoughtNeeded: true,
        ),
      );
      expect(formatted, contains('$_revisionIcon Revision 2/3'));
      expect(formatted, contains('revising thought 1'));
      expect(formatted, contains('This is a revision thought'));
    });

    test('Test formatThought with branch thought', () {
      final formatted = SequentialThinkingTool.formatThought(
        const SequentialThoughtRequest(
          thought: 'This is a branch thought',
          thoughtNumber: 2,
          totalThoughts: 4,
          branchFromThought: 1,
          branchId: 'branch-1',
          nextThoughtNeeded: true,
        ),
      );
      expect(formatted, contains('$_branchIcon Branch 2/4'));
      expect(formatted, contains('from thought 1'));
      expect(formatted, contains('ID: branch-1'));
      expect(formatted, contains('This is a branch thought'));
    });
  });

  group('TestProcessThought', () {
    // Convey runs the outer block again for every case: each one gets a new
    // server.
    test('Test process valid thought', () {
      final tool = SequentialThinkingTool();
      final result = tool.processThought(
        ctx,
        const SequentialThoughtRequest(
          thought: 'First thought',
          thoughtNumber: 1,
          totalThoughts: 3,
          nextThoughtNeeded: true,
        ),
      );
      expect(result.content, contains('First thought'));
      expect(result.thoughtNumber, 1);
      expect(result.totalThoughts, 3);
      expect(result.nextThoughtNeeded, isTrue);
      expect(result.thoughtHistoryLength, 1);
    });

    test('Test thought with thought number > total thoughts', () {
      final tool = SequentialThinkingTool();
      final result = tool.processThought(
        ctx,
        const SequentialThoughtRequest(
          thought: 'Exceeding thought',
          thoughtNumber: 5,
          totalThoughts: 3,
          nextThoughtNeeded: true,
        ),
      );
      expect(result.thoughtNumber, 5);
      // Adjusted to match the thought number.
      expect(result.totalThoughts, 5);
      // Derived from Go's validate: the text is replaced as well.
      expect(
        result.content,
        contains('$_revisionIcon Revision 5/5 (revising thought 5)'),
      );
      expect(
        result.content,
        contains('Thought number cannot exceed total thoughts'),
      );
    });

    test('Test branching thought', () {
      final tool = SequentialThinkingTool();
      tool.processThought(
        ctx,
        const SequentialThoughtRequest(
          thought: 'First thought',
          thoughtNumber: 1,
          totalThoughts: 3,
          nextThoughtNeeded: true,
        ),
      );
      final result = tool.processThought(
        ctx,
        const SequentialThoughtRequest(
          thought: 'Branch thought',
          thoughtNumber: 2,
          totalThoughts: 4,
          branchFromThought: 1,
          branchId: 'test-branch',
          nextThoughtNeeded: true,
        ),
      );
      expect(result.thoughtHistoryLength, 2);
      expect(result.branches, hasLength(1));
      expect(result.branches[0], 'test-branch');
    });
  });

  group('TestNewTool', () {
    test('creates a tool', () async {
      final tool = SequentialThinkingTool();
      expect((await tool.info()).name, 'sequentialthinking');
    });
  });

  group('TestHelperFunctions', () {
    test('Test padEnd function', () {
      expect(SequentialThinkingTool.padEnd('test', 8), 'test    ');
      expect(SequentialThinkingTool.padEnd('test', 4), 'test');
      expect(SequentialThinkingTool.padEnd('test', 2), 'test');
    });

    test('Test getKeys function', () {
      final tool = SequentialThinkingTool();
      for (final id in ['key1', 'key2']) {
        tool.processThought(
          ctx,
          SequentialThoughtRequest(
            thought: 't',
            thoughtNumber: 1,
            totalThoughts: 1,
            branchId: id,
          ),
        );
      }
      expect(tool.branches.keys, ['key1', 'key2']);
    });
  });

  group('tool info', () {
    test('name, description and parameters are those of Go', () async {
      final info = await SequentialThinkingTool().info();
      expect(info.name, 'sequentialthinking');
      expect(info.name, SequentialThinkingTool.toolName);
      final desc = info.desc!;
      expect(desc, SequentialThinkingTool.description);
      // Measured on Go's toolDesc: 2781 bytes (all ASCII), 54 line breaks.
      expect(desc.length, 2781);
      expect('\n'.allMatches(desc), hasLength(54));
      expect(
        desc,
        startsWith(
          'A detailed tool for dynamic and reflective problem-solving through '
          'thoughts.\nThis tool helps analyze',
        ),
      );
      expect(
        desc,
        endsWith(
          '11. Only set next_thought_needed to false when truly done and a '
          'satisfactory answer is reached\n',
        ),
      );
      expect(desc, contains('even at the "end"\n4. Express uncertainty'));

      // Go's InferTool reflects ThoughtRequest with jsonschema.Reflector
      // (DoNotReference): the fields in struct order, the ones without
      // omitempty required, additionalProperties false; jsonschema.Schema
      // writes `type` after the other keys. Derived from the Go code.
      expect(
        jsonEncode(info.function.parametersJsonSchema),
        '{"properties":{'
        '"thought":{"description":"Your current thinking step","type":"string"},'
        '"thought_number":{"description":"Current thought number","type":"integer"},'
        '"total_thoughts":{"description":"Estimated total thoughts needed","type":"integer"},'
        '"is_revision":{"description":"Whether this revises previous thinking","type":"boolean"},'
        '"revises_thought":{"description":"Which thought is being reconsidered","type":"integer"},'
        '"branch_from_thought":{"description":"Branching point thought number","type":"integer"},'
        '"branch_id":{"description":"Branch identifier","type":"string"},'
        '"needs_more_thoughts":{"description":"If more thoughts are needed","type":"boolean"},'
        '"next_thought_needed":{"description":"Whether another thought step is needed","type":"boolean"}'
        '},"additionalProperties":false,'
        '"required":["thought","thought_number","total_thoughts","next_thought_needed"],'
        '"type":"object"}',
      );
      expect(info.paramsOneOf!.jsonSchemaMap, info.function.parametersJsonSchema);
      // The JSONSchema view of it, for code that reads `parameters`.
      final schema = info.paramsOneOf!.toJsonSchema();
      expect(schema.properties.keys, [
        'thought',
        'thought_number',
        'total_thoughts',
        'is_revision',
        'revises_thought',
        'branch_from_thought',
        'branch_id',
        'needs_more_thoughts',
        'next_thought_needed',
      ]);
      expect(schema.properties['thought_number']!.type, 'integer');
      expect(schema.required, [
        'thought',
        'thought_number',
        'total_thoughts',
        'next_thought_needed',
      ]);
      expect(schema.additionalProperties, isFalse);
    });

    test('the component type is the one InferTool derives', () {
      expect(componentTypeNameOf(SequentialThinkingTool()), 'Sequentialthinking');
    });
  });

  group('formatThought draws Go bytes', () {
    test('a regular thought', () {
      // Header: 4 bytes of emoji + " Thought 1/3" = 16 bytes; thought: 25.
      expect(
        SequentialThinkingTool.formatThought(
          const SequentialThoughtRequest(
            thought: 'This is a regular thought',
            thoughtNumber: 1,
            totalThoughts: 3,
          ),
        ),
        _box(
          '$_thoughtIcon Thought 1/3${' ' * 11}',
          'This is a regular thought  ',
          29,
        ),
      );
    });

    test('a header longer than the thought', () {
      // Header: 4 + " Revision 2/3 (revising thought 1)" (34) = 38 bytes;
      // a border of 42.
      expect(
        SequentialThinkingTool.formatThought(
          const SequentialThoughtRequest(
            thought: 'short',
            thoughtNumber: 2,
            totalThoughts: 3,
            isRevision: true,
            revisesThought: 1,
          ),
        ),
        _box(
          '$_revisionIcon Revision 2/3 (revising thought 1)  ',
          'short${' ' * 35}',
          42,
        ),
      );
    });

    test('a branch, and non-ASCII text measured in bytes', () {
      // Header: 4 + " Branch 3/4 (from thought 2, ID: b)" (35) = 39 bytes;
      // the thought is two characters of three bytes each: a border of 43.
      final thought = String.fromCharCodes([0x65E5, 0x672C]);
      expect(
        SequentialThinkingTool.formatThought(
          SequentialThoughtRequest(
            thought: thought,
            thoughtNumber: 3,
            totalThoughts: 4,
            branchFromThought: 2,
            branchId: 'b',
          ),
        ),
        _box(
          '$_branchIcon Branch 3/4 (from thought 2, ID: b)  ',
          '$thought${' ' * 35}',
          43,
        ),
      );
    });

    test('a revision wins over a branch', () {
      final formatted = SequentialThinkingTool.formatThought(
        const SequentialThoughtRequest(
          thought: 't',
          thoughtNumber: 2,
          totalThoughts: 2,
          isRevision: true,
          revisesThought: 1,
          branchFromThought: 1,
          branchId: 'b',
        ),
      );
      expect(formatted, contains('Revision 2/2 (revising thought 1)'));
      expect(formatted, isNot(contains('Branch')));
    });

    test('padEnd counts bytes', () {
      final e = String.fromCharCode(0xE9);
      expect(SequentialThinkingTool.padEnd('${e}a', 5), '${e}a  ');
    });
  });

  group('invokableRun', () {
    test('answers with the result as Go encodes it', () async {
      final tool = SequentialThinkingTool();
      final answer = await tool.invokableRun(
        ctx,
        jsonEncode({
          'thought': 'First thought',
          'thought_number': 1,
          'total_thoughts': 3,
          'next_thought_needed': true,
        }),
      );
      // Header 16 bytes, thought 13: a border of 20.
      final content = _box(
        '$_thoughtIcon Thought 1/3  ',
        'First thought${' ' * 5}',
        20,
      );
      expect(
        answer,
        '{"content":${jsonEncode(content)},"thought_number":1,'
        '"total_thoughts":3,"next_thought_needed":true,"branches":[],'
        '"thought_history_length":1}',
      );
      final decoded = SequentialThoughtResult.fromJson(
        jsonDecode(answer) as Map<String, Object?>,
      );
      expect(decoded.content, content);
      expect(decoded.branches, isEmpty);
    });

    test('keeps the thoughts and branches across calls', () async {
      final tool = SequentialThinkingTool();
      Future<SequentialThoughtResult> send(Map<String, Object?> args) async =>
          SequentialThoughtResult.fromJson(
            jsonDecode(await tool.invokableRun(ctx, jsonEncode(args)))
                as Map<String, Object?>,
          );

      var result = await send({
        'thought': 'a',
        'thought_number': 1,
        'total_thoughts': 3,
        'next_thought_needed': true,
      });
      expect(result.thoughtHistoryLength, 1);
      expect(result.branches, isEmpty);

      result = await send({
        'thought': 'b',
        'thought_number': 2,
        'total_thoughts': 3,
        'branch_from_thought': 1,
        'branch_id': 'b2',
        'next_thought_needed': true,
      });
      expect(result.branches, ['b2']);

      result = await send({
        'thought': 'c',
        'thought_number': 3,
        'total_thoughts': 3,
        'branch_from_thought': 1,
        'branch_id': 'b1',
        'next_thought_needed': true,
      });
      expect(result.branches, ['b2', 'b1']);

      result = await send({
        'thought': 'd',
        'thought_number': 4,
        'total_thoughts': 3,
        'branch_id': 'b2',
        'next_thought_needed': false,
      });
      expect(result.thoughtHistoryLength, 4);
      expect(result.branches, ['b2', 'b1']);
      expect(result.thoughtNumber, 4);
      expect(result.totalThoughts, 4);
      expect(result.nextThoughtNeeded, isFalse);

      expect(tool.thoughtHistory.map((t) => t.thought), [
        'a',
        'b',
        'c',
        'Thought number cannot exceed total thoughts',
      ]);
      expect(tool.thoughtHistory.last.totalThoughts, 4);
      expect(tool.branches['b2']!.map((t) => t.thoughtNumber), [2, 4]);
      expect(tool.branches['b1']!.map((t) => t.thoughtNumber), [3]);
      expect(() => tool.thoughtHistory.add(const SequentialThoughtRequest()),
          throwsUnsupportedError);

      // Another tool is another conversation.
      final other = SequentialThinkingTool();
      expect(other.thoughtHistory, isEmpty);
      expect(
        await other.invokableRun(
          ctx,
          '{"thought":"x","thought_number":1,"total_thoughts":1}',
        ),
        endsWith('"thought_history_length":1}'),
      );
    });

    test('empty arguments are a thought with zero values', () async {
      final tool = SequentialThinkingTool();
      final result = SequentialThoughtResult.fromJson(
        jsonDecode(await tool.invokableRun(ctx, '{}')) as Map<String, Object?>,
      );
      // Number and total below 1: the last of Go's checks wins.
      expect(
        result.content,
        // Header 38 bytes, thought 37: a border of 42.
        _box(
          '$_revisionIcon Revision 0/0 (revising thought 0)  ',
          'Total thoughts must be greater than 0   ',
          42,
        ),
      );
      expect(tool.thoughtHistory.single.isRevision, isTrue);
      expect(tool.thoughtHistory.single.revisesThought, 0);
    });

    test('arguments of the wrong type are refused', () async {
      final tool = SequentialThinkingTool();
      for (final args in [
        '{"thought":"t","thought_number":"1","total_thoughts":1}',
        '{"thought":"t","thought_number":1.5,"total_thoughts":2}',
        '{"thought":1,"thought_number":1,"total_thoughts":1}',
        '{"thought":"t","thought_number":1,"total_thoughts":1,"is_revision":"yes"}',
        '[]',
        'null',
        '{"thought":',
      ]) {
        await expectLater(
          tool.invokableRun(ctx, args),
          throwsA(isA<ThreepioFormatException>()),
          reason: args,
        );
      }
      expect(tool.thoughtHistory, isEmpty);
    });

    test('a field of the wrong type is named in the error', () async {
      await expectLater(
        SequentialThinkingTool().invokableRun(
          ctx,
          '{"thought":"t","thought_number":1.5,"total_thoughts":2}',
        ),
        throwsA(
          isA<ThreepioFormatException>().having(
            (e) => e.message,
            'message',
            contains(
              'mismatched type with value: "thought_number" must be an '
              'integer, got 1.5',
            ),
          ),
        ),
      );
    });

    test('unknown fields and nulls are ignored', () async {
      final tool = SequentialThinkingTool();
      await tool.invokableRun(
        ctx,
        '{"thought":"t","thought_number":1,"total_thoughts":2,'
        '"branch_id":null,"extra":[1,2]}',
      );
      expect(tool.thoughtHistory.single, const SequentialThoughtRequest(
        thought: 't',
        thoughtNumber: 1,
        totalThoughts: 2,
      ));
    });

    test('keys match ignoring case, as sonic decodes them', () async {
      final tool = SequentialThinkingTool();
      final dottedCapitalI = String.fromCharCode(0x0130);
      await tool.invokableRun(
        ctx,
        jsonEncode({
          'Thought': 'first',
          'THOUGHT_NUMBER': 2,
          'Total_Thoughts': 3,
          'Branch_ID': 'b',
          'NEEDS_MORE_THOUGHTS': true,
          // strings.ToLower makes the dotted capital I an i.
          '${dottedCapitalI}S_REVISION': true,
          'revises_thought': 1,
          // A later key overwrites an earlier one; null changes nothing.
          'thought': 'second',
          'tHoUgHt': null,
          'next_thought_needed': true,
        }),
      );
      expect(
        tool.thoughtHistory.single,
        const SequentialThoughtRequest(
          thought: 'second',
          thoughtNumber: 2,
          totalThoughts: 3,
          isRevision: true,
          revisesThought: 1,
          branchId: 'b',
          needsMoreThoughts: true,
          nextThoughtNeeded: true,
        ),
      );
      // strings.ToLower leaves the long s as it is (encoding/json would fold
      // it to s; sonic does not).
      final longS = String.fromCharCode(0x017F);
      expect(
        SequentialThoughtRequest.fromJson({'i${longS}_revision': true}),
        const SequentialThoughtRequest(),
      );
      // The first field of the wrong type fails, whatever follows.
      expect(
        () => SequentialThoughtRequest.fromJson(
            {'Thought_Number': '1', 'thought_number': 1}),
        throwsA(isA<ThreepioFormatException>().having((e) => e.message,
            'message', contains('"thought_number" must be an integer'))),
      );
    });

    test('run is invokableRun', () async {
      final tool = SequentialThinkingTool();
      expect(
        await tool.run('{"thought":"t","thought_number":1,"total_thoughts":1}'),
        contains('"thought_history_length":1'),
      );
    });
  });

  group('value types', () {
    test('a request writes Go JSON and reads it back', () {
      const request = SequentialThoughtRequest(
        thought: 't',
        thoughtNumber: 2,
        totalThoughts: 3,
        nextThoughtNeeded: true,
      );
      expect(request.toJson(), {
        'thought': 't',
        'thought_number': 2,
        'total_thoughts': 3,
        'next_thought_needed': true,
      });
      expect(SequentialThoughtRequest.fromJson(request.toJson()), request);

      const full = SequentialThoughtRequest(
        thought: 't',
        thoughtNumber: 2,
        totalThoughts: 3,
        isRevision: true,
        revisesThought: 1,
        branchFromThought: 1,
        branchId: 'b',
        needsMoreThoughts: true,
      );
      expect(full.toJson().keys, [
        'thought',
        'thought_number',
        'total_thoughts',
        'is_revision',
        'revises_thought',
        'branch_from_thought',
        'branch_id',
        'needs_more_thoughts',
        'next_thought_needed',
      ]);
      expect(SequentialThoughtRequest.fromJson(full.toJson()), full);
      expect(full.hashCode, SequentialThoughtRequest.fromJson(full.toJson()).hashCode);
    });

    test('a result reads back what it writes', () {
      final result = SequentialThoughtResult(
        content: 'c',
        thoughtNumber: 1,
        totalThoughts: 2,
        nextThoughtNeeded: true,
        branches: const ['x'],
        thoughtHistoryLength: 3,
      );
      expect(result.toJson().keys, [
        'content',
        'thought_number',
        'total_thoughts',
        'next_thought_needed',
        'branches',
        'thought_history_length',
      ]);
      expect(SequentialThoughtResult.fromJson(result.toJson()), result);
      expect(() => result.branches.add('y'), throwsUnsupportedError);
      expect(
        () => SequentialThoughtResult.fromJson(const {'branches': [1]}),
        throwsA(isA<ThreepioFormatException>()),
      );
    });
  });
}
