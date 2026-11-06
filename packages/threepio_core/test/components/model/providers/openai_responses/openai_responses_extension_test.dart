// Port of eino-ext components/model/agenticopenai/responses_extension_test.go:
// TestGetServerToolCallArguments, TestGetServerToolResult,
// TestConcatServerToolCallArguments, TestConcatServerToolResult (all
// subtests), plus JSON round trips of the payload types.
//
// Adapted: "nil input" passes a null block payload (a ServerToolCall /
// ServerToolResult is nullable here); the map-shaped tool search result
// uses threepio's ToolInfo JSON (Go marshals its own ToolInfo struct).
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/schema.dart';
import 'package:threepio_core/src/components/model/providers/openai_responses/openai_responses_consts.dart';
import 'package:threepio_core/src/components/model/providers/openai_responses/openai_responses_exception.dart';
import 'package:threepio_core/src/components/model/providers/openai_responses/openai_responses_extension.dart';
import 'package:threepio_core/src/components/model/providers/openai_responses/openai_responses_extension_ops.dart';

final _throws = throwsA(isA<OpenAIResponsesException>());

void main() {
  group('TestGetServerToolCallArguments', () {
    test('success', () {
      const args = OpenAIResponsesServerToolCallArguments();
      final res = serverToolCallArgumentsOf(const ServerToolCall(arguments: args));
      expect(identical(res, args), isTrue);
    });

    test('nil input', () {
      expect(() => serverToolCallArgumentsOf(null), _throws);
    });

    test('nil arguments', () {
      expect(() => serverToolCallArgumentsOf(const ServerToolCall()), _throws);
    });

    test('wrong type', () {
      expect(
        () => serverToolCallArgumentsOf(
          const ServerToolCall(arguments: 'wrong type'),
        ),
        _throws,
      );
    });

    test('map[string]any success', () {
      final res = serverToolCallArgumentsOf(
        const ServerToolCall(
          arguments: {
            'web_search': {
              'action_type': 'search',
              'search': {
                'queries': ['query1', 'query2'],
              },
            },
          },
        ),
      );
      expect(res.webSearch!.actionType, OpenAIResponsesWebSearchAction.search);
      expect(res.webSearch!.search!.queries, ['query1', 'query2']);
    });

    test('map[string]any with file_search', () {
      final res = serverToolCallArgumentsOf(
        const ServerToolCall(
          arguments: {
            'file_search': {
              'queries': ['file query'],
            },
          },
        ),
      );
      expect(res.fileSearch!.queries, ['file query']);
    });

    test('map[string]any with shell', () {
      final res = serverToolCallArgumentsOf(
        const ServerToolCall(
          arguments: {
            'shell': {
              'created_by': 'user1',
              'action': {
                'commands': ['ls', 'pwd'],
                'timeout_ms': 5000.0,
              },
            },
          },
        ),
      );
      expect(res.shell!.createdBy, 'user1');
      expect(res.shell!.action!.commands, ['ls', 'pwd']);
      expect(res.shell!.action!.timeoutMs, 5000);
    });

    test('map[string]any with tool_search', () {
      final res = serverToolCallArgumentsOf(
        const ServerToolCall(
          arguments: {
            'tool_search': {
              'arguments': {'query': 'find tools'},
            },
          },
        ),
      );
      expect(res.toolSearch!.arguments, isNotNull);
      expect(jsonEncode(res.toolSearch!.arguments), contains('find tools'));
    });
  });

  group('TestGetServerToolResult', () {
    test('success', () {
      const result = OpenAIResponsesServerToolResult();
      final res = serverToolResultOf(const ServerToolResult(content: result));
      expect(identical(res, result), isTrue);
    });

    test('nil input', () {
      expect(() => serverToolResultOf(null), _throws);
    });

    test('nil result', () {
      expect(() => serverToolResultOf(const ServerToolResult()), _throws);
    });

    test('wrong type', () {
      expect(
        () => serverToolResultOf(const ServerToolResult(content: 'wrong type')),
        _throws,
      );
    });

    test('map[string]any with web_search', () {
      final res = serverToolResultOf(
        const ServerToolResult(
          content: {
            'web_search': {
              'action_type': 'search',
              'search': {
                'sources': [
                  {'url': 'https://example.com'},
                ],
              },
            },
          },
        ),
      );
      expect(res.webSearch!.actionType, OpenAIResponsesWebSearchAction.search);
      expect(res.webSearch!.search!.sources, hasLength(1));
      expect(res.webSearch!.search!.sources.single.url, 'https://example.com');
    });

    test('map[string]any with code_interpreter', () {
      final res = serverToolResultOf(
        const ServerToolResult(
          content: {
            'code_interpreter': {
              'code': "print('hello')",
              'container_id': 'container123',
              'outputs': [
                {
                  'type': 'logs',
                  'logs': {'logs': 'hello'},
                },
              ],
            },
          },
        ),
      );
      expect(res.codeInterpreter!.code, "print('hello')");
      expect(res.codeInterpreter!.containerId, 'container123');
      expect(res.codeInterpreter!.outputs, hasLength(1));
      expect(
        res.codeInterpreter!.outputs.single.type,
        OpenAIResponsesCodeInterpreterOutputType.logs,
      );
    });

    test('map[string]any with image_generation', () {
      final res = serverToolResultOf(
        const ServerToolResult(
          content: {
            'image_generation': {'image_base64': 'base64data'},
          },
        ),
      );
      expect(res.imageGeneration!.imageBase64, 'base64data');
    });

    test('map[string]any with shell', () {
      final res = serverToolResultOf(
        const ServerToolResult(
          content: {
            'shell': {
              'max_output_length': 1000.0,
              'created_by': 'user1',
              'outputs': [
                {'stdout': 'output', 'stderr': ''},
              ],
            },
          },
        ),
      );
      expect(res.shell!.maxOutputLength, 1000);
      expect(res.shell!.createdBy, 'user1');
      expect(res.shell!.outputs.single.stdout, 'output');
    });

    test('map[string]any with tool_search', () {
      final expectedTool = ToolInfo.fromJsonSchemaMap(
        name: 'tool1',
        desc: 'description1',
        schema: const {
          'type': 'object',
          'required': ['query'],
        },
      );
      final toolAny = jsonDecode(jsonEncode(expectedTool.toJson()));
      final res = serverToolResultOf(
        ServerToolResult(
          content: {
            'tool_search': {
              'tools': [toolAny],
            },
          },
        ),
      );
      final tool = res.toolSearch!.tools.single;
      expect(tool.name, 'tool1');
      expect(tool.desc, 'description1');
      expect(tool.paramsOneOf, isNotNull);
      final schema = tool.paramsOneOf!.toJsonSchema();
      expect(schema.type, 'object');
      expect(schema.required, ['query']);
    });
  });

  group('TestConcatServerToolCallArguments', () {
    test('empty chunks', () {
      expect(concatServerToolCallArguments(const []), isNull);
    });

    test('one chunk', () {
      const args = OpenAIResponsesServerToolCallArguments();
      expect(identical(concatServerToolCallArguments(const [args]), args), isTrue);
    });

    test('multiple nil chunks', () {
      expect(
        () => concatServerToolCallArguments(const [null, null, null]),
        _throws,
      );
    });

    test('multiple web search chunks', () {
      expect(
        () => concatServerToolCallArguments(const [
          OpenAIResponsesServerToolCallArguments(
            webSearch: OpenAIResponsesWebSearchArguments(),
          ),
          OpenAIResponsesServerToolCallArguments(
            webSearch: OpenAIResponsesWebSearchArguments(),
          ),
        ]),
        _throws,
      );
    });

    test('multiple shell chunks', () {
      final res = concatServerToolCallArguments(const [
        OpenAIResponsesServerToolCallArguments(
          shell: OpenAIResponsesShellArguments(createdBy: 'user1'),
        ),
        OpenAIResponsesServerToolCallArguments(
          shell: OpenAIResponsesShellArguments(createdBy: 'user2'),
        ),
      ]);
      expect(res!.shell!.createdBy, 'user2');
    });

    test('mixed type chunks', () {
      expect(
        () => concatServerToolCallArguments(const [
          OpenAIResponsesServerToolCallArguments(
            webSearch: OpenAIResponsesWebSearchArguments(),
          ),
          OpenAIResponsesServerToolCallArguments(
            shell: OpenAIResponsesShellArguments(),
          ),
        ]),
        throwsA(
          isA<OpenAIResponsesException>()
              .having((e) => e.message, 'message', contains('type mismatch')),
        ),
      );
    });
  });

  group('TestConcatServerToolResult', () {
    test('empty chunks', () {
      expect(concatServerToolResult(const []), isNull);
    });

    test('one chunk', () {
      const result = OpenAIResponsesServerToolResult();
      expect(identical(concatServerToolResult(const [result]), result), isTrue);
    });

    test('multiple WebSearch chunks error', () {
      expect(
        () => concatServerToolResult(const [
          OpenAIResponsesServerToolResult(
            webSearch: OpenAIResponsesWebSearchResult(),
          ),
          OpenAIResponsesServerToolResult(
            webSearch: OpenAIResponsesWebSearchResult(),
          ),
        ]),
        _throws,
      );
    });

    test('multiple FileSearch chunks error', () {
      expect(
        () => concatServerToolResult([
          OpenAIResponsesServerToolResult(
            fileSearch: OpenAIResponsesFileSearchResult(),
          ),
          OpenAIResponsesServerToolResult(
            fileSearch: OpenAIResponsesFileSearchResult(),
          ),
        ]),
        _throws,
      );
    });

    test('concat CodeInterpreter code delta', () {
      final res = concatServerToolResult([
        OpenAIResponsesServerToolResult(
          codeInterpreter: OpenAIResponsesCodeInterpreterResult(
            code: "print('hello",
          ),
        ),
        OpenAIResponsesServerToolResult(
          codeInterpreter: OpenAIResponsesCodeInterpreterResult(
            code: " world')",
          ),
        ),
        OpenAIResponsesServerToolResult(
          codeInterpreter: OpenAIResponsesCodeInterpreterResult(
            containerId: 'container123',
            outputs: const [
              OpenAIResponsesCodeInterpreterOutput(
                logs: OpenAIResponsesCodeInterpreterOutputLogs(
                  logs: 'hello world',
                ),
              ),
            ],
          ),
        ),
        OpenAIResponsesServerToolResult(
          codeInterpreter: OpenAIResponsesCodeInterpreterResult(
            outputs: const [
              OpenAIResponsesCodeInterpreterOutput(
                image: OpenAIResponsesCodeInterpreterOutputImage(
                  url: 'https://example.com/img.png',
                ),
              ),
            ],
          ),
        ),
      ]);
      expect(res!.codeInterpreter!.code, "print('hello world')");
      expect(res.codeInterpreter!.containerId, 'container123');
      expect(res.codeInterpreter!.outputs, hasLength(2));
    });

    test('skip nil chunks', () {
      final res = concatServerToolResult([
        null,
        OpenAIResponsesServerToolResult(
          codeInterpreter: OpenAIResponsesCodeInterpreterResult(code: 'x = 1'),
        ),
        null,
      ]);
      expect(res!.codeInterpreter!.code, 'x = 1');
    });

    test('concat ImageGeneration partial images', () {
      final res = concatServerToolResult(const [
        OpenAIResponsesServerToolResult(
          imageGeneration:
              OpenAIResponsesImageGenerationResult(imageBase64: 'partial1'),
        ),
        OpenAIResponsesServerToolResult(
          imageGeneration:
              OpenAIResponsesImageGenerationResult(imageBase64: 'partial2'),
        ),
      ]);
      expect(res!.imageGeneration!.imageBase64, 'partial1partial2');
    });

    test('cannot mix CodeInterpreter and ImageGeneration', () {
      expect(
        () => concatServerToolResult([
          OpenAIResponsesServerToolResult(
            codeInterpreter: OpenAIResponsesCodeInterpreterResult(code: 'x = 1'),
          ),
          const OpenAIResponsesServerToolResult(
            imageGeneration:
                OpenAIResponsesImageGenerationResult(imageBase64: 'img'),
          ),
        ]),
        throwsA(
          isA<OpenAIResponsesException>()
              .having((e) => e.message, 'message', contains('type mismatch')),
        ),
      );
    });

    test('shell results append their outputs', () {
      final res = concatServerToolResult([
        OpenAIResponsesServerToolResult(
          shell: OpenAIResponsesShellResult(
            maxOutputLength: 10,
            outputs: const [OpenAIResponsesShellOutputItem(stdout: 'a')],
          ),
        ),
        OpenAIResponsesServerToolResult(
          shell: OpenAIResponsesShellResult(
            createdBy: 'u',
            outputs: const [OpenAIResponsesShellOutputItem(stdout: 'b')],
          ),
        ),
      ]);
      expect(res!.shell!.maxOutputLength, 10);
      expect(res.shell!.createdBy, 'u');
      expect(res.shell!.outputs.map((o) => o.stdout), ['a', 'b']);
    });
  });

  group('JSON round trips', () {
    test('arguments of every tool', () {
      final all = [
        OpenAIResponsesServerToolCallArguments(
          webSearch: OpenAIResponsesWebSearchArguments(
            actionType: OpenAIResponsesWebSearchAction.search,
            search: OpenAIResponsesWebSearchQuery(queries: const ['q']),
          ),
        ),
        const OpenAIResponsesServerToolCallArguments(
          webSearch: OpenAIResponsesWebSearchArguments(
            actionType: OpenAIResponsesWebSearchAction.find,
            find: OpenAIResponsesWebSearchFind(url: 'u', pattern: 'p'),
          ),
        ),
        OpenAIResponsesServerToolCallArguments(
          fileSearch: OpenAIResponsesFileSearchArguments(queries: const ['f']),
        ),
        const OpenAIResponsesServerToolCallArguments(
          codeInterpreter: OpenAIResponsesCodeInterpreterArguments(),
        ),
        const OpenAIResponsesServerToolCallArguments(
          imageGeneration: OpenAIResponsesImageGenerationArguments(),
        ),
        OpenAIResponsesServerToolCallArguments(
          shell: OpenAIResponsesShellArguments(
            action: OpenAIResponsesShellAction(
              commands: const ['ls'],
              timeoutMs: 5,
              maxOutputLength: 6,
            ),
            environment: OpenAIResponsesShellEnvironment(
              type: OpenAIResponsesShellEnvironmentType.local,
              local: OpenAIResponsesShellEnvironmentLocal(
                skills: const [
                  OpenAIResponsesShellEnvironmentLocalSkill(
                    name: 'n',
                    description: 'd',
                    path: '/p',
                  ),
                ],
              ),
            ),
            createdBy: 'me',
          ),
        ),
        const OpenAIResponsesServerToolCallArguments(
          toolSearch: OpenAIResponsesToolSearchArguments(
            arguments: {'query': 'x'},
          ),
        ),
      ];
      for (final args in all) {
        final json = jsonDecode(jsonEncode(args.toJson())) as Map<String, Object?>;
        expect(OpenAIResponsesServerToolCallArguments.fromJson(json), args);
      }
      expect(
        const OpenAIResponsesServerToolCallArguments(
          codeInterpreter: OpenAIResponsesCodeInterpreterArguments(),
        ).toJson(),
        {'code_interpreter': <String, Object?>{}},
      );
    });

    test('results of every tool', () {
      final all = [
        OpenAIResponsesServerToolResult(
          webSearch: OpenAIResponsesWebSearchResult(
            actionType: OpenAIResponsesWebSearchAction.search,
            search: OpenAIResponsesWebSearchQueryResult(
              sources: const [OpenAIResponsesWebSearchQuerySource(url: 'u')],
            ),
          ),
        ),
        OpenAIResponsesServerToolResult(
          fileSearch: OpenAIResponsesFileSearchResult(
            results: [
              OpenAIResponsesFileSearchResultItem(
                fileId: 'f',
                fileName: 'n',
                score: 0.5,
                text: 't',
                attributes: const {
                  's': OpenAIResponsesFileSearchAttribute(ofString: 'v'),
                  'n': OpenAIResponsesFileSearchAttribute(ofFloat: 1.5),
                  'b': OpenAIResponsesFileSearchAttribute(ofBool: true),
                },
              ),
            ],
          ),
        ),
        OpenAIResponsesServerToolResult(
          codeInterpreter: OpenAIResponsesCodeInterpreterResult(
            code: 'c',
            containerId: 'ctr',
            outputs: const [
              OpenAIResponsesCodeInterpreterOutput(
                type: OpenAIResponsesCodeInterpreterOutputType.image,
                image: OpenAIResponsesCodeInterpreterOutputImage(url: 'u'),
              ),
            ],
          ),
        ),
        const OpenAIResponsesServerToolResult(
          imageGeneration: OpenAIResponsesImageGenerationResult(
            imageBase64: 'b64',
          ),
        ),
        OpenAIResponsesServerToolResult(
          shell: OpenAIResponsesShellResult(
            maxOutputLength: 9,
            createdBy: 'me',
            outputs: const [
              OpenAIResponsesShellOutputItem(
                stdout: 'o',
                stderr: 'e',
                outcome: OpenAIResponsesShellOutputOutcome(
                  type: OpenAIResponsesShellOutputOutcomeType.exit,
                  exit: OpenAIResponsesShellOutputOutcomeExit(exitCode: 2),
                ),
              ),
            ],
          ),
        ),
        OpenAIResponsesServerToolResult(
          toolSearch: OpenAIResponsesToolSearchResult(
            tools: [
              ToolInfo.fromJsonSchemaMap(
                name: 't',
                desc: 'd',
                schema: const {'type': 'object'},
              ),
            ],
          ),
        ),
      ];
      for (final result in all) {
        final json =
            jsonDecode(jsonEncode(result.toJson())) as Map<String, Object?>;
        expect(OpenAIResponsesServerToolResult.fromJson(json), result);
      }
    });
  });
}
