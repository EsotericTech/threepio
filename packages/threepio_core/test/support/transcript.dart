import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:threepio_core/threepio_core.dart';

import 'scripted_chat_model.dart';

/// Set this environment variable to `1` to write the golden files instead of
/// comparing with them:
///
/// ```sh
/// THREEPIO_UPDATE_GOLDENS=1 tool/run_capped.sh 60 4096 \
///   dart test -j 1 test/adk/golden/runtime_transcripts_test.dart
/// ```
const updateGoldensVariable = 'THREEPIO_UPDATE_GOLDENS';

/// Values that differ from run to run, by JSON key, and what replaces them.
const _volatile = {
  'run_id': '<run-id>',
  'timestamp': '<timestamp>',
  'duration_ms': '<duration>',
  'latency_ms': '<duration>',
  'stack_trace': '<stack-trace>',
};

/// The JSON record of one run: what the model was sent, every event the run
/// emitted and its result.
///
/// Run ids, timestamps, durations and stack traces are replaced by
/// placeholders and `null` fields are left out, so two runs of the same
/// scenario give the same transcript.
Map<String, Object?> buildTranscript({
  required List<AgentEvent> events,
  required RunResult result,
  required List<ScriptedCall> modelCalls,
}) {
  expect(
    events.map((event) => event.runId).toSet(),
    {result.runId},
    reason: 'every event carries the run id of its run',
  );

  final transcript = {
    'model_calls': [
      for (final call in modelCalls)
        {
          'tools': [for (final tool in call.tools ?? const <ToolInfo>[]) tool.function.name],
          'messages': [for (final message in call.messages) message.toJson()],
        },
    ],
    'events': [for (final event in events) event.toJson()],
    'result': {
      'run_id': result.runId,
      'succeeded': result.succeeded,
      'cancelled': result.cancelled,
      'error': result.error,
      'usage': result.usage.toJson(),
      'final_message': result.finalMessage?.toJson(),
      'messages': [for (final message in result.messages) message.toJson()],
    },
  };

  // Encoding and decoding leaves plain JSON values, as a consumer that stores
  // events would see them.
  return _normalise(jsonDecode(jsonEncode(transcript)))! as Map<String, Object?>;
}

Object? _normalise(Object? json) => switch (json) {
      final Map<String, Object?> map => {
          for (final MapEntry(:key, :value) in map.entries)
            if (value != null) key: _volatile[key] ?? _normalise(value),
        },
      final List<Object?> list => [for (final item in list) _normalise(item)],
      _ => json,
    };

/// Compares [transcript] with `test/adk/golden/transcripts/<name>.json`, or
/// writes that file when [updateGoldensVariable] is set.
void expectGoldenTranscript(String name, Map<String, Object?> transcript) {
  final file = File('test/adk/golden/transcripts/$name.json');
  final encoded = '${const JsonEncoder.withIndent('  ').convert(transcript)}\n';

  if (Platform.environment[updateGoldensVariable] == '1') {
    file
      ..createSync(recursive: true)
      ..writeAsStringSync(encoded);
    return;
  }

  if (!file.existsSync()) {
    fail(
      'Missing golden file ${file.path}. '
      'Record it with $updateGoldensVariable=1.',
    );
  }

  expect(
    transcript,
    equals(jsonDecode(file.readAsStringSync())),
    reason: 'The run no longer matches ${file.path}. If the change is '
        'intended, record the file again with $updateGoldensVariable=1 and '
        'review the diff.',
  );
}
