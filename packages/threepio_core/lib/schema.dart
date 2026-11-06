/// The data types of threepio: messages, tool definitions and results,
/// documents, and what goes with them (templates, parsers, concatenation,
/// the type registry).
///
/// Port of the Eino package `schema`. Streams are in
/// `package:threepio_core/streaming.dart`.
///
/// The agentic messages (`AgenticMessage`, its `ContentBlock`s, the OpenAI,
/// Claude and Gemini extensions, `AgenticToolChoice`) are the beta agentic
/// path of Eino.
///
/// The run context (`RunContext`, `ContextKey`, `CancelToken`) is exported
/// from here as well, because templates and parsers take one.
library;

export 'src/components/model/cancel_token.dart';
export 'src/core/field_addressable.dart';
export 'src/core/run_context.dart';
export 'src/errors.dart';
export 'src/schema/agentic_message.dart';
export 'src/schema/agentic_message_concat.dart';
export 'src/schema/agentic_message_template.dart';
export 'src/schema/agentic_tool_choice.dart';
export 'src/schema/concat.dart' hide concatMaps;
export 'src/schema/document.dart';
export 'src/schema/extensions/claude.dart';
export 'src/schema/extensions/gemini.dart';
export 'src/schema/extensions/openai.dart';
export 'src/schema/message.dart';
export 'src/schema/message_concat.dart' hide concatMessagesLeniently;
export 'src/schema/message_parser.dart';
export 'src/schema/message_template.dart'
    hide formatMessage, formatTemplateText;
export 'src/schema/tool_info.dart';
export 'src/schema/tool_result.dart';
export 'src/schema/type_registry.dart';
