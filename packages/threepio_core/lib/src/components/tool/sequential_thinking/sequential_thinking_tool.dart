/// The `sequentialthinking` tool.
///
/// Port of eino-ext `components/tool/sequentialthinking`
/// (`sequentialthinking.go`, `util.go`).
library;

import 'dart:convert';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../schema/tool_info.dart';
import '../../component_type.dart';
import '../function_tool.dart';
import '../invokable_tool.dart';
import '../tool_options.dart';

/// One step of sequential thinking: what the model sends the tool.
///
/// Port of eino-ext `sequentialthinking.ThoughtRequest`.
@immutable
final class SequentialThoughtRequest {
  /// A thought; the fields Go marks `omitempty` default to their zero
  /// values.
  const SequentialThoughtRequest({
    this.thought = '',
    this.thoughtNumber = 0,
    this.totalThoughts = 0,
    this.isRevision = false,
    this.revisesThought = 0,
    this.branchFromThought = 0,
    this.branchId = '',
    this.needsMoreThoughts = false,
    this.nextThoughtNeeded = false,
  });

  /// Reads the tool's arguments the way Go decodes them (`sonic`, which
  /// `utils.InferTool` uses): a key names a field exactly or ignoring case
  /// (Go's `strings.ToLower` of the key), a later key overwrites an earlier
  /// one, a missing or `null` field keeps its zero value, other fields are
  /// ignored, and the first field of the wrong type (a number that is not an
  /// integer for the counts) is a [ThreepioFormatException].
  factory SequentialThoughtRequest.fromJson(Map<String, Object?> json) {
    var thought = '';
    var thoughtNumber = 0;
    var totalThoughts = 0;
    var isRevision = false;
    var revisesThought = 0;
    var branchFromThought = 0;
    var branchId = '';
    var needsMoreThoughts = false;
    var nextThoughtNeeded = false;
    for (final MapEntry(:key, :value) in json.entries) {
      // Go: `null` leaves the field as it is.
      if (value == null) continue;
      switch (_sonicFieldKey(key)) {
        case 'thought':
          thought = _string('thought', value);
        case 'thought_number':
          thoughtNumber = _int('thought_number', value);
        case 'total_thoughts':
          totalThoughts = _int('total_thoughts', value);
        case 'is_revision':
          isRevision = _bool('is_revision', value);
        case 'revises_thought':
          revisesThought = _int('revises_thought', value);
        case 'branch_from_thought':
          branchFromThought = _int('branch_from_thought', value);
        case 'branch_id':
          branchId = _string('branch_id', value);
        case 'needs_more_thoughts':
          needsMoreThoughts = _bool('needs_more_thoughts', value);
        case 'next_thought_needed':
          nextThoughtNeeded = _bool('next_thought_needed', value);
      }
    }
    return SequentialThoughtRequest(
      thought: thought,
      thoughtNumber: thoughtNumber,
      totalThoughts: totalThoughts,
      isRevision: isRevision,
      revisesThought: revisesThought,
      branchFromThought: branchFromThought,
      branchId: branchId,
      needsMoreThoughts: needsMoreThoughts,
      nextThoughtNeeded: nextThoughtNeeded,
    );
  }

  /// The current thinking step.
  final String thought;

  /// The number of this thought.
  final int thoughtNumber;

  /// The estimated number of thoughts needed.
  final int totalThoughts;

  /// Whether this thought revises an earlier one.
  final bool isRevision;

  /// The number of the thought being reconsidered.
  final int revisesThought;

  /// The number of the thought this one branches from.
  final int branchFromThought;

  /// The name of the branch; empty when the thought is on none.
  final String branchId;

  /// Whether more thoughts are needed than estimated.
  final bool needsMoreThoughts;

  /// Whether another thought step is needed.
  final bool nextThoughtNeeded;

  /// A copy with the given fields replaced.
  SequentialThoughtRequest copyWith({
    String? thought,
    int? thoughtNumber,
    int? totalThoughts,
    bool? isRevision,
    int? revisesThought,
    int? branchFromThought,
    String? branchId,
    bool? needsMoreThoughts,
    bool? nextThoughtNeeded,
  }) =>
      SequentialThoughtRequest(
        thought: thought ?? this.thought,
        thoughtNumber: thoughtNumber ?? this.thoughtNumber,
        totalThoughts: totalThoughts ?? this.totalThoughts,
        isRevision: isRevision ?? this.isRevision,
        revisesThought: revisesThought ?? this.revisesThought,
        branchFromThought: branchFromThought ?? this.branchFromThought,
        branchId: branchId ?? this.branchId,
        needsMoreThoughts: needsMoreThoughts ?? this.needsMoreThoughts,
        nextThoughtNeeded: nextThoughtNeeded ?? this.nextThoughtNeeded,
      );

  /// The JSON form, as Go writes it (its field names and order; the
  /// `omitempty` fields are left out when they are zero).
  Map<String, Object?> toJson() => {
        'thought': thought,
        'thought_number': thoughtNumber,
        'total_thoughts': totalThoughts,
        if (isRevision) 'is_revision': isRevision,
        if (revisesThought != 0) 'revises_thought': revisesThought,
        if (branchFromThought != 0) 'branch_from_thought': branchFromThought,
        if (branchId.isNotEmpty) 'branch_id': branchId,
        if (needsMoreThoughts) 'needs_more_thoughts': needsMoreThoughts,
        'next_thought_needed': nextThoughtNeeded,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SequentialThoughtRequest &&
          other.thought == thought &&
          other.thoughtNumber == thoughtNumber &&
          other.totalThoughts == totalThoughts &&
          other.isRevision == isRevision &&
          other.revisesThought == revisesThought &&
          other.branchFromThought == branchFromThought &&
          other.branchId == branchId &&
          other.needsMoreThoughts == needsMoreThoughts &&
          other.nextThoughtNeeded == nextThoughtNeeded;

  @override
  int get hashCode => Object.hash(
        thought,
        thoughtNumber,
        totalThoughts,
        isRevision,
        revisesThought,
        branchFromThought,
        branchId,
        needsMoreThoughts,
        nextThoughtNeeded,
      );

  @override
  String toString() => 'SequentialThoughtRequest(${toJson()})';
}

/// What the tool answers for a thought.
///
/// Port of eino-ext `sequentialthinking.ThoughtResult`.
@immutable
final class SequentialThoughtResult {
  /// A result.
  SequentialThoughtResult({
    required this.content,
    required this.thoughtNumber,
    required this.totalThoughts,
    required this.nextThoughtNeeded,
    required this.thoughtHistoryLength,
    List<String> branches = const [],
  }) : branches = List.unmodifiable(branches);

  /// Reads the map written by [toJson].
  factory SequentialThoughtResult.fromJson(Map<String, Object?> json) =>
      SequentialThoughtResult(
        content: _string('content', json['content']),
        thoughtNumber: _int('thought_number', json['thought_number']),
        totalThoughts: _int('total_thoughts', json['total_thoughts']),
        nextThoughtNeeded:
            _bool('next_thought_needed', json['next_thought_needed']),
        branches: _strings('branches', json['branches']),
        thoughtHistoryLength:
            _int('thought_history_length', json['thought_history_length']),
      );

  /// The thought, drawn in a box with a header that says what kind of
  /// thought it is.
  final String content;

  /// The number of the thought.
  final int thoughtNumber;

  /// The estimated number of thoughts, raised to [thoughtNumber] when that
  /// is higher.
  final int totalThoughts;

  /// Whether another thought step is needed.
  final bool nextThoughtNeeded;

  /// The names of the branches so far, in the order they were first seen.
  final List<String> branches;

  /// How many thoughts the tool has received so far.
  final int thoughtHistoryLength;

  /// The JSON form, as Go writes it (its field names and order).
  Map<String, Object?> toJson() => {
        'content': content,
        'thought_number': thoughtNumber,
        'total_thoughts': totalThoughts,
        'next_thought_needed': nextThoughtNeeded,
        'branches': branches,
        'thought_history_length': thoughtHistoryLength,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SequentialThoughtResult &&
          other.content == content &&
          other.thoughtNumber == thoughtNumber &&
          other.totalThoughts == totalThoughts &&
          other.nextThoughtNeeded == nextThoughtNeeded &&
          const ListEquality<String>().equals(other.branches, branches) &&
          other.thoughtHistoryLength == thoughtHistoryLength;

  @override
  int get hashCode => Object.hash(
        content,
        thoughtNumber,
        totalThoughts,
        nextThoughtNeeded,
        const ListEquality<String>().hash(branches),
        thoughtHistoryLength,
      );

  @override
  String toString() => 'SequentialThoughtResult(${toJson()})';
}

/// A tool that guides a model through a problem one thought at a time.
///
/// Port of eino-ext `sequentialthinking.NewTool`, inspired by
/// `@modelcontextprotocol/sequentialthinking`. The model sends each thought
/// as a [SequentialThoughtRequest]; the tool checks it, records it and
/// answers with a [SequentialThoughtResult] (as JSON) whose `content` draws
/// the thought in a box.
///
/// The tool keeps the thoughts it received, and the branches they named, in
/// the instance, as Go keeps them in its thinking server: one instance is
/// one conversation. Give each conversation a tool of its own.
///
/// A thought that breaks a rule is not refused: like Go, the tool replaces
/// its text with what is wrong (`Thought number must be greater than 0`,
/// `Total thoughts must be greater than 0`, `Thought number cannot exceed
/// total thoughts`, `The Parameter's thought should not empty`), marks it as
/// a revision of itself and records it all the same. A thought numbered
/// above the estimate also raises the estimate.
///
/// Arguments that do not decode make the call throw a
/// [ThreepioFormatException], as every `FunctionTool` does.
final class SequentialThinkingTool extends InvokableTool
    implements TypedComponent {
  /// A tool with no thoughts yet.
  ///
  /// Port of eino-ext `sequentialthinking.NewTool`, which cannot fail here.
  SequentialThinkingTool() {
    _tool =
        FunctionTool<SequentialThoughtRequest, SequentialThoughtResult>.fromInfo(
      _info,
      fromJson: SequentialThoughtRequest.fromJson,
      invoke: (ctx, request, _) => processThought(ctx, request),
      toJson: (result) => result.toJson(),
    );
  }

  /// The name of the tool.
  static const String toolName = 'sequentialthinking';

  /// The description of the tool, as the model sees it.
  static const String description = '''
A detailed tool for dynamic and reflective problem-solving through thoughts.
This tool helps analyze problems through a flexible thinking process that can adapt and evolve.
Each thought can build on, question, or revise previous insights as understanding deepens.

When to use this tool:
- Breaking down complex problems into steps
- Planning and design with room for revision
- Analysis that might need course correction
- Problems where the full scope might not be clear initially
- Problems that require a multi-step solution
- Tasks that need to maintain context over multiple steps
- Situations where irrelevant information needs to be filtered out

Key features:
- You can adjust total_thoughts up or down as you progress
- You can question or revise previous thoughts
- You can add more thoughts even after reaching what seemed like the end
- You can express uncertainty and explore alternative approaches
- Not every thought needs to build linearly - you can branch or backtrack
- Generates a solution hypothesis
- Verifies the hypothesis based on the Chain of Thought steps
- Repeats the process until satisfied
- Provides a correct answer

Parameters explained:
- thought: Your current thinking step, which can include:
* Regular analytical steps
* Revisions of previous thoughts
* Questions about previous decisions
* Realizations about needing more analysis
* Changes in approach
* Hypothesis generation
* Hypothesis verification
- next_thought_needed: True if you need more thinking, even if at what seemed like the end
- thought_number: Current number in sequence (can go beyond initial total if needed)
- total_thoughts: Current estimate of thoughts needed (can be adjusted up/down)
- is_revision: A boolean indicating if this thought revises previous thinking
- revises_thought: If is_revision is true, which thought number is being reconsidered
- branch_from_thought: If branching, which thought number is the branching point
- branch_id: Identifier for the current branch (if any)
- needs_more_thoughts: If reaching end but realizing more thoughts needed

You should:
1. Start with an initial estimate of needed thoughts, but be ready to adjust
2. Feel free to question or revise previous thoughts
3. Don't hesitate to add more thoughts if needed, even at the "end"
4. Express uncertainty when present
5. Mark thoughts that revise previous thinking or branch into new paths
6. Ignore information that is irrelevant to the current step
7. Generate a solution hypothesis when appropriate
8. Verify the hypothesis based on the Chain of Thought steps
9. Repeat the process until satisfied with the solution
10. Provide a single, ideally correct answer as the final output
11. Only set next_thought_needed to false when truly done and a satisfactory answer is reached
''';

  /// The tool info Go's `utils.InferTool` derives from `ThoughtRequest`
  /// (`jsonschema.Reflector` with `DoNotReference`): the fields in struct
  /// order, those without `omitempty` required, `additionalProperties:
  /// false`. Kept as a JSON Schema document, with the keys in the order Go's
  /// `jsonschema.Schema` writes them (`type` last), so that every provider
  /// sends the schema Go sends.
  static final ToolInfo _info = ToolInfo.fromJsonSchemaMap(
    name: toolName,
    desc: description,
    schema: const {
      'properties': {
        'thought': {
          'description': 'Your current thinking step',
          'type': 'string',
        },
        'thought_number': {
          'description': 'Current thought number',
          'type': 'integer',
        },
        'total_thoughts': {
          'description': 'Estimated total thoughts needed',
          'type': 'integer',
        },
        'is_revision': {
          'description': 'Whether this revises previous thinking',
          'type': 'boolean',
        },
        'revises_thought': {
          'description': 'Which thought is being reconsidered',
          'type': 'integer',
        },
        'branch_from_thought': {
          'description': 'Branching point thought number',
          'type': 'integer',
        },
        'branch_id': {
          'description': 'Branch identifier',
          'type': 'string',
        },
        'needs_more_thoughts': {
          'description': 'If more thoughts are needed',
          'type': 'boolean',
        },
        'next_thought_needed': {
          'description': 'Whether another thought step is needed',
          'type': 'boolean',
        },
      },
      'additionalProperties': false,
      'required': [
        'thought',
        'thought_number',
        'total_thoughts',
        'next_thought_needed',
      ],
      'type': 'object',
    },
  );

  late final FunctionTool<SequentialThoughtRequest, SequentialThoughtResult>
      _tool;

  final List<SequentialThoughtRequest> _thoughtHistory = [];

  final Map<String, List<SequentialThoughtRequest>> _branches = {};

  /// The thoughts received so far, as recorded (after the checks), oldest
  /// first.
  List<SequentialThoughtRequest> get thoughtHistory =>
      List.unmodifiable(_thoughtHistory);

  /// The thoughts of each branch, by branch name, in the order the branches
  /// were first seen.
  Map<String, List<SequentialThoughtRequest>> get branches => Map.unmodifiable({
        for (final MapEntry(:key, :value) in _branches.entries)
          key: List<SequentialThoughtRequest>.unmodifiable(value),
      });

  /// Go: `utils.InferTool` names the type after the tool.
  @override
  String get componentTypeName => 'Sequentialthinking';

  @override
  Future<ToolInfo> info() => _tool.info();

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) =>
      _tool.invokableRun(ctx, argumentsJson, options: options);

  /// The same as [invokableRun] with a context that is never cancelled, for
  /// code that still calls the tool the old way.
  @override
  Future<String> run(String argumentsJson) =>
      invokableRun(RunContext.background(), argumentsJson);

  /// Checks [request], records it and returns the answer for it.
  ///
  /// Port of the Go thinking server's `processThought`, the function the
  /// tool runs. Go map order is random; [SequentialThoughtResult.branches]
  /// lists the branches in the order they were first seen.
  SequentialThoughtResult processThought(
    RunContext ctx,
    SequentialThoughtRequest request,
  ) {
    var validated = validateThought(request);
    if (validated.thoughtNumber > validated.totalThoughts) {
      validated = validated.copyWith(totalThoughts: validated.thoughtNumber);
    }
    _thoughtHistory.add(validated);
    if (validated.branchId.isNotEmpty) {
      (_branches[validated.branchId] ??= []).add(validated);
    }
    return SequentialThoughtResult(
      content: formatThought(validated),
      thoughtNumber: validated.thoughtNumber,
      totalThoughts: validated.totalThoughts,
      nextThoughtNeeded: validated.nextThoughtNeeded,
      branches: [..._branches.keys],
      thoughtHistoryLength: _thoughtHistory.length,
    );
  }

  /// [request] with its text replaced by what is wrong with it, if anything,
  /// and then marked as a revision of itself. Of several problems the last
  /// one checked wins: thought number below 1, total below 1, thought number
  /// above the total, empty text.
  ///
  /// Port of the Go thinking server's `validate`.
  @visibleForTesting
  static SequentialThoughtRequest validateThought(
    SequentialThoughtRequest request,
  ) {
    String? problem;
    if (request.thoughtNumber < 1) {
      problem = 'Thought number must be greater than 0';
    }
    if (request.totalThoughts < 1) {
      problem = 'Total thoughts must be greater than 0';
    }
    if (request.thoughtNumber > request.totalThoughts) {
      problem = 'Thought number cannot exceed total thoughts';
    }
    if ((problem ?? request.thought).isEmpty) {
      problem = "The Parameter's thought should not empty";
    }
    if (problem == null) return request;
    return request.copyWith(
      thought: problem,
      isRevision: true,
      revisesThought: request.thoughtNumber,
    );
  }

  /// [thought] drawn in a box, under a header that says what kind of
  /// thought it is.
  ///
  /// Port of the Go thinking server's `formatThought`. Go measures the box
  /// in bytes of UTF-8 (`len`), so a line with an emoji or other non-ASCII
  /// text comes out narrower than the border; the port draws the same
  /// bytes.
  @visibleForTesting
  static String formatThought(SequentialThoughtRequest thought) {
    final String prefix;
    final String context;
    if (thought.isRevision) {
      prefix = '${_emoji(0x1F504)} Revision';
      context = ' (revising thought ${thought.revisesThought})';
    } else if (thought.branchFromThought > 0) {
      prefix = '${_emoji(0x1F33F)} Branch';
      context = ' (from thought ${thought.branchFromThought}, '
          'ID: ${thought.branchId})';
    } else {
      prefix = '${_emoji(0x1F4AD)} Thought';
      context = '';
    }

    final header =
        '$prefix ${thought.thoughtNumber}/${thought.totalThoughts}$context';
    final width = max(_byteLength(header), _byteLength(thought.thought)) + 4;
    final border = '-' * width;
    final v = String.fromCharCode(0x2502);
    return '\n'
        '${String.fromCharCode(0x250C)}$border${String.fromCharCode(0x2510)}\n'
        '$v ${padEnd(header, width - 2)} $v\n'
        '${String.fromCharCode(0x251C)}$border${String.fromCharCode(0x2524)}\n'
        '$v ${padEnd(thought.thought, width - 2)} $v\n'
        '${String.fromCharCode(0x2514)}$border${String.fromCharCode(0x2518)}';
  }

  /// [text] followed by spaces up to [length] bytes of UTF-8, or [text] when
  /// it is that long already.
  ///
  /// Port of Go's `padEnd`.
  @visibleForTesting
  static String padEnd(String text, int length) =>
      text + ' ' * max(0, length - _byteLength(text));
}

/// The length of [text] as Go's `len` measures it: bytes of UTF-8.
int _byteLength(String text) => utf8.encode(text).length;

String _emoji(int codePoint) => String.fromCharCode(codePoint);

/// [key] as Go's `sonic` decoder compares it with the JSON names of the
/// fields when no name matches exactly: `strings.ToLower(key)`. The names
/// here are lower-case ASCII, so only the runes whose lower case is ASCII
/// matter: `A`-`Z`, the Kelvin sign (`k`) and the capital I with dot above
/// (`i`).
String _sonicFieldKey(String key) {
  final buffer = StringBuffer();
  for (final rune in key.runes) {
    buffer.writeCharCode(switch (rune) {
      >= 0x41 && <= 0x5A => rune + 0x20,
      0x212A => 0x6B,
      0x0130 => 0x69,
      _ => rune,
    });
  }
  return buffer.toString();
}

String _string(String key, Object? value) {
  if (value == null) return '';
  if (value is String) return value;
  throw _mismatch(key, 'a string', value);
}

int _int(String key, Object? value) {
  if (value == null) return 0;
  if (value is int) return value;
  throw _mismatch(key, 'an integer', value);
}

List<String> _strings(String key, Object? value) {
  if (value == null) return const [];
  if (value is List<Object?> && value.every((element) => element is String)) {
    return value.cast<String>();
  }
  throw _mismatch(key, 'a list of strings', value);
}

bool _bool(String key, Object? value) {
  if (value == null) return false;
  if (value is bool) return value;
  throw _mismatch(key, 'a boolean', value);
}

ThreepioFormatException _mismatch(String key, String expected, Object value) =>
    ThreepioFormatException(
      'mismatched type with value: "$key" must be $expected, got '
      '${jsonEncode(value)}',
    );
