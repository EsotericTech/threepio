import 'package:test/test.dart';
import 'package:threepio_core/src/callbacks/callback_handler.dart';
import 'package:threepio_core/src/callbacks/callback_manager.dart';
import 'package:threepio_core/src/callbacks/run_info.dart';
import 'package:threepio_core/src/callbacks/handlers/logging_handler.dart';
import 'package:threepio_core/src/callbacks/handlers/metrics_handler.dart';
import 'package:threepio_core/src/callbacks/handlers/tracing_handler.dart';

/// Test callback handler that records calls
class RecordingHandler extends BaseCallbackHandler {
  final List<String> calls = [];

  @override
  Future<Map<String, dynamic>> onStart(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackInput input,
  ) async {
    calls.add('start:${info.name}');
    return context;
  }

  @override
  Future<Map<String, dynamic>> onEnd(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackOutput output,
  ) async {
    calls.add('end:${info.name}');
    return context;
  }

  @override
  Future<Map<String, dynamic>> onError(
    Map<String, dynamic> context,
    RunInfo info,
    Object error,
    StackTrace stackTrace,
  ) async {
    calls.add('error:${info.name}');
    return context;
  }

  @override
  Future<Map<String, dynamic>> onStartWithStreamInput(
    Map<String, dynamic> context,
    RunInfo info,
    Stream<dynamic> input,
  ) async {
    calls.add('stream_start:${info.name}');
    return context;
  }

  @override
  Future<Map<String, dynamic>> onEndWithStreamOutput(
    Map<String, dynamic> context,
    RunInfo info,
    Stream<dynamic> output,
  ) async {
    calls.add('stream_end:${info.name}');
    return context;
  }
}

/// Handler that modifies context
class ContextModifyingHandler extends BaseCallbackHandler {
  @override
  Future<Map<String, dynamic>> onStart(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackInput input,
  ) async {
    final updated = Map<String, dynamic>.from(context);
    updated['started'] = true;
    updated['component'] = info.name;
    return updated;
  }

  @override
  Future<Map<String, dynamic>> onEnd(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackOutput output,
  ) async {
    final updated = Map<String, dynamic>.from(context);
    updated['completed'] = true;
    return updated;
  }
}

void main() {
  group('RunInfo', () {
    test('creates with required fields', () {
      final info = RunInfo(
        name: 'test_component',
        type: 'TestType',
        componentType: ComponentType.chain,
      );

      expect(info.name, equals('test_component'));
      expect(info.type, equals('TestType'));
      expect(info.componentType, equals(ComponentType.chain));
      expect(info.metadata, isNull);
    });

    test('supports metadata', () {
      final info = RunInfo(
        name: 'test',
        type: 'Test',
        componentType: ComponentType.chatModel,
        metadata: {'key': 'value'},
      );

      expect(info.metadata, equals({'key': 'value'}));
    });

    test('copyWith creates modified copy', () {
      final original = RunInfo(
        name: 'original',
        type: 'Type1',
        componentType: ComponentType.tool,
      );

      final modified = original.copyWith(name: 'modified');

      expect(modified.name, equals('modified'));
      expect(modified.type, equals('Type1'));
      expect(modified.componentType, equals(ComponentType.tool));
    });

    test('equality works', () {
      final info1 = RunInfo(
        name: 'test',
        type: 'Test',
        componentType: ComponentType.chain,
      );

      final info2 = RunInfo(
        name: 'test',
        type: 'Test',
        componentType: ComponentType.chain,
      );

      expect(info1, equals(info2));
      expect(info1.hashCode, equals(info2.hashCode));
    });
  });

  group('CallbackInput/Output', () {
    test('CallbackInput wraps data', () {
      final input = CallbackInput('test data', metadata: {'key': 'value'});

      expect(input.data, equals('test data'));
      expect(input.metadata, equals({'key': 'value'}));
    });

    test('CallbackOutput wraps data', () {
      final output = CallbackOutput(42, metadata: {'result': true});

      expect(output.data, equals(42));
      expect(output.metadata, equals({'result': true}));
    });
  });

  group('BaseCallbackHandler', () {
    test('provides no-op default implementations', () async {
      final handler = RecordingHandler();
      final context = <String, dynamic>{};
      final info = RunInfo(
        name: 'test',
        type: 'Test',
        componentType: ComponentType.runnable,
      );

      // Should not throw
      final result = await handler.onStart(
        context,
        info,
        const CallbackInput('input'),
      );

      expect(result, isNotNull);
    });
  });

  group('CallbackManager', () {
    test('manages multiple handlers', () {
      final handler1 = RecordingHandler();
      final handler2 = RecordingHandler();

      final manager = CallbackManager([handler1, handler2]);

      expect(manager.handlers, hasLength(2));
      expect(manager.handlers, contains(handler1));
      expect(manager.handlers, contains(handler2));
    });

    test('addHandler adds a handler', () {
      final manager = CallbackManager();
      final handler = RecordingHandler();

      manager.addHandler(handler);

      expect(manager.handlers, contains(handler));
    });

    test('removeHandler removes a handler', () {
      final handler = RecordingHandler();
      final manager = CallbackManager([handler]);

      final removed = manager.removeHandler(handler);

      expect(removed, isTrue);
      expect(manager.handlers, isNot(contains(handler)));
    });

    test('triggerStart calls all handlers', () async {
      final handler1 = RecordingHandler();
      final handler2 = RecordingHandler();
      final manager = CallbackManager([handler1, handler2]);

      final info = RunInfo(
        name: 'test',
        type: 'Test',
        componentType: ComponentType.chain,
      );

      await manager.triggerStart(
        {},
        info,
        const CallbackInput('input'),
      );

      expect(handler1.calls, contains('start:test'));
      expect(handler2.calls, contains('start:test'));
    });

    test('triggerEnd calls all handlers', () async {
      final handler1 = RecordingHandler();
      final handler2 = RecordingHandler();
      final manager = CallbackManager([handler1, handler2]);

      final info = RunInfo(
        name: 'test',
        type: 'Test',
        componentType: ComponentType.chain,
      );

      await manager.triggerEnd(
        {},
        info,
        const CallbackOutput('output'),
      );

      expect(handler1.calls, contains('end:test'));
      expect(handler2.calls, contains('end:test'));
    });

    test('triggerError calls all handlers', () async {
      final handler1 = RecordingHandler();
      final handler2 = RecordingHandler();
      final manager = CallbackManager([handler1, handler2]);

      final info = RunInfo(
        name: 'test',
        type: 'Test',
        componentType: ComponentType.chain,
      );

      await manager.triggerError(
        {},
        info,
        Exception('test error'),
        StackTrace.current,
      );

      expect(handler1.calls, contains('error:test'));
      expect(handler2.calls, contains('error:test'));
    });

    test('context flows through handlers', () async {
      final handler1 = ContextModifyingHandler();
      final handler2 = RecordingHandler();
      final manager = CallbackManager([handler1, handler2]);

      final info = RunInfo(
        name: 'test',
        type: 'Test',
        componentType: ComponentType.chain,
      );

      var context = <String, dynamic>{};

      context = await manager.triggerStart(
        context,
        info,
        const CallbackInput('input'),
      );

      expect(context['started'], isTrue);
      expect(context['component'], equals('test'));

      context = await manager.triggerEnd(
        context,
        info,
        const CallbackOutput('output'),
      );

      expect(context['completed'], isTrue);
    });

    test('runWithCallbacks executes function with callbacks', () async {
      final handler = RecordingHandler();
      final manager = CallbackManager([handler]);

      final info = RunInfo(
        name: 'test',
        type: 'Test',
        componentType: ComponentType.chain,
      );

      final result = await manager.runWithCallbacks(
        {},
        info,
        'input',
        () async {
          return 42;
        },
      );

      expect(result, equals(42));
      expect(handler.calls, contains('start:test'));
      expect(handler.calls, contains('end:test'));
    });

    test('runWithCallbacks triggers error on failure', () async {
      final handler = RecordingHandler();
      final manager = CallbackManager([handler]);

      final info = RunInfo(
        name: 'test',
        type: 'Test',
        componentType: ComponentType.chain,
      );

      // Properly await the async exception
      try {
        await manager.runWithCallbacks(
          {},
          info,
          'input',
          () async {
            throw Exception('test error');
          },
        );
        fail('Should have thrown exception');
      } catch (e) {
        // Expected exception
      }

      expect(handler.calls, contains('start:test'));
      expect(handler.calls, contains('error:test'));
    });

    test('global handlers apply to all managers', () async {
      final globalHandler = RecordingHandler();
      CallbackManager.addGlobalHandler(globalHandler);

      final localHandler = RecordingHandler();
      final manager = CallbackManager([localHandler]);

      final info = RunInfo(
        name: 'test',
        type: 'Test',
        componentType: ComponentType.chain,
      );

      await manager.triggerStart(
        {},
        info,
        const CallbackInput('input'),
      );

      expect(localHandler.calls, contains('start:test'));
      expect(globalHandler.calls, contains('start:test'));

      CallbackManager.clearGlobalHandlers();
    });

    test('withHandlers creates copy with additional handlers', () {
      final handler1 = RecordingHandler();
      final handler2 = RecordingHandler();
      final handler3 = RecordingHandler();

      final manager1 = CallbackManager([handler1]);
      final manager2 = manager1.withHandlers([handler2, handler3]);

      // Original unchanged
      expect(manager1.handlers.length, equals(1));

      // New manager has all handlers
      expect(manager2.handlers.length, equals(3));
      expect(manager2.handlers, contains(handler1));
      expect(manager2.handlers, contains(handler2));
      expect(manager2.handlers, contains(handler3));
    });
  });

  group('LoggingHandler', () {
    test('logs start and end events', () async {
      final handler = LoggingHandler();
      final info = RunInfo(
        name: 'test_component',
        type: 'TestType',
        componentType: ComponentType.chain,
      );

      // These will print to console - testing they don't throw
      await handler.onStart({}, info, const CallbackInput('input'));
      await handler.onEnd({}, info, const CallbackOutput('output'));
    });

    test('verbose mode logs more details', () async {
      final handler = LoggingHandler(verbose: true, logInputs: true);
      final info = RunInfo(
        name: 'test',
        type: 'Test',
        componentType: ComponentType.chatModel,
        metadata: {'model': 'gpt-4'},
      );

      await handler.onStart({}, info, const CallbackInput('test input'));
    });
  });

  group('MetricsHandler', () {
    test('collects execution metrics', () async {
      final handler = MetricsHandler();
      final manager = CallbackManager([handler]);

      final info = RunInfo(
        name: 'test',
        type: 'Test',
        componentType: ComponentType.chain,
      );

      await manager.runWithCallbacks(
        {},
        info,
        'input',
        () async {
          await Future.delayed(const Duration(milliseconds: 10));
          return 42;
        },
      );

      expect(handler.metrics, hasLength(1));
      final metric = handler.metrics.first;

      expect(metric.componentName, equals('test'));
      expect(metric.isSuccess, isTrue);
      expect(metric.duration, isNotNull);
      expect(metric.duration!.inMilliseconds, greaterThan(0));
    });

    test('records errors in metrics', () async {
      final handler = MetricsHandler();
      final manager = CallbackManager([handler]);

      final info = RunInfo(
        name: 'test',
        type: 'Test',
        componentType: ComponentType.chain,
      );

      try {
        await manager.runWithCallbacks(
          {},
          info,
          'input',
          () async {
            throw Exception('test error');
          },
        );
      } catch (e) {
        // Expected
      }

      expect(handler.metrics, hasLength(1));
      final metric = handler.metrics.first;

      expect(metric.isFailed, isTrue);
      expect(metric.error, isNotNull);
    });

    test('getMetricsFor filters by component', () async {
      final handler = MetricsHandler();
      final manager = CallbackManager([handler]);

      final info1 = RunInfo(
        name: 'component1',
        type: 'Test',
        componentType: ComponentType.chain,
      );

      final info2 = RunInfo(
        name: 'component2',
        type: 'Test',
        componentType: ComponentType.chain,
      );

      await manager.runWithCallbacks({}, info1, 'input', () async => 1);
      await manager.runWithCallbacks({}, info2, 'input', () async => 2);
      await manager.runWithCallbacks({}, info1, 'input', () async => 3);

      final metrics1 = handler.getMetricsFor('component1');
      final metrics2 = handler.getMetricsFor('component2');

      expect(metrics1, hasLength(2));
      expect(metrics2, hasLength(1));
    });

    test('getAverageDuration calculates correctly', () async {
      final handler = MetricsHandler();
      final manager = CallbackManager([handler]);

      final info = RunInfo(
        name: 'test',
        type: 'Test',
        componentType: ComponentType.chain,
      );

      // Run multiple times
      for (var i = 0; i < 3; i++) {
        await manager.runWithCallbacks(
          {},
          info,
          'input',
          () async {
            await Future.delayed(const Duration(milliseconds: 10));
            return i;
          },
        );
      }

      final avgDuration = handler.getAverageDuration('test');

      expect(avgDuration, isNotNull);
      expect(avgDuration!.inMilliseconds, greaterThan(0));
    });

    test('clear removes all metrics', () async {
      final handler = MetricsHandler();
      final manager = CallbackManager([handler]);

      final info = RunInfo(
        name: 'test',
        type: 'Test',
        componentType: ComponentType.chain,
      );

      await manager.runWithCallbacks({}, info, 'input', () async => 42);

      expect(handler.metrics, hasLength(1));

      handler.clear();

      expect(handler.metrics, isEmpty);
    });
  });

  group('TracingHandler', () {
    test('records trace events', () async {
      final handler = TracingHandler();
      final manager = CallbackManager([handler]);

      final info = RunInfo(
        name: 'test',
        type: 'Test',
        componentType: ComponentType.chain,
      );

      await manager.runWithCallbacks(
        {},
        info,
        'input',
        () async => 42,
      );

      expect(handler.events, hasLength(2)); // start + end
      expect(handler.events[0].eventType, equals(TraceEventType.start));
      expect(handler.events[1].eventType, equals(TraceEventType.end));
    });

    test('tracks nesting depth', () async {
      final handler = TracingHandler();
      var context = <String, dynamic>{};

      final info1 = RunInfo(
        name: 'outer',
        type: 'Test',
        componentType: ComponentType.chain,
      );

      final info2 = RunInfo(
        name: 'inner',
        type: 'Test',
        componentType: ComponentType.chain,
      );

      context =
          await handler.onStart(context, info1, const CallbackInput(null));
      context =
          await handler.onStart(context, info2, const CallbackInput(null));
      context = await handler.onEnd(context, info2, const CallbackOutput(null));
      context = await handler.onEnd(context, info1, const CallbackOutput(null));

      expect(handler.events[0].depth, equals(0)); // outer start
      expect(handler.events[1].depth, equals(1)); // inner start
      expect(handler.events[2].depth, equals(1)); // inner end
      expect(handler.events[3].depth, equals(0)); // outer end
    });

    test('captureData records input/output when enabled', () async {
      final handler = TracingHandler(captureData: true);
      final manager = CallbackManager([handler]);

      final info = RunInfo(
        name: 'test',
        type: 'Test',
        componentType: ComponentType.chain,
      );

      await manager.runWithCallbacks(
        {},
        info,
        'test input',
        () async => 'test output',
      );

      expect(handler.events[0].data, equals('test input'));
      expect(handler.events[1].data, equals('test output'));
    });

    test('getTimeline calculates durations', () async {
      final handler = TracingHandler();
      final manager = CallbackManager([handler]);

      final info = RunInfo(
        name: 'test',
        type: 'Test',
        componentType: ComponentType.chain,
      );

      await manager.runWithCallbacks(
        {},
        info,
        'input',
        () async {
          await Future.delayed(const Duration(milliseconds: 10));
          return 42;
        },
      );

      final timeline = handler.getTimeline();

      expect(timeline, containsPair('test', isA<Duration>()));
      expect(timeline['test']!.inMilliseconds, greaterThan(0));
    });

    test('clear removes all events', () {
      final handler = TracingHandler();

      handler.events.add(TraceEvent(
        timestamp: DateTime.now(),
        eventType: TraceEventType.start,
        componentName: 'test',
        componentType: 'Test',
      ));

      expect(handler.events, hasLength(1));

      handler.clear();

      expect(handler.events, isEmpty);
    });
  });
}
