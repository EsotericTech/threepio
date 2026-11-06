// Port of eino-ext `callbacks/langsmith/trace_test.go`: TestSetTrace,
// TestWithSessionName, TestWithReferenceExampleID, TestWithTraceID,
// TestAddTag, TestSetMetadata ("nil initial"), TestTraceOptionChaining, with
// Go's expected values; plus tests of `LangSmithState` and its JSON.
//
// Go's options are functions applied to a struct; in Dart they are the named
// parameters of `LangSmithTrace.set`, so the option tests go through it.
// Not ported: the "merge with existing" and "overwrite existing" cases of
// TestSetMetadata, which apply `SetMetadata` twice to one set of options; a
// call of `set` takes one metadata map.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/src/callbacks/handlers/langsmith/langsmith_trace.dart';
import 'package:threepio_core/threepio_core.dart';

void main() {
  group('TestSetTrace', () {
    test('empty options', () {
      final ctx = LangSmithTrace.set(RunContext.background());
      final options = LangSmithTrace.optionsOf(ctx)!;
      expect(options.sessionName, isEmpty);
      expect(options.referenceExampleId, isEmpty);
      expect(options.tags, isEmpty);
      expect(options.traceId, isEmpty);
      expect(options.metadata, isNull);
    });

    test('with options', () {
      final ctx = LangSmithTrace.set(
        RunContext.background(),
        sessionName: 'test-project',
        referenceExampleId: 'example-123',
        traceId: 'trace-456',
        tags: ['tag1', 'tag2', 'tag1'], // a repeated tag is kept once
        metadata: {'key1': 'value1'},
      );
      final options = LangSmithTrace.optionsOf(ctx)!;
      expect(options.sessionName, 'test-project');
      expect(options.referenceExampleId, 'example-123');
      expect(options.traceId, 'trace-456');
      expect(options.tags, unorderedEquals(['tag1', 'tag2']));
      expect(options.metadata, isNotNull);
      expect(options.metadata!['key1'], 'value1');
    });

    test('a context without options has none', () {
      expect(LangSmithTrace.optionsOf(RunContext.background()), isNull);
    });
  });

  test('TestWithSessionName', () {
    final ctx =
        LangSmithTrace.set(RunContext.background(), sessionName: 'my-project');
    expect(LangSmithTrace.optionsOf(ctx)!.sessionName, 'my-project');
  });

  test('TestWithReferenceExampleID', () {
    final ctx = LangSmithTrace.set(
      RunContext.background(),
      referenceExampleId: 'example-abc',
    );
    expect(LangSmithTrace.optionsOf(ctx)!.referenceExampleId, 'example-abc');
  });

  test('TestWithTraceID', () {
    final ctx = LangSmithTrace.set(RunContext.background(), traceId: 'trace-xyz');
    expect(LangSmithTrace.optionsOf(ctx)!.traceId, 'trace-xyz');
  });

  group('TestAddTag', () {
    List<String> tagsOf(List<String> initial, String added) =>
        LangSmithTrace.optionsOf(
          LangSmithTrace.set(RunContext.background(), tags: [...initial, added]),
        )!
            .tags;

    test('add to empty', () {
      expect(tagsOf([], 'tag1'), unorderedEquals(['tag1']));
    });

    test('add new tag', () {
      expect(tagsOf(['tag1'], 'tag2'), unorderedEquals(['tag1', 'tag2']));
    });

    test('add duplicate tag', () {
      expect(tagsOf(['tag1', 'tag2'], 'tag1'), unorderedEquals(['tag1', 'tag2']));
    });

    test('the tags keep the order they were given in', () {
      expect(tagsOf(['b', 'a', 'b'], 'c'), ['b', 'a', 'c']);
    });
  });

  group('TestSetMetadata', () {
    test('nil initial', () {
      final ctx = LangSmithTrace.set(RunContext.background(), metadata: {});
      expect(LangSmithTrace.optionsOf(ctx)!.metadata, <String, Object?>{});
    });

    test('the map is copied and cannot be changed through the options', () {
      final metadata = <String, Object?>{'old': 'value'};
      final ctx = LangSmithTrace.set(RunContext.background(), metadata: metadata);
      metadata['new'] = 'data';
      final stored = LangSmithTrace.optionsOf(ctx)!.metadata!;
      expect(stored, {'old': 'value'});
      expect(() => stored['x'] = 1, throwsUnsupportedError);
    });
  });

  test('TestTraceOptionChaining', () {
    var ctx = LangSmithTrace.set(
      RunContext.background(),
      sessionName: 'project1',
      referenceExampleId: 'ref1',
      tags: ['tag1'],
      traceId: 'trace1',
    );
    // Each call replaces all the options.
    ctx = LangSmithTrace.set(ctx, sessionName: 'project2', tags: ['tag2']);

    final options = LangSmithTrace.optionsOf(ctx)!;
    expect(options.sessionName, 'project2');
    expect(options.referenceExampleId, isNot('ref1'));
    expect(options.traceId, isNot('trace1'));
    expect(options.tags, unorderedEquals(['tag2']));
  });

  group('LangSmithState', () {
    test('withState and stateOf', () {
      const state = LangSmithState(
        traceId: 't',
        parentRunId: 'p',
        parentDottedOrder: 'd',
      );
      final base = RunContext.background();
      final ctx = LangSmithTrace.withState(base, state);
      expect(LangSmithTrace.stateOf(ctx), same(state));
      expect(LangSmithTrace.stateOf(base), isNull, reason: 'contexts are values');
    });

    test('toJson has the fields of Go in its order', () {
      const state = LangSmithState(
        traceId: 'test-trace-id',
        parentRunId: 'test-parent-id',
        parentDottedOrder: 'test.dotted.order',
        metadata: {'key': 'value'},
        tags: ['tag1', 'tag2'],
      );
      expect(
        jsonEncode(state.toJson()),
        '{"trace_id":"test-trace-id","parent_run_id":"test-parent-id",'
        '"parent_dotted_order":"test.dotted.order","metadata":{},'
        '"tags":["tag1","tag2"],"marshal_metadata":{"key":"value"}}',
      );
    });

    test('toJson of an empty state', () {
      expect(
        jsonEncode(const LangSmithState().toJson()),
        '{"trace_id":"","parent_run_id":"","parent_dotted_order":"",'
        '"metadata":null,"tags":null,"marshal_metadata":{}}',
      );
    });

    test('fromJson reads what Go writes', () {
      final state = LangSmithState.fromJson(
        jsonDecode(
          '{"trace_id":"test-trace","parent_run_id":"test-parent",'
          '"parent_dotted_order":"test.order","metadata":{},'
          '"marshal_metadata":{"key":"value"},"tags":["tag1","tag2"]}',
        ) as Map<String, Object?>,
      );
      expect(state.traceId, 'test-trace');
      expect(state.parentRunId, 'test-parent');
      expect(state.parentDottedOrder, 'test.order');
      expect(state.metadata, {'key': 'value'});
      expect(state.tags, ['tag1', 'tag2']);
    });

    test('fromJson without marshal_metadata', () {
      expect(
        LangSmithState.fromJson(const {'metadata': <String, Object?>{}}).metadata,
        isEmpty,
        reason: "Go's sync.Map decodes to an empty map",
      );
      expect(LangSmithState.fromJson(const {}).metadata, isNull);
      final empty = LangSmithState.fromJson(const {});
      expect(empty.traceId, isEmpty);
      expect(empty.tags, isNull);
    });

    test('fromJson refuses fields of the wrong type', () {
      for (final json in <Map<String, Object?>>[
        {'trace_id': 5},
        {'tags': 'tag'},
        {
          'tags': [1],
        },
        {'marshal_metadata': 'x'},
      ]) {
        expect(
          () => LangSmithState.fromJson(json),
          throwsA(isA<ThreepioFormatException>()),
          reason: '$json',
        );
      }
    });

    test('values that are not JSON are written as threepio writes them', () {
      final state = LangSmithState(
        metadata: {
          'message': Message.user('hi'),
          'when': DateTime.utc(2025),
        },
      );
      final json = state.toJson()['marshal_metadata']! as Map<String, Object?>;
      expect(json['message'], {'role': 'user', 'content': 'hi'});
      expect(json['when'], '2025-01-01T00:00:00.000Z');
    });
  });
}
