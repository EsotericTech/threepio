// The fields and factories P1 added to the schema types for Eino v0.9.22.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/threepio_core.dart';

Map<String, dynamic> wire(Map<String, dynamic> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, dynamic>;

void main() {
  group('MessagePartCommon', () {
    test('has a file id that survives JSON', () {
      const common = MessagePartCommon(
        fileId: 'file-123',
        mimeType: 'application/pdf',
      );

      final restored = MessagePartCommon.fromJson(wire(common.toJson()));

      expect(restored, common);
      expect(restored.fileId, 'file-123');
      expect(restored.url, isNull);
    });

    test('still reads and writes the deprecated extra', () {
      const common = MessagePartCommon(
        url: 'u',
        // ignore: deprecated_member_use
        extra: {'filename': 'a.pdf'},
      );

      final restored = MessagePartCommon.fromJson(wire(common.toJson()));

      expect(restored, common);
      // ignore: deprecated_member_use
      expect(restored.extra, {'filename': 'a.pdf'});
    });

    test('reads JSON written before the file id existed', () {
      final restored = MessagePartCommon.fromJson(const {
        'url': 'https://example.com/a.png',
        'mimeType': 'image/png',
      });

      expect(restored.url, 'https://example.com/a.png');
      expect(restored.fileId, isNull);
    });
  });

  group('MessageInputPart', () {
    test('audio, video and file factories', () {
      final audio = MessageInputPart.audio(
        base64Data: 'QUJD',
        mimeType: 'audio/wav',
      );
      final video = MessageInputPart.video(url: 'https://example.com/v.mp4');
      final file = MessageInputPart.file(fileId: 'file-1', name: 'report.pdf');

      expect(audio.type, ChatMessagePartType.audioUrl);
      expect(audio.audio!.common.base64Data, 'QUJD');
      expect(audio.audio!.common.mimeType, 'audio/wav');
      expect(video.type, ChatMessagePartType.videoUrl);
      expect(video.video!.common.url, 'https://example.com/v.mp4');
      expect(file.type, ChatMessagePartType.fileUrl);
      expect(file.file!.common.fileId, 'file-1');
      expect(file.file!.name, 'report.pdf');
    });

    test('extra, file name and tool search result survive JSON', () {
      final parts = [
        const MessageInputPart(
          type: ChatMessagePartType.text,
          text: 'hi',
          extra: {'cache_control': 'ephemeral'},
        ),
        MessageInputPart.file(url: 'https://example.com/a.pdf', name: 'a.pdf'),
        MessageInputPart(
          type: ChatMessagePartType.toolSearchResult,
          toolSearchResult: ToolSearchResult(
            tools: [ToolInfo.function(name: 'found', description: 'a tool')],
          ),
        ),
      ];

      for (final part in parts) {
        expect(MessageInputPart.fromJson(wire(part.toJson())), part);
      }
    });

    test('the new part types have the names Eino gives them', () {
      expect(
        const MessageOutputPart(type: ChatMessagePartType.reasoning)
            .toJson()['type'],
        'reasoning',
      );
      expect(
        const MessageInputPart(type: ChatMessagePartType.toolSearchResult)
            .toJson()['type'],
        'tool_search_result',
      );
    });

    test('reads JSON written before the new fields existed', () {
      final restored = MessageInputPart.fromJson(const {
        'type': 'file_url',
        'file': {
          'common': {'url': 'u'},
        },
      });

      expect(restored.file!.common.url, 'u');
      expect(restored.file!.name, isNull);
      expect(restored.extra, isNull);
      expect(restored.toolSearchResult, isNull);
    });
  });

  group('MessageOutputPart', () {
    test('reasoning and extra survive JSON', () {
      const part = MessageOutputPart(
        type: ChatMessagePartType.reasoning,
        reasoning: MessageOutputReasoning(text: 'thinking', signature: 'sig'),
        extra: {'provider': 'x'},
      );

      expect(MessageOutputPart.fromJson(wire(part.toJson())), part);
      expect(const MessageOutputReasoning().text, isEmpty);
      expect(const MessageOutputReasoning().signature, isEmpty);
    });

    test('the streaming position is not written to JSON', () {
      const part = MessageOutputPart(
        type: ChatMessagePartType.text,
        text: 'a',
        streamingMeta: MessageStreamingMeta(index: 2),
      );

      final json = wire(part.toJson());
      final restored = MessageOutputPart.fromJson(json);

      expect(json, isNot(contains('streamingMeta')));
      expect(restored.streamingMeta, isNull);
      expect(restored, part.copyWith(streamingMeta: null));
      expect(const MessageStreamingMeta().index, 0);
    });
  });

  group('TokenUsage', () {
    test('cache write tokens survive JSON and are summed', () {
      const usage = TokenUsage(
        promptTokens: 10,
        completionTokens: 5,
        totalTokens: 15,
        promptTokenDetails:
            PromptTokenDetails(cachedTokens: 4, cacheWriteTokens: 6),
      );

      final restored = TokenUsage.fromJson(wire(usage.toJson()));
      final sum = usage + usage;

      expect(restored, usage);
      expect(sum.promptTokenDetails!.cachedTokens, 8);
      expect(sum.promptTokenDetails!.cacheWriteTokens, 12);
      expect(const PromptTokenDetails().cacheWriteTokens, 0);
    });

    test('reads prompt token details written before cache writes existed',
        () {
      final details = PromptTokenDetails.fromJson(const {'cachedTokens': 3});

      expect(details.cachedTokens, 3);
      expect(details.cacheWriteTokens, 0);
    });

    test('the run-end event carries the schema usage', () {
      final event = AgentRunEndEvent(
        agentName: 'assistant',
        outputMessage: Message.assistant('Done'),
        durationMs: 1,
        runId: 'run-1',
        tokenUsage: const TokenUsage(
          promptTokens: 100,
          completionTokens: 50,
          totalTokens: 150,
          cost: 0.25,
        ),
      );

      final restored =
          AgentEvent.fromJson(wire(event.toJson())) as AgentRunEndEvent;

      expect(restored.tokenUsage, event.tokenUsage);
    });

    test('a run-end event stored with the old usage shape is still read', () {
      final restored = AgentEvent.fromJson({
        'event_type': 'run_end',
        'run_id': 'run-1',
        'timestamp': DateTime.utc(2026).toIso8601String(),
        'agent_name': 'assistant',
        'output_message': Message.assistant('Done').toJson(),
        'duration_ms': 1,
        'token_usage': {
          'prompt_tokens': 100,
          'completion_tokens': 50,
          'total_tokens': 150,
        },
      }) as AgentRunEndEvent;

      expect(
        restored.tokenUsage,
        const TokenUsage(
          promptTokens: 100,
          completionTokens: 50,
          totalTokens: 150,
        ),
      );
    });
  });

  group('the umbrella library', () {
    test('exports the core RunContext, not the runtime scope under that name',
        () {
      final ctx = RunContext.background();
      final scope = AgentRunScope(sessionId: 's1');

      expect(ctx.cancelToken.isCancelled, isFalse);
      expect(scope.sessionId, 's1');
      expect(scope.cancelToken.isCancelled, isFalse);
    });

    test('exports the Eino-shaped schema and stream additions', () {
      // Every name here has to resolve through package:threepio_core alone.
      expect(FormatType.values, hasLength(3));
      expect(const MessagesPlaceholder('k'), isA<MessagesTemplate>());
      expect(const ParamsOneOf.params({}).toJsonSchema().properties, isEmpty);
      expect(const ToolArgument('{}').text, '{}');
      expect(ToolResult.text('a').parts.single.type, ToolPartType.text);
      expect(StreamConcat.concatItems(['a', 'b']), 'ab');
      expect(TypeRegistry.isRegistered<Message>(), isTrue);
      expect(concatMessages([Message.user('a')]), Message.user('a'));
      expect(
        MessageJsonParser<int>(fromJson: (json) => json! as int),
        isA<MessageParser<int>>(),
      );
      expect(Document.simple('d').withExtraInfo('i').extraInfo, 'i');
      final (reader, writer) = pipe<int>(capacity: 1);
      expect(writer.sendAsync(1), completion(isFalse));
      expect(reader.nextOrNull(), completion(1));
    });
  });
}
