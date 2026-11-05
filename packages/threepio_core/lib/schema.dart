/// The data types of threepio: messages, tool definitions and results,
/// documents, and what goes with them (templates, parsers, concatenation,
/// the type registry).
///
/// Port of the Eino package `schema`. Streams are in
/// `package:threepio_core/streaming.dart`.
///
/// The run context (`RunContext`, `ContextKey`, `CancelToken`) is exported
/// from here as well, because templates and parsers take one.
library;

export 'src/components/model/cancel_token.dart';
export 'src/core/run_context.dart';
export 'src/schema/concat.dart' hide concatMaps;
export 'src/schema/document.dart';
export 'src/schema/message.dart';
export 'src/schema/message_concat.dart';
export 'src/schema/message_parser.dart';
export 'src/schema/message_template.dart' hide formatMessage;
export 'src/schema/tool_info.dart';
export 'src/schema/tool_result.dart';
export 'src/schema/type_registry.dart';
