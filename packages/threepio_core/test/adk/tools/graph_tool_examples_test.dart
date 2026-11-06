// Port of the eino-examples graph tool, `adk/common/tool/graphtool`:
// the library `graph_tool.go` (README.md) and its four example programs
// `examples/1_chain_summarize/main.go`, `examples/2_graph_research/main.go`,
// `examples/3_workflow_order/main.go` and `examples/4_nested_interrupt/main.go`.
//
// eino-examples has no Go tests for the graph tool; each example program is a
// group here. The real chat models become ScriptedChatModels (the agent's
// model calls the graph tool, then answers; the model inside the graph answers
// what the example's prompts ask for), the answers the examples read from
// stdin become fixed resume data (approve and reject wherever the example
// branches), and the printed events become assertions on the tool's output,
// the interrupt contexts and the resumed outcome.
//
// Not ported: the printing (`prints.Event`) and the `time.Sleep` of the mock
// services (no real timers; example 2's three searches still finish in the
// order their sleeps imply, through zero-delay hops).
//
// The group `GraphTool API` adds unit tests of the Dart port's API
// (`GraphTool.invokable` / `GraphTool.streamable`, `GraphToolOptions`): info,
// type checks, argument decoding, options, failures, streamed chunks and
// interrupts of both variants, checked against `graph_tool.go`.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/compose/interrupt.dart'
    show AddressedInterruptSignal;

import '../../support/scripted_chat_model.dart';

// ---------------------------------------------------------------------------
// Shared helpers.
// ---------------------------------------------------------------------------

/// The events of a run, checked to carry no error.
Future<List<AgentEvent>> _collectOk(StreamReader<AgentEvent> events) async {
  final all = await events.collectAll();
  expect(all.map((e) => e.error), everyElement(isNull), reason: '$all');
  return all;
}

/// The events of a run up to its interrupt (the last event, as the examples
/// expect it), checked to carry no error, and the interrupt.
Future<(List<AgentEvent>, AgentInterruptInfo)> _runUntilInterrupt(
  StreamReader<AgentEvent> events,
) async {
  final all = await _collectOk(events);
  expect(all, isNotEmpty, reason: 'no events received');
  final interrupted = all.last.action?.interrupted;
  expect(interrupted, isNotNull,
      reason: 'last event is not an interrupt: $all');
  return (all.sublist(0, all.length - 1), interrupted!);
}

/// Resumes the run saved as [checkpointId] at [interruptId] with [data]
/// (Go: `runner.ResumeWithParams(ctx, checkpointID, &adk.ResumeParams{...})`
/// with the targets `{interruptID: data}`).
Future<StreamReader<AgentEvent>> _resume(
  Runner runner,
  String checkpointId,
  String interruptId,
  Object? data,
) =>
    runner.resumeWithParams(
      RunContext.background(),
      checkpointId,
      ResumeParams(targets: {interruptId: data}),
    );

/// The messages of [events] (joined when streamed).
Future<List<Message?>> _messagesOf(List<AgentEvent> events) async =>
    [for (final event in events) await getMessageFromEvent(event)];

/// Checks that [call] continues the conversation with the result of the tool
/// call [callId], and returns that result.
String _toolResultOf(ScriptedCall call, String callId) {
  final last = call.messages.last;
  expect(last.role, RoleType.tool);
  expect(last.toolCallId, callId);
  return last.content;
}

/// A model that calls [tool] once with [args], then answers [answer].
ScriptedChatModel _callingModel(String tool, String args, String answer) =>
    ScriptedChatModel([
      [
        toolCallDelta(0, id: 'call_1', name: tool, args: args),
        finish('tool_calls'),
      ],
      [text(answer), finish('stop')],
    ]);

const _prefix = 'graph_tool_examples_test';

// ---------------------------------------------------------------------------
// Example 1: 1_chain_summarize (compose.Chain + InvokableGraphTool).
// ---------------------------------------------------------------------------

/// Go: `SummarizeInput`.
final class _SummarizeInput {
  const _SummarizeInput({this.document = '', this.maxWords = 0});

  factory _SummarizeInput.fromJson(Map<String, Object?> json) =>
      _SummarizeInput(
        document: json['document'] as String? ?? '',
        maxWords: (json['max_words'] as num?)?.toInt() ?? 0,
      );

  final String document;
  final int maxWords;
}

/// Go: `SummarizeOutput`.
final class _SummarizeOutput {
  const _SummarizeOutput({
    required this.summary,
    required this.keyPoints,
    required this.wordCount,
  });

  final String summary;
  final List<String> keyPoints;
  final int wordCount;

  Map<String, Object?> toJson() => {
        'summary': summary,
        'key_points': keyPoints,
        'word_count': wordCount,
      };
}

const _summarizeParams = ParamsOneOf.params({
  'document': ParameterInfo(
    type: DataType.string,
    desc: 'The document text to summarize',
    required: true,
  ),
  'max_words': ParameterInfo(
    type: DataType.integer,
    desc: 'Maximum number of words in the summary (default: 100)',
    required: true,
  ),
});

const _extractSystem =
    '''You are an expert at extracting key points from documents.
Extract the main key points from the following document. Return them as a numbered list.
Be concise and focus on the most important information.''';

const _condenseSystem = '''You are an expert summarizer.
Given the key points below, create a coherent summary in approximately {max_words} words.
The summary should flow naturally and capture the essence of the original content.''';

/// Go: `countWords`.
int _countWords(String s) {
  var words = 0;
  var inWord = false;
  for (final r in s.runes) {
    if (r == 0x20 || r == 0x0A || r == 0x09) {
      inWord = false;
    } else if (!inWord) {
      inWord = true;
      words++;
    }
  }
  return words;
}

/// Go: `NewSummarizeTool` (the chain, wrapped as `summarize_document`).
InvokableTool _newSummarizeTool(BaseChatModel cm) {
  final extractKeyPointsPrompt = ChatTemplate.fromMessages(FormatType.fString, [
    Message.system(_extractSystem),
    Message.user('''Document:
{document}

Extract the key points:'''),
  ]);
  final condenseSummaryPrompt = ChatTemplate.fromMessages(FormatType.fString, [
    Message.system(_condenseSystem),
    Message.user('''Key Points:
{key_points}

Create a summary in approximately {max_words} words:'''),
  ]);

  final fullChain = Chain<_SummarizeInput, _SummarizeOutput>()
    ..appendLambda(Lambda.invokable((ctx, _SummarizeInput input) {
      var maxWords = input.maxWords;
      if (maxWords <= 0) maxWords = 100;
      return <String, dynamic>{
        'document': input.document,
        'max_words': maxWords,
      };
    }))
    ..appendChatTemplate(extractKeyPointsPrompt)
    ..appendChatModel(cm)
    ..appendLambda(Lambda.invokable((ctx, Message msg) {
      final keyPointsContent = msg.content;
      return <String, dynamic>{
        'key_points': keyPointsContent,
        'max_words': 100,
      };
    }))
    ..appendChatTemplate(condenseSummaryPrompt)
    ..appendChatModel(cm)
    ..appendLambda(Lambda.invokable((ctx, Message msg) => _SummarizeOutput(
          summary: msg.content,
          keyPoints: const [],
          wordCount: _countWords(msg.content),
        )));

  return GraphTool.invokable<_SummarizeInput, _SummarizeOutput>(
    name: 'summarize_document',
    description:
        'Summarize a document by extracting key points and creating a coherent '
        'summary. Returns the summary, key points, and word count.',
    params: _summarizeParams,
    fromJson: _SummarizeInput.fromJson,
    graph: fullChain,
    toJson: (output) => output.toJson(),
  );
}

ChatModelAgent _documentAssistant(BaseChatModel model, BaseTool tool) =>
    ChatModelAgent(ChatModelAgentConfig(
      name: 'DocumentAssistant',
      description: 'An assistant that can summarize documents',
      instruction: '''You are a helpful document assistant.
When the user provides a document or asks you to summarize something, use the summarize_document tool.
Always provide the full document text to the tool.''',
      model: model,
      toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [tool])),
    ));

const _sampleDocument =
    '''Artificial Intelligence (AI) has transformed numerous industries over the past decade.
In healthcare, AI systems now assist doctors in diagnosing diseases by analyzing medical images with remarkable accuracy.
Machine learning algorithms can detect patterns in X-rays and MRIs that might escape human observation.

In finance, AI-powered trading systems execute millions of transactions daily, analyzing market trends and making
split-second decisions. Banks use AI for fraud detection, identifying suspicious patterns in transaction data.

The transportation sector has seen revolutionary changes with autonomous vehicles. Self-driving cars use
computer vision and deep learning to navigate roads safely. Companies like Tesla, Waymo, and others are
racing to perfect this technology.

However, AI also raises important ethical concerns. Issues of bias in AI systems, job displacement,
and privacy concerns require careful consideration. As AI becomes more powerful, society must develop
frameworks to ensure its responsible use.''';

const _keyPoints = '1. AI aids diagnosis in healthcare.\n'
    '2. AI trades and detects fraud in finance.\n'
    '3. Self-driving cars transform transportation.\n'
    '4. Bias, jobs and privacy raise ethical concerns.';

const _summary = 'AI has reshaped healthcare, finance and transportation, '
    'from diagnosis and fraud detection to self-driving cars,\nwhile bias, '
    'job loss and privacy demand\tresponsible frameworks.';

/// Records the variables every chat template of a run is filled with.
final class _TemplateRecorder extends ComponentCallbackHandler {
  final List<Map<String, Object?>> variables = [];

  @override
  RunContext onStart(RunContext ctx, RunInfo info, Object? input) {
    if (info.componentType == ComponentType.promptTemplate) {
      final prompt = PromptCallbackInput.from(input);
      if (prompt != null) variables.add(Map.of(prompt.variables));
    }
    return ctx;
  }
}

// ---------------------------------------------------------------------------
// Example 2: 2_graph_research (compose.Graph + StreamableGraphTool).
// ---------------------------------------------------------------------------

/// Go: `ResearchInput`.
final class _ResearchInput {
  const _ResearchInput({this.query = ''});

  factory _ResearchInput.fromJson(Map<String, Object?> json) =>
      _ResearchInput(query: json['query'] as String? ?? '');

  final String query;
}

/// Go: `searchResults`.
final class _SearchResults {
  _SearchResults({required this.query});

  final String query;
  String webResults = '';
  String kbResults = '';
  String localResults = '';
}

/// Waits [hops] zero-delay timers: the stand-in for the mock services'
/// `time.Sleep`, keeping the order in which they finish.
Future<void> _hops(int hops) async {
  for (var i = 0; i < hops; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Go: `mockWebSearch` (sleeps 100 ms).
Future<String> _mockWebSearch(String query) async {
  await _hops(3);
  return '''Web Search Results for "$query":
1. Wikipedia: $query is a widely discussed topic with multiple perspectives...
2. News Article: Recent developments in $query show promising trends...
3. Research Paper: A comprehensive study on $query reveals key insights...''';
}

/// Go: `mockKnowledgeBaseSearch` (sleeps 80 ms).
Future<String> _mockKnowledgeBaseSearch(String query) async {
  await _hops(2);
  return '''Knowledge Base Results for "$query":
- Internal Doc #1: Company guidelines related to $query...
- Internal Doc #2: Best practices for handling $query...
- FAQ Entry: Common questions about $query answered...''';
}

/// Go: `mockLocalFileSearch` (sleeps 50 ms).
Future<String> _mockLocalFileSearch(String query) async {
  await _hops(1);
  final file = query.replaceAll(' ', '_');
  return '''Local File Results for "$query":
- notes/research_$file.md: Personal notes on $query...
- docs/guide_$file.txt: Step-by-step guide for $query...''';
}

const _synthesizeSystem =
    '''You are a research analyst. Synthesize the following search results from multiple sources into a coherent summary.
Focus on the most relevant and reliable information. Identify any conflicting information across sources.
Be concise but comprehensive. Output the summary directly without any JSON formatting.''';

/// Go: `NewResearchTool`; [log] gets the lines the Go graph prints.
StreamableTool _newResearchTool(BaseChatModel cm, List<String> log) {
  final synthesizePrompt = ChatTemplate.fromMessages(FormatType.fString, [
    Message.system(_synthesizeSystem),
    Message.user('''Research Query: {query}

Web Search Results:
{web_results}

Knowledge Base Results:
{kb_results}

Local File Results:
{local_results}

Please synthesize these results into a comprehensive summary:'''),
  ]);

  final graph = Graph<_ResearchInput, Message>()
    ..addLambdaNode(
      'parallel_search',
      Lambda.invokable((ctx, _ResearchInput input) async {
        log.add('[Graph] Starting parallel searches...');
        final results = _SearchResults(query: input.query);
        Future<void> search(String source, Future<String> running) async {
          final data = await running;
          switch (source) {
            case 'web':
              results.webResults = data;
              log.add('[Graph] Web search completed');
            case 'kb':
              results.kbResults = data;
              log.add('[Graph] Knowledge base search completed');
            case 'local':
              results.localResults = data;
              log.add('[Graph] Local file search completed');
          }
        }

        await Future.wait([
          search('web', _mockWebSearch(input.query)),
          search('kb', _mockKnowledgeBaseSearch(input.query)),
          search('local', _mockLocalFileSearch(input.query)),
        ]);
        log.add('[Graph] All searches completed, preparing synthesis...');
        return results;
      }),
    )
    ..addLambdaNode(
      'prepare_prompt_input',
      Lambda.invokable((ctx, _SearchResults results) => <String, dynamic>{
            'query': results.query,
            'web_results': results.webResults,
            'kb_results': results.kbResults,
            'local_results': results.localResults,
          }),
    )
    ..addChatTemplateNode('prepare_prompt', synthesizePrompt)
    ..addChatModelNode('synthesize', cm)
    ..addEdge(Graph.start, 'parallel_search')
    ..addEdge('parallel_search', 'prepare_prompt_input')
    ..addEdge('prepare_prompt_input', 'prepare_prompt')
    ..addEdge('prepare_prompt', 'synthesize')
    ..addEdge('synthesize', Graph.end);

  // Go: NewStreamableGraphTool[*ResearchInput, *schema.Message]; each chunk
  // is the message chunk marshalled as it is (no toJson: Message's own).
  return GraphTool.streamable<_ResearchInput, Message>(
    name: 'research_topic',
    description:
        'Research a topic by querying multiple sources (web, knowledge base, '
        'local files) in parallel and synthesizing the results. Returns a '
        'streaming summary directly.',
    params: const ParamsOneOf.params({
      'query': ParameterInfo(
        type: DataType.string,
        desc: 'The research topic or question to investigate',
        required: true,
      ),
    }),
    fromJson: _ResearchInput.fromJson,
    graph: graph,
  );
}

// ---------------------------------------------------------------------------
// Example 3: 3_workflow_order (compose.Workflow + InvokableApprovableTool).
// ---------------------------------------------------------------------------

/// Go: `OrderInput`.
final class _OrderInput {
  const _OrderInput({
    this.customerId = '',
    this.productId = '',
    this.quantity = 0,
  });

  factory _OrderInput.fromJson(Map<String, Object?> json) => _OrderInput(
        customerId: json['customer_id'] as String? ?? '',
        productId: json['product_id'] as String? ?? '',
        quantity: (json['quantity'] as num?)?.toInt() ?? 0,
      );

  final String customerId;
  final String productId;
  final int quantity;
}

/// Go: `OrderOutput`.
final class _OrderOutput {
  const _OrderOutput({
    required this.orderId,
    required this.status,
    required this.totalPrice,
    required this.customerName,
    required this.productName,
    required this.quantity,
    required this.message,
  });

  final String orderId;
  final String status;
  final double totalPrice;
  final String customerName;
  final String productName;
  final int quantity;
  final String message;

  Map<String, Object?> toJson() => {
        'order_id': orderId,
        'status': status,
        'total_price': totalPrice,
        'customer_name': customerName,
        'product_name': productName,
        'quantity': quantity,
        'message': message,
      };
}

/// Go: `validationResult` of example 3.
final class _OrderValidation {
  const _OrderValidation({
    required this.valid,
    this.productName = '',
    this.unitPrice = 0,
    this.customerId = '',
    this.quantity = 0,
  });

  final bool valid;
  final String productName;
  final double unitPrice;
  final String customerId;
  final int quantity;
}

/// Go: `pricingResult`.
final class _PricingResult {
  const _PricingResult({
    required this.totalPrice,
    required this.productName,
    required this.quantity,
  });

  final double totalPrice;
  final String productName;
  final int quantity;
}

/// Go: `customerInfo`.
final class _CustomerInfo {
  const _CustomerInfo(this.customerName, this.email, this.address);

  final String customerName;
  final String email;
  final String address;
}

/// Go: `orderContext`, the input of `generate_confirmation`, assembled by
/// `compose.ToField("Pricing")` and `compose.ToField("Customer")`.
final class _OrderContext implements FieldAddressable {
  const _OrderContext({this.pricing, this.customer});

  final _PricingResult? pricing;
  final _CustomerInfo? customer;

  @override
  Object? getField(String name) => switch (name) {
        'Pricing' => pricing,
        'Customer' => customer,
        _ => throw ArgumentError.value(name, 'name', 'orderContext has no such field'),
      };

  @override
  _OrderContext withField(String name, Object? value) => switch (name) {
        'Pricing' => _OrderContext(
            pricing: value as _PricingResult?,
            customer: customer,
          ),
        'Customer' => _OrderContext(
            pricing: pricing,
            customer: value as _CustomerInfo?,
          ),
        _ => throw ArgumentError.value(name, 'name', 'orderContext has no such field'),
      };
}

/// Go: `mockValidateOrder` (sleeps 50 ms).
_OrderValidation _mockValidateOrder(_OrderInput input) {
  const products = {
    'P100': ('Laptop Pro', 999.99),
    'P101': ('Wireless Mouse', 29.99),
    'P102': ('Mechanical Keyboard', 149.99),
    'P103': ('4K Monitor', 499.99),
  };
  final product = products[input.productId];
  if (product == null) return const _OrderValidation(valid: false);
  if (input.quantity <= 0 || input.quantity > 100) {
    return const _OrderValidation(valid: false);
  }
  return _OrderValidation(
    valid: true,
    productName: product.$1,
    unitPrice: product.$2,
    customerId: input.customerId,
    quantity: input.quantity,
  );
}

/// Go: `mockCalculatePrice` (sleeps 30 ms).
_PricingResult _mockCalculatePrice(_OrderValidation validation) {
  var total = validation.unitPrice * validation.quantity;
  if (validation.quantity >= 10) total *= 0.9;
  return _PricingResult(
    totalPrice: total,
    productName: validation.productName,
    quantity: validation.quantity,
  );
}

/// Go: `mockLookupCustomer` (sleeps 40 ms).
_CustomerInfo _mockLookupCustomer(_OrderValidation validation) {
  const customers = {
    'C001': _CustomerInfo('Alice Johnson', 'alice@example.com', '123 Main St, New York'),
    'C002': _CustomerInfo('Bob Smith', 'bob@example.com', '456 Oak Ave, Los Angeles'),
    'C003': _CustomerInfo('Carol White', 'carol@example.com', '789 Pine Rd, Chicago'),
  };
  return customers[validation.customerId] ??
      const _CustomerInfo('Unknown Customer', 'unknown@example.com', 'Unknown Address');
}

/// How often each node of the order workflow ran.
final class _OrderRuns {
  int validate = 0;
  int calculatePrice = 0;
  int lookupCustomer = 0;
  int generateConfirmation = 0;

  List<int> get all =>
      [validate, calculatePrice, lookupCustomer, generateConfirmation];
}

/// Go: `NewOrderProcessingTool`.
InvokableTool _newOrderProcessingTool(_OrderRuns runs) {
  final workflow = Workflow<_OrderInput, _OrderOutput>();
  workflow
      .addLambdaNode('validate', Lambda.invokable((ctx, _OrderInput input) {
        runs.validate++;
        return _mockValidateOrder(input);
      }))
      .addInput(Graph.start);
  workflow
      .addLambdaNode(
        'calculate_price',
        Lambda<_OrderValidation, _PricingResult>.invokable((ctx, validation) {
          runs.calculatePrice++;
          if (!validation.valid) {
            throw const ThreepioException(
              'invalid order: product not found or invalid quantity',
            );
          }
          return _mockCalculatePrice(validation);
        }),
      )
      .addInput('validate');
  workflow
      .addLambdaNode(
        'lookup_customer',
        Lambda.invokable((ctx, _OrderValidation validation) {
          runs.lookupCustomer++;
          return _mockLookupCustomer(validation);
        }),
      )
      .addInput('validate');
  workflow
      .addLambdaNode(
        'generate_confirmation',
        Lambda.invokable((ctx, _OrderContext input) {
          runs.generateConfirmation++;
          final orderId =
              'ORD-${DateTime.now().microsecondsSinceEpoch * 1000 % 1000000}';
          final pricing = input.pricing!;
          final customer = input.customer!;
          return _OrderOutput(
            orderId: orderId,
            status: 'confirmed',
            totalPrice: pricing.totalPrice,
            customerName: customer.customerName,
            productName: pricing.productName,
            quantity: pricing.quantity,
            message: 'Order $orderId confirmed! ${pricing.quantity} x '
                '${pricing.productName} for ${customer.customerName}. Total: '
                '\$${pricing.totalPrice.toStringAsFixed(2)}',
          );
        }),
      )
      .addInput('calculate_price', [FieldMapping.toField('Pricing')])
      .addInput('lookup_customer', [FieldMapping.toField('Customer')]);
  workflow.end().addInput('generate_confirmation');

  return GraphTool.invokable<_OrderInput, _OrderOutput>(
    name: 'process_order',
    description:
        'Process a customer order. Validates the order, calculates pricing, '
        'looks up customer info, and generates a confirmation.',
    params: const ParamsOneOf.params({
      'customer_id': ParameterInfo(
        type: DataType.string,
        desc: 'Customer identifier',
        required: true,
      ),
      'product_id': ParameterInfo(
        type: DataType.string,
        desc: 'Product identifier to order',
        required: true,
      ),
      'quantity': ParameterInfo(
        type: DataType.integer,
        desc: 'Number of items to order',
        required: true,
      ),
    }),
    fromJson: _OrderInput.fromJson,
    graph: workflow,
    toJson: (output) => output.toJson(),
  );
}

ChatModelAgent _orderAssistant(BaseChatModel model, BaseTool tool) =>
    ChatModelAgent(ChatModelAgentConfig(
      name: 'OrderAssistant',
      description: 'An assistant that can process customer orders',
      instruction: '''You are a helpful order processing assistant.
When the user wants to place an order, use the process_order tool with the customer_id, product_id, and quantity.
Available products: P100 (Laptop Pro \$999.99), P101 (Wireless Mouse \$29.99), P102 (Mechanical Keyboard \$149.99), P103 (4K Monitor \$499.99).
Available customers: C001 (Alice), C002 (Bob), C003 (Carol).
All orders require human approval before processing.''',
      model: model,
      toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [tool])),
    ));

// ---------------------------------------------------------------------------
// Example 4: 4_nested_interrupt (approvable wrapper + workflow interrupt).
// ---------------------------------------------------------------------------

/// Go: `TransferInput`.
final class _TransferInput {
  const _TransferInput({
    this.fromAccount = '',
    this.toAccount = '',
    this.amount = 0,
  });

  factory _TransferInput.fromJson(Map<String, Object?> json) => _TransferInput(
        fromAccount: json['from_account'] as String? ?? '',
        toAccount: json['to_account'] as String? ?? '',
        amount: (json['amount'] as num?)?.toDouble() ?? 0,
      );

  final String fromAccount;
  final String toAccount;
  final double amount;
}

/// Go: `TransferOutput` (no `omitempty`: zero fields are encoded too).
final class _TransferOutput {
  const _TransferOutput({
    this.transactionId = '',
    this.status = '',
    this.message = '',
    this.fromBalance = 0,
    this.toBalance = 0,
  });

  final String transactionId;
  final String status;
  final String message;
  final double fromBalance;
  final double toBalance;

  Map<String, Object?> toJson() => {
        'transaction_id': transactionId,
        'status': status,
        'message': message,
        'from_balance': fromBalance,
        'to_balance': toBalance,
      };
}

/// Go: `InternalApprovalInfo` (registered with `schema.Register`).
final class _InternalApprovalInfo {
  const _InternalApprovalInfo({required this.step, required this.message});

  factory _InternalApprovalInfo.fromJson(Map<String, Object?> json) =>
      _InternalApprovalInfo(
        step: json['Step']! as String,
        message: json['Message']! as String,
      );

  final String step;
  final String message;

  Map<String, Object?> toJson() => {'Step': step, 'Message': message};

  @override
  String toString() => '\n[INTERNAL WORKFLOW APPROVAL]\nStep: $step\n'
      'Message: $message\nApprove? (Y/N):';
}

/// Go: `InternalApprovalResult` (registered with `schema.Register`).
final class _InternalApprovalResult {
  const _InternalApprovalResult({required this.approved, this.comment = ''});

  factory _InternalApprovalResult.fromJson(Map<String, Object?> json) =>
      _InternalApprovalResult(
        approved: json['Approved']! as bool,
        comment: json['Comment']! as String,
      );

  final bool approved;
  final String comment;

  Map<String, Object?> toJson() => {'Approved': approved, 'Comment': comment};
}

/// Go: `validationResult` of example 4 (registered with `schema.Register`:
/// it is the interrupt state of `risk_check_and_execute` and goes into the
/// workflow's checkpoint).
final class _TransferValidation {
  const _TransferValidation({
    required this.valid,
    this.fromAccount = '',
    this.toAccount = '',
    this.amount = 0,
  });

  factory _TransferValidation.fromJson(Map<String, Object?> json) =>
      _TransferValidation(
        valid: json['Valid']! as bool,
        fromAccount: json['FromAccount']! as String,
        toAccount: json['ToAccount']! as String,
        amount: (json['Amount']! as num).toDouble(),
      );

  final bool valid;
  final String fromAccount;
  final String toAccount;
  final double amount;

  Map<String, Object?> toJson() => {
        'Valid': valid,
        'FromAccount': fromAccount,
        'ToAccount': toAccount,
        'Amount': amount,
      };
}

/// What the transfer workflow did (Go prints it).
final class _TransferRuns {
  int validate = 0;
  int riskCheck = 0;
  final List<String> log = [];
}

/// Go: `NewTransferToolWithInternalInterrupt`.
InvokableTool _newTransferTool(_TransferRuns runs) {
  final workflow = Workflow<_TransferInput, _TransferOutput>();
  workflow
      .addLambdaNode('validate', Lambda.invokable((ctx, _TransferInput input) {
        runs.validate++;
        runs.log.add('[Workflow] Validating transfer...');
        if (input.amount <= 0) return const _TransferValidation(valid: false);
        return _TransferValidation(
          valid: true,
          fromAccount: input.fromAccount,
          toAccount: input.toAccount,
          amount: input.amount,
        );
      }))
      .addInput(Graph.start);
  workflow
      .addLambdaNode(
        'risk_check_and_execute',
        Lambda.invokable((ctx, _TransferValidation validation) {
          runs.riskCheck++;
          final saved = getInterruptState<_TransferValidation>(ctx);
          final storedValidation = saved.state;

          if (saved.wasInterrupted) {
            runs.log.add('[Workflow] Resuming from interrupt...');
            final resumed = getResumeContext<_InternalApprovalResult>(ctx);
            if (!resumed.isResumeTarget) {
              runs.log.add('[Workflow] Not resume target, re-interrupting...');
              throw statefulInterrupt(
                ctx,
                _InternalApprovalInfo(
                  step: 'risk_check',
                  message: 'High-value transfer of '
                      '\$${storedValidation!.amount.toStringAsFixed(2)} '
                      'requires risk team approval',
                ),
                storedValidation,
              );
            }
            if (!resumed.hasData) {
              throw const ThreepioException('resumed without approval data');
            }
            final data = resumed.data!;
            if (!data.approved) {
              return _TransferOutput(
                status: 'rejected',
                message: 'Transfer rejected by risk team: ${data.comment}',
              );
            }
            runs.log
              ..add('[Workflow] Risk team approved with comment: '
                  '${data.comment}')
              ..add('[Workflow] Executing transfer...');
            final amount = storedValidation!.amount;
            return _TransferOutput(
              transactionId: 'TXN-12345',
              status: 'completed',
              message: 'Transfer of \$${amount.toStringAsFixed(2)} completed '
                  '(risk approved)',
              fromBalance: 10000 - amount,
              toBalance: 5000 + amount,
            );
          }

          if (!validation.valid) {
            return const _TransferOutput(
              status: 'rejected',
              message: 'Invalid transfer: validation failed',
            );
          }

          runs.log.add('[Workflow] Performing risk check...');
          if (validation.amount > 1000) {
            runs.log.add('[Workflow] High-value transfer detected, triggering '
                'INTERNAL interrupt...');
            throw statefulInterrupt(
              ctx,
              _InternalApprovalInfo(
                step: 'risk_check',
                message: 'High-value transfer of '
                    '\$${validation.amount.toStringAsFixed(2)} requires risk '
                    'team approval',
              ),
              validation,
            );
          }

          runs.log.add('[Workflow] Low-value transfer, executing directly...');
          return _TransferOutput(
            transactionId: 'TXN-12345',
            status: 'completed',
            message: 'Transfer of \$${validation.amount.toStringAsFixed(2)} '
                'completed',
            fromBalance: 10000 - validation.amount,
            toBalance: 5000 + validation.amount,
          );
        }),
      )
      .addInput('validate');
  workflow.end().addInput('risk_check_and_execute');

  return GraphTool.invokable<_TransferInput, _TransferOutput>(
    name: 'transfer_funds',
    description: 'Transfer funds between accounts. High-value transfers '
        r'(>$1000) require internal risk approval.',
    params: const ParamsOneOf.params({
      'from_account': ParameterInfo(
        type: DataType.string,
        desc: 'Source account ID',
        required: true,
      ),
      'to_account': ParameterInfo(
        type: DataType.string,
        desc: 'Destination account ID',
        required: true,
      ),
      'amount': ParameterInfo(
        type: DataType.number,
        desc: 'Amount to transfer',
        required: true,
      ),
    }),
    fromJson: _TransferInput.fromJson,
    graph: workflow,
    toJson: (output) => output.toJson(),
  );
}

ChatModelAgent _transferAssistant(BaseChatModel model, BaseTool tool) =>
    ChatModelAgent(ChatModelAgentConfig(
      name: 'TransferAssistant',
      description: 'An assistant that can transfer funds between accounts',
      instruction: '''You are a helpful banking assistant.
When the user wants to transfer funds, IMMEDIATELY use the transfer_funds tool without asking for confirmation.
All transfers require initial approval. High-value transfers (>\$1000) also require internal risk team approval.''',
      model: model,
      toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [tool])),
    ));

// ---------------------------------------------------------------------------
// Unit-test fixtures.
// ---------------------------------------------------------------------------

/// The input of the unit-test graphs. Registered: it is the input of the
/// first node and goes into a checkpoint when the graph interrupts.
final class _In {
  const _In(this.text);

  factory _In.fromJson(Map<String, Object?> json) =>
      _In(json['text'] as String? ?? '');

  final String text;

  Map<String, Object?> toJson() => {'text': text};
}

/// The output of the unit-test graphs.
final class _Out {
  const _Out(this.text, this.length);

  final String text;
  final int length;

  Map<String, Object?> toJson() => {'text': text, 'length': length};
}

/// A lambda call option of the unit tests.
final class _Tag {
  const _Tag(this.name);

  final String name;

  @override
  bool operator ==(Object other) => other is _Tag && other.name == name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => '_Tag($name)';
}

const _inParams = ParamsOneOf.params({
  'text': ParameterInfo(type: DataType.string, desc: 'The text', required: true),
});

/// A chain that answers the text and its length; counts its runs in [runs].
Chain<_In, _Out> _echoChain(List<String> runs) => Chain<_In, _Out>()
  ..appendLambda(Lambda.invokable((ctx, _In input) {
    runs.add(input.text);
    return _Out(input.text, input.text.length);
  }));

InvokableTool _echoTool(List<String> runs) => GraphTool.invokable<_In, _Out>(
      name: 'echo',
      description: 'Echoes the text',
      params: _inParams,
      fromJson: _In.fromJson,
      graph: _echoChain(runs),
      toJson: (output) => output.toJson(),
    );

/// A graph that streams the words of its input, one [_Out] per word.
Graph<_In, _Out> _wordsGraph() => Graph<_In, _Out>()
  ..addLambdaNode(
    'words',
    Lambda<_In, _Out>.streamable(
      (ctx, input) => StreamReader.fromIterable([
        for (final word in input.text.split(' ')) _Out(word, word.length),
      ]),
    ),
  )
  ..addEdge(Graph.start, 'words')
  ..addEdge('words', Graph.end);

/// A graph whose `gate` interrupts on its first run and, resumed as the
/// target, goes on with the text and the resume data; `words` then streams.
Graph<_In, _Out> _gatedWordsGraph(List<String> gateLog) => Graph<_In, _Out>()
  ..addLambdaNode(
    'gate',
    Lambda<_In, _In>.invokable((ctx, input) {
      final saved = getInterruptState<String>(ctx);
      if (!saved.wasInterrupted) {
        gateLog.add('interrupt ${input.text}');
        throw statefulInterrupt(ctx, 'confirm ${input.text}?', input.text);
      }
      final resumed = getResumeContext<String>(ctx);
      if (!resumed.isResumeTarget) {
        gateLog.add('interrupt again ${saved.state}');
        throw statefulInterrupt(ctx, 'confirm ${saved.state}?', saved.state);
      }
      gateLog.add('resumed ${saved.state} with ${resumed.data}');
      return _In('${saved.state} ${resumed.data}');
    }),
  )
  ..addLambdaNode(
    'words',
    Lambda<_In, _Out>.streamable(
      (ctx, input) => StreamReader.fromIterable([
        for (final word in input.text.split(' ')) _Out(word, word.length),
      ]),
    ),
  )
  ..addEdge(Graph.start, 'gate')
  ..addEdge('gate', 'words')
  ..addEdge('words', Graph.end);

/// The signals of the tree below [signal] (itself included).
Iterable<AddressedInterruptSignal> _signalTree(
  AddressedInterruptSignal signal,
) sync* {
  yield signal;
  for (final sub in signal.subs) {
    yield* _signalTree(sub);
  }
}

/// Checks that [error] is the graph tool's composite interrupt
/// (Go: `tool.CompositeInterrupt(ctx, "graph tool interrupt",
/// &graphToolInterruptState{Data, ToolInput}, interruptErr)`) for a call with
/// [arguments] whose graph interrupted with [rootInfo].
void _expectGraphToolInterrupt(
  Object? error,
  String arguments,
  Object? rootInfo,
) {
  expect(error, isA<AddressedInterruptSignal>(), reason: '$error');
  final signal = error! as AddressedInterruptSignal;
  expect(signal.info, 'graph tool interrupt');
  expect(signal.isRootCause, isFalse);
  expect(signal.subs, isNotEmpty);
  final roots = _signalTree(signal).where((s) => s.isRootCause).toList();
  expect(roots.map((s) => s.info), [rootInfo]);
  final state = TypeRegistry.encode(signal.state.state)! as Map;
  expect(state[r'$type'], '_eino_graph_tool_interrupt_state');
  final value = state[r'$value'] as Map;
  expect(value['tool_input'], arguments);
  expect(base64Decode(value['data'] as String), isNotEmpty);
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

void main() {
  setUpAll(() {
    FieldAddressable.registerBlank<_OrderContext>(() => const _OrderContext());
    TypeRegistry.registerName<_TransferValidation>(
      '$_prefix.validationResult',
      fromJson: _TransferValidation.fromJson,
      toJson: (value) => value.toJson(),
    );
    TypeRegistry.registerName<_InternalApprovalInfo>(
      '$_prefix.InternalApprovalInfo',
      fromJson: _InternalApprovalInfo.fromJson,
      toJson: (value) => value.toJson(),
    );
    TypeRegistry.registerName<_InternalApprovalResult>(
      '$_prefix.InternalApprovalResult',
      fromJson: _InternalApprovalResult.fromJson,
      toJson: (value) => value.toJson(),
    );
    TypeRegistry.registerName<_In>(
      '$_prefix.In',
      fromJson: _In.fromJson,
      toJson: (value) => value.toJson(),
    );
  });

  for (final streaming in [false, true]) {
    group('1_chain_summarize (streaming: $streaming)', () {
      final args = jsonEncode({'document': _sampleDocument, 'max_words': 50});
      const finalAnswer = 'Here is the summary: AI has reshaped industries.';
      late ScriptedChatModel model;
      late ScriptedChatModel cm;
      late Runner runner;

      setUp(() {
        model = _callingModel('summarize_document', args, finalAnswer);
        cm = ScriptedChatModel([
          [text(_keyPoints), finish('stop')],
          [text(_summary), finish('stop')],
        ]);
        runner = Runner(
          agent: _documentAssistant(model, _newSummarizeTool(cm)),
          enableStreaming: streaming,
        );
      });

      test('the chain extracts key points, condenses them, and the model sees '
          'the JSON of SummarizeOutput', () async {
        const query =
            'Please summarize this document in about 50 words:\n\n$_sampleDocument';
        final events = await _collectOk(runner.query(RunContext.background(), query));

        // The chain's two model calls: the prompts of the example.
        expect(cm.calls, hasLength(2));
        final extract = cm.calls[0].messages;
        expect(extract.map((m) => m.role), [RoleType.system, RoleType.user]);
        expect(extract[0].content, _extractSystem);
        expect(
          extract[1].content,
          'Document:\n$_sampleDocument\n\nExtract the key points:',
        );
        final condense = cm.calls[1].messages;
        expect(condense.map((m) => m.role), [RoleType.system, RoleType.user]);
        // The second lambda always asks for 100 words (Go: "max_words": 100).
        expect(condense[0].content,
            _condenseSystem.replaceAll('{max_words}', '100'));
        expect(
          condense[1].content,
          'Key Points:\n$_keyPoints\n\nCreate a summary in approximately 100 '
          'words:',
        );

        // What the agent's model sees: sonic.MarshalString(SummarizeOutput).
        expect(model.calls, hasLength(2));
        final result = _toolResultOf(model.calls[1], 'call_1');
        expect(
          result,
          jsonEncode({
            'summary': _summary,
            'key_points': <String>[],
            'word_count': _countWords(_summary),
          }),
        );
        expect(_countWords(_summary), 24);

        // The events: tool call, tool result, answer.
        final messages = await _messagesOf(events);
        expect(messages, hasLength(3));
        expect(messages[0]!.toolCalls!.single.function.name, 'summarize_document');
        expect(messages[0]!.toolCalls!.single.function.arguments, args);
        expect(messages[1]!.role, RoleType.tool);
        expect(messages[1]!.content, result);
        expect(events[1].output!.messageOutput!.toolName, 'summarize_document');
        expect(messages[2]!.content, finalAnswer);
      });

      test('max_words <= 0 defaults to 100 in the first prompt variables; the '
          'second prompt always gets 100', () async {
        // The template variables are seen through a callback handed to the
        // graph with GraphToolOptions (Go: WithGraphToolOption(
        // compose.WithCallbacks(h))).
        final recorder = _TemplateRecorder();
        model = _callingModel(
          'summarize_document',
          jsonEncode({'document': 'One short line.'}),
          finalAnswer,
        );
        runner = Runner(
          agent: _documentAssistant(model, _newSummarizeTool(cm)),
          enableStreaming: streaming,
        );
        await _collectOk(runner.query(
          RunContext.background(),
          'summarize',
          options: [
            AgentRunOption.toolOptions(ToolOptions(extensions: [
              GraphToolOptions([CallOption.callbacks([recorder])]),
            ])),
          ],
        ));
        expect(recorder.variables, [
          {'document': 'One short line.', 'max_words': 100},
          {'key_points': _keyPoints, 'max_words': 100},
        ]);
        expect(cm.calls[0].messages[1].content,
            'Document:\nOne short line.\n\nExtract the key points:');
        expect(jsonDecode(_toolResultOf(model.calls[1], 'call_1')),
            containsPair('summary', _summary));
      });
    });
  }

  group('2_graph_research', () {
    const query = 'best practices for building microservices';
    const toolArgs = '{"query":"$query"}';
    final innerChunks = [
      text('Microservices should '),
      text('be small, '),
      text('independently deployable.'),
      finish('stop'),
    ];
    late ScriptedChatModel model;
    late ScriptedChatModel cm;
    late List<String> log;
    late Runner runner;

    setUp(() {
      log = [];
      model = ScriptedChatModel([
        [
          toolCallDelta(0, id: 'call_1', name: 'research_topic', args: toolArgs),
          finish('tool_calls'),
        ],
      ]);
      cm = ScriptedChatModel([innerChunks]);
      runner = Runner(
        agent: ChatModelAgent(ChatModelAgentConfig(
          name: 'ResearchAssistant',
          description:
              'An assistant that can research topics using multiple sources',
          instruction: '''You are a helpful research assistant.
When the user asks about a topic or wants to learn something, use the research_topic tool to gather information from multiple sources.
The tool will stream the research results directly to the user.''',
          model: model,
          toolsConfig: ToolsConfig(
            toolsNode: ToolsNodeConfig(tools: [_newResearchTool(cm, log)]),
            returnDirectly: const {'research_topic'},
          ),
        )),
        enableStreaming: true,
      );
    });

    test('the synthesis streams to the user chunk by chunk, returned directly',
        () async {
      final events = await _collectOk(runner.query(
        RunContext.background(),
        'What are the best practices for building microservices?',
      ));

      // The graph: three searches in parallel, finishing in the order of the
      // Go sleeps (local 50 ms, knowledge base 80 ms, web 100 ms).
      expect(log, [
        '[Graph] Starting parallel searches...',
        '[Graph] Local file search completed',
        '[Graph] Knowledge base search completed',
        '[Graph] Web search completed',
        '[Graph] All searches completed, preparing synthesis...',
      ]);
      final synthesize = cm.calls.single.messages;
      expect(synthesize.map((m) => m.role), [RoleType.system, RoleType.user]);
      expect(synthesize[0].content, _synthesizeSystem);
      expect(
        synthesize[1].content,
        'Research Query: $query\n\n'
        'Web Search Results:\n${await _mockWebSearch(query)}\n\n'
        'Knowledge Base Results:\n${await _mockKnowledgeBaseSearch(query)}\n\n'
        'Local File Results:\n${await _mockLocalFileSearch(query)}\n\n'
        'Please synthesize these results into a comprehensive summary:',
      );

      // ReturnDirectly: the tool's stream is the last event; the agent's
      // model is not called again.
      expect(model.calls, hasLength(1));
      expect(events, hasLength(2));
      expect(events[0].output!.messageOutput!.isStreaming, isTrue);
      final call = (await getMessageFromEvent(events[0]))!.toolCalls!.single;
      expect(call.function.name, 'research_topic');
      expect(call.function.arguments, toolArgs);

      final variant = events[1].output!.messageOutput!;
      expect(variant.isStreaming, isTrue);
      expect(variant.role, RoleType.tool);
      expect(variant.toolName, 'research_topic');
      final chunks = await variant.messageStream!.collectAll();
      // One tool chunk per chunk of the model inside the graph, each the
      // message chunk marshalled (Go: sonic.MarshalString(chunk)).
      expect(chunks.map((c) => c.content),
          [for (final chunk in innerChunks) jsonEncode(chunk)]);
      for (final chunk in chunks) {
        expect(chunk.role, RoleType.tool);
        expect(chunk.toolCallId, 'call_1');
      }
      final decoded = [
        for (final chunk in chunks)
          Message.fromJson(jsonDecode(chunk.content) as Map<String, dynamic>),
      ];
      expect(decoded.map((m) => m.content),
          ['Microservices should ', 'be small, ', 'independently deployable.', '']);
      expect(decoded.map((m) => m.role), everyElement(RoleType.assistant));
      expect(decoded.last.responseMeta?.finishReason, 'stop');
    });
  });

  for (final streaming in [false, true]) {
    group('3_workflow_order (streaming: $streaming)', () {
      const checkpointId = 'order-session-1';
      const toolArgs =
          '{"customer_id":"C001","product_id":"P100","quantity":3}';
      const finalAnswer = 'Your order has been processed.';
      late _OrderRuns runs;
      late ScriptedChatModel model;
      late InMemoryCheckpointStore store;
      late Runner runner;

      setUp(() {
        runs = _OrderRuns();
        model = _callingModel('process_order', toolArgs, finalAnswer);
        store = InMemoryCheckpointStore();
        runner = Runner(
          agent: _orderAssistant(
            model,
            ApprovableTool(_newOrderProcessingTool(runs)),
          ),
          enableStreaming: streaming,
          checkpointStore: store,
        );
      });

      /// Runs the query until the approval interrupt and checks it.
      Future<InterruptCtx> askForApproval() async {
        final (before, interrupted) = await _runUntilInterrupt(runner.query(
          RunContext.background(),
          'Place an order for customer C001, product P100 (Laptop Pro), '
          'quantity 3',
          options: [AgentRunOption.checkpointId(checkpointId)],
        ));
        final messages = await _messagesOf(before);
        expect(messages.single!.toolCalls!.single.function.name, 'process_order');
        final point = interrupted.interruptContexts.single;
        expect(point.isRootCause, isTrue);
        expect(point.address.toString(),
            'agent:OrderAssistant;tool:process_order:call_1');
        expect(
          point.info,
          const ApprovalInfo(toolName: 'process_order', argumentsJson: toolArgs),
        );
        expect(store.keys, [checkpointId]);
        expect(runs.all, [0, 0, 0, 0], reason: 'nothing runs before approval');
        expect(model.calls, hasLength(1));
        return point;
      }

      test('approve (Y): the workflow validates, prices, looks up the '
          'customer and confirms', () async {
        final point = await askForApproval();
        final events = await _collectOk(await _resume(
          runner,
          checkpointId,
          point.id,
          const ApprovalResult(approved: true),
        ));

        expect(runs.all, [1, 1, 1, 1]);
        final result = _toolResultOf(model.calls[1], 'call_1');
        final output = jsonDecode(result) as Map<String, Object?>;
        // sonic.MarshalString(OrderOutput): the fields in struct order.
        expect(output.keys, [
          'order_id',
          'status',
          'total_price',
          'customer_name',
          'product_name',
          'quantity',
          'message',
        ]);
        final orderId = output['order_id']! as String;
        expect(orderId, matches(RegExp(r'^ORD-\d+$')));
        expect(output['status'], 'confirmed');
        expect(output['total_price'], 999.99 * 3);
        expect(output['customer_name'], 'Alice Johnson');
        expect(output['product_name'], 'Laptop Pro');
        expect(output['quantity'], 3);
        expect(
          output['message'],
          'Order $orderId confirmed! 3 x Laptop Pro for Alice Johnson. '
          r'Total: $2999.97',
        );

        final messages = await _messagesOf(events);
        expect(messages, hasLength(2));
        expect(messages[0]!.role, RoleType.tool);
        expect(messages[0]!.content, result);
        expect(events[0].output!.messageOutput!.toolName, 'process_order');
        expect(messages[1]!.content, finalAnswer);
        expect(model.calls, hasLength(2));
      });

      test('reject (N) with a reason: the workflow does not run', () async {
        final point = await askForApproval();
        final events = await _collectOk(await _resume(
          runner,
          checkpointId,
          point.id,
          const ApprovalResult(approved: false, disapproveReason: 'too expensive'),
        ));

        expect(runs.all, [0, 0, 0, 0]);
        expect(
          _toolResultOf(model.calls[1], 'call_1'),
          "tool 'process_order' disapproved, reason: too expensive",
        );
        final messages = await _messagesOf(events);
        expect(messages.last!.content, finalAnswer);
      });
    });
  }

  for (final streaming in [false, true]) {
    group('4_nested_interrupt (streaming: $streaming)', () {
      const checkpointId = 'nested-interrupt-test';
      const toolArgs =
          '{"from_account":"A001","to_account":"B002","amount":1500}';
      const toolAddress = 'agent:TransferAssistant;tool:transfer_funds:call_1';
      const finalAnswer = 'The transfer request has been handled.';
      late _TransferRuns runs;
      late ScriptedChatModel model;
      late InMemoryCheckpointStore store;
      late Runner runner;

      void build(String args) {
        runs = _TransferRuns();
        model = _callingModel('transfer_funds', args, finalAnswer);
        store = InMemoryCheckpointStore();
        runner = Runner(
          agent: _transferAssistant(model, ApprovableTool(_newTransferTool(runs))),
          enableStreaming: streaming,
          checkpointStore: store,
        );
      }

      setUp(() => build(toolArgs));

      /// Interrupt #1: the approvable wrapper asks before the workflow runs.
      Future<InterruptCtx> outerInterrupt(String args) async {
        final (before, interrupted) = await _runUntilInterrupt(runner.query(
          RunContext.background(),
          r'Transfer $1500 from account A001 to account B002',
          options: [AgentRunOption.checkpointId(checkpointId)],
        ));
        expect((await _messagesOf(before)).single!.toolCalls!.single.function.name,
            'transfer_funds');
        final point = interrupted.interruptContexts.single;
        expect(point.isRootCause, isTrue);
        expect(point.address.toString(), toolAddress);
        expect(
          point.info,
          ApprovalInfo(toolName: 'transfer_funds', argumentsJson: args),
        );
        expect(runs.validate, 0, reason: 'the workflow has not started');
        expect(store.keys, [checkpointId]);
        return point;
      }

      /// Interrupt #2: approved, the workflow runs and its risk check
      /// interrupts inside the graph tool.
      Future<InterruptCtx> innerInterrupt(InterruptCtx first) async {
        final (before, interrupted) = await _runUntilInterrupt(await _resume(
          runner,
          checkpointId,
          first.id,
          const ApprovalResult(approved: true),
        ));
        expect(before, isEmpty, reason: '$before');
        final point = interrupted.interruptContexts.single;
        expect(point.id, isNot(first.id));
        expect(point.isRootCause, isTrue);
        // Only agent and tool segments are shown: the workflow's node is
        // part of the tool call.
        expect(point.address.toString(), toolAddress);
        expect(point.info, isA<_InternalApprovalInfo>());
        final info = point.info! as _InternalApprovalInfo;
        expect(info.step, 'risk_check');
        expect(info.message,
            r'High-value transfer of $1500.00 requires risk team approval');
        expect(
          '$info',
          '\n[INTERNAL WORKFLOW APPROVAL]\nStep: risk_check\nMessage: '
          'High-value transfer of \$1500.00 requires risk team approval\n'
          'Approve? (Y/N):',
        );
        // Its parent is the graph tool's composite interrupt.
        final parent = point.parent;
        expect(parent, isNotNull);
        expect(parent!.info, 'graph tool interrupt');
        expect(parent.isRootCause, isFalse);
        expect(parent.address.toString(), toolAddress);
        final ancestors = [
          for (InterruptCtx? p = parent.parent; p != null; p = p.parent)
            p.address.toString(),
        ];
        expect(ancestors, contains('agent:TransferAssistant'));

        expect(runs.validate, 1);
        expect(runs.riskCheck, 1);
        expect(runs.log, [
          '[Workflow] Validating transfer...',
          '[Workflow] Performing risk check...',
          ('[Workflow] High-value transfer detected, triggering INTERNAL '
              'interrupt...'),
        ]);
        expect(model.calls, hasLength(1));
        return point;
      }

      test('approve both: the risk team approves and the transfer completes',
          () async {
        final first = await outerInterrupt(toolArgs);
        final second = await innerInterrupt(first);
        final events = await _collectOk(await _resume(
          runner,
          checkpointId,
          second.id,
          const _InternalApprovalResult(
            approved: true,
            comment: 'Risk approved by manager',
          ),
        ));

        // The workflow resumed at the risk check; validate did not run again.
        expect(runs.validate, 1);
        expect(runs.riskCheck, 2);
        expect(runs.log.skip(3), [
          '[Workflow] Resuming from interrupt...',
          '[Workflow] Risk team approved with comment: Risk approved by manager',
          '[Workflow] Executing transfer...',
        ]);

        final result = _toolResultOf(model.calls[1], 'call_1');
        expect(jsonDecode(result), {
          'transaction_id': 'TXN-12345',
          'status': 'completed',
          'message': r'Transfer of $1500.00 completed (risk approved)',
          'from_balance': 8500,
          'to_balance': 6500,
        });
        final messages = await _messagesOf(events);
        expect(messages, hasLength(2));
        expect(messages[0]!.content, result);
        expect(events[0].output!.messageOutput!.toolName, 'transfer_funds');
        expect(messages[1]!.content, finalAnswer);
        expect(model.calls, hasLength(2));
      });

      test('approve, then the risk team rejects: the workflow answers '
          'rejected', () async {
        final first = await outerInterrupt(toolArgs);
        final second = await innerInterrupt(first);
        final events = await _collectOk(await _resume(
          runner,
          checkpointId,
          second.id,
          const _InternalApprovalResult(
            approved: false,
            comment: 'Risk team rejected',
          ),
        ));

        expect(runs.validate, 1);
        expect(runs.riskCheck, 2);
        expect(jsonDecode(_toolResultOf(model.calls[1], 'call_1')), {
          'transaction_id': '',
          'status': 'rejected',
          'message': 'Transfer rejected by risk team: Risk team rejected',
          'from_balance': 0,
          'to_balance': 0,
        });
        expect((await _messagesOf(events)).last!.content, finalAnswer);
      });

      test('reject the first approval: the workflow never runs', () async {
        final first = await outerInterrupt(toolArgs);
        final events = await _collectOk(await _resume(
          runner,
          checkpointId,
          first.id,
          const ApprovalResult(approved: false, disapproveReason: 'User rejected'),
        ));

        expect(runs.validate, 0);
        expect(runs.riskCheck, 0);
        expect(
          _toolResultOf(model.calls[1], 'call_1'),
          "tool 'transfer_funds' disapproved, reason: User rejected",
        );
        expect((await _messagesOf(events)).last!.content, finalAnswer);
      });

      test('a low-value transfer has only the approval interrupt', () async {
        const lowArgs =
            '{"from_account":"A001","to_account":"B002","amount":500}';
        build(lowArgs);
        final first = await outerInterrupt(lowArgs);
        final events = await _collectOk(await _resume(
          runner,
          checkpointId,
          first.id,
          const ApprovalResult(approved: true),
        ));

        expect(events.where((e) => e.action?.interrupted != null), isEmpty);
        expect(runs.log, [
          '[Workflow] Validating transfer...',
          '[Workflow] Performing risk check...',
          '[Workflow] Low-value transfer, executing directly...',
        ]);
        expect(jsonDecode(_toolResultOf(model.calls[1], 'call_1')), {
          'transaction_id': 'TXN-12345',
          'status': 'completed',
          'message': r'Transfer of $500.00 completed',
          'from_balance': 9500,
          'to_balance': 5500,
        });
        expect((await _messagesOf(events)).last!.content, finalAnswer);
      });
    });
  }

  group('GraphTool API', () {
    final ctx = RunContext.background();

    test('info() is the name, the description and the schema of the params '
        '(Go: utils.GoStruct2ToolInfo[I](name, desc))', () async {
      final expected = ToolInfo.fromJsonSchema(
        name: 'echo',
        desc: 'Echoes the text',
        schema: _inParams.toJsonSchema(),
      );
      final invokable = _echoTool([]);
      final streamable = GraphTool.streamable<_In, _Out>(
        name: 'echo',
        description: 'Echoes the text',
        params: _inParams,
        fromJson: _In.fromJson,
        graph: _wordsGraph(),
      );
      for (final tool in <BaseTool>[invokable, streamable]) {
        final info = await tool.info();
        expect(info, expected);
        expect(info.function.name, 'echo');
        expect(info.function.description, 'Echoes the text');
        final parameters = info.function.parameters!;
        expect(parameters.properties.keys, ['text']);
        expect(parameters.properties['text']!.type, 'string');
        expect(parameters.properties['text']!.description, 'The text');
        expect(parameters.required, ['text']);
      }
      expect(invokable, isA<InvokableTool>());
      expect(streamable, isA<StreamableTool>());
    });

    test('a graph, a chain and a workflow of the right types are accepted',
        () {
      final workflow = Workflow<_In, _Out>();
      workflow
          .addLambdaNode('n', Lambda.invokable((ctx, _In i) => _Out(i.text, 0)))
          .addInput(Graph.start);
      workflow.end().addInput('n');
      for (final graph in <AnyGraph>[_wordsGraph(), _echoChain([]), workflow]) {
        expect(
          GraphTool.invokable<_In, _Out>(
            name: 't',
            description: 'd',
            params: _inParams,
            fromJson: _In.fromJson,
            graph: graph,
          ),
          isA<InvokableTool>(),
        );
      }
    });

    test('I or O not those of the graph is an ArgumentError (Go: a compile '
        'error of Compilable[I, O])', () {
      expect(
        () => GraphTool.invokable<_In, String>(
          name: 't',
          description: 'd',
          params: _inParams,
          fromJson: _In.fromJson,
          graph: _echoChain([]),
        ),
        throwsArgumentError,
      );
      expect(
        () => GraphTool.invokable<String, _Out>(
          name: 't',
          description: 'd',
          params: _inParams,
          fromJson: (json) => '',
          graph: _echoChain([]),
        ),
        throwsArgumentError,
      );
      expect(
        () => GraphTool.streamable<_In, Message>(
          name: 't',
          description: 'd',
          params: _inParams,
          fromJson: _In.fromJson,
          graph: _wordsGraph(),
        ),
        throwsArgumentError,
      );
    });

    test('the output is encoded as JSON, through toJson', () async {
      final runs = <String>[];
      expect(
        await _echoTool(runs).invokableRun(ctx, '{"text":"hello"}'),
        '{"text":"hello","length":5}',
      );
      expect(runs, ['hello']);

      // Without toJson the output is encoded as it is.
      final plain = GraphTool.invokable<_In, Map<String, Object?>>(
        name: 'plain',
        description: 'd',
        params: _inParams,
        fromJson: _In.fromJson,
        graph: Chain<_In, Map<String, Object?>>()
          ..appendLambda(Lambda.invokable(
            (ctx, _In input) => <String, Object?>{'echo': input.text},
          )),
      );
      expect(await plain.invokableRun(ctx, '{"text":"x"}'), '{"echo":"x"}');
    });

    test('arguments that are not a JSON object fail the call before the graph '
        'runs (Go: sonic.UnmarshalString)', () async {
      final runs = <String>[];
      final tool = _echoTool(runs);
      await expectLater(
        tool.invokableRun(ctx, '{"text": '),
        throwsA(isA<ThreepioFormatException>()),
      );
      await expectLater(
        tool.invokableRun(ctx, '["text"]'),
        throwsA(isA<ThreepioFormatException>()),
      );
      final streamable = GraphTool.streamable<_In, _Out>(
        name: 'words',
        description: 'd',
        params: _inParams,
        fromJson: _In.fromJson,
        graph: _wordsGraph(),
      );
      // Go's StreamableRun returns the unmarshal error itself, no stream.
      await expectLater(
        streamable.streamableRun(ctx, 'not json'),
        throwsA(isA<ThreepioFormatException>()),
      );
      expect(runs, isEmpty);
    });

    test('empty arguments fail like any other non-JSON input (Go: '
        'sonic.UnmarshalString("", &input) is an error)', () async {
      final runs = <String>[];
      await expectLater(
        _echoTool(runs).invokableRun(ctx, ''),
        throwsA(isA<FormatException>()),
      );
      expect(runs, isEmpty);
    });

    test('bad JSON arguments from the model fail the agent run', () async {
      final runs = <String>[];
      final model = _callingModel('echo', '{"text": ', 'never');
      final events = await Runner(
        agent: ChatModelAgent(ChatModelAgentConfig(
          name: 'A',
          description: 'd',
          model: model,
          toolsConfig: ToolsConfig(
            toolsNode: ToolsNodeConfig(tools: [_echoTool(runs)]),
          ),
        )),
      ).query(ctx, 'go').collectAll();
      final error = events.last.error;
      expect(error, isNotNull);
      expect(ThreepioException.findCause<FormatException>(error) ?? error,
          isA<FormatException>());
      expect(events.last.action?.interrupted, isNull);
      expect(runs, isEmpty);
      expect(model.calls, hasLength(1));
    });

    test("GraphToolOptions reach the graph, before the tool's checkpoint id "
        '(Go: WithGraphToolOption)', () async {
      final seen = <List<_Tag>>[];
      final tool = GraphTool.invokable<_In, _Out>(
        name: 'tagged',
        description: 'd',
        params: _inParams,
        fromJson: _In.fromJson,
        graph: Chain<_In, _Out>()
          ..appendLambda(Lambda.invokableWithOption<_In, _Out, _Tag>(
            (ctx, input, options) {
              seen.add(options);
              return _Out(input.text, options.length);
            },
          )),
        toJson: (output) => output.toJson(),
      );
      expect(
        await tool.invokableRun(
          ctx,
          '{"text":"a"}',
          options: ToolOptions(extensions: [
            GraphToolOptions([
              CallOption.lambda<_Tag>([const _Tag('x'), const _Tag('y')]),
            ]),
          ]),
        ),
        '{"text":"a","length":2}',
      );
      expect(seen.single, [const _Tag('x'), const _Tag('y')]);

      // Without them the graph runs with its own options only.
      await tool.invokableRun(ctx, '{"text":"b"}');
      expect(seen.last, isEmpty);
    });

    test('GraphToolOptions given to the agent run reach the model inside the '
        'graph (Go: adk.WithToolOptions(graphtool.WithGraphToolOption(...)))',
        () async {
      final model = _callingModel(
        'summarize_document',
        jsonEncode({'document': 'doc', 'max_words': 10}),
        'done',
      );
      final cm = ScriptedChatModel([
        [text('points'), finish('stop')],
        [text('summary'), finish('stop')],
      ]);
      await _collectOk(
        Runner(agent: _documentAssistant(model, _newSummarizeTool(cm))).query(
          ctx,
          'summarize',
          options: [
            AgentRunOption.toolOptions(ToolOptions(extensions: [
              GraphToolOptions([
                CallOption.chatModel(const ChatModelOptions(temperature: 0.25)),
              ]),
            ])),
          ],
        ),
      );
      expect(cm.calls, hasLength(2));
      expect(cm.calls.map((c) => c.options?.temperature), [0.25, 0.25]);
      // The agent's own model does not get them.
      expect(model.calls.map((c) => c.options?.temperature),
          everyElement(isNot(0.25)));
    });

    test('a failure of the graph that is not an interrupt is the error of the '
        'call', () async {
      Graph<_In, _Out> failing() => Graph<_In, _Out>()
        ..addLambdaNode(
          'bad',
          Lambda<_In, _Out>.invokable((ctx, input) => throw StateError('boom')),
        )
        ..addEdge(Graph.start, 'bad')
        ..addEdge('bad', Graph.end);

      final tool = GraphTool.invokable<_In, _Out>(
        name: 'bad',
        description: 'd',
        params: _inParams,
        fromJson: _In.fromJson,
        graph: failing(),
      );
      Object? error;
      try {
        await tool.invokableRun(ctx, '{"text":"x"}');
        // The failure under test.
        // ignore: avoid_catches_without_on_clauses
      } catch (e) {
        error = e;
      }
      expect(error, isNotNull);
      expect('$error', contains('boom'));
      expect(error, isNot(isA<AddressedInterruptSignal>()));
      expect(extractInterruptInfo(error), isNull);

      // The streamable tool returns its stream; the failure comes through it
      // (Go: sw.Send("", err) from the goroutine).
      final streamable = GraphTool.streamable<_In, _Out>(
        name: 'bad',
        description: 'd',
        params: _inParams,
        fromJson: _In.fromJson,
        graph: failing(),
      );
      final reader = await streamable.streamableRun(ctx, '{"text":"x"}');
      await expectLater(
        reader.collectAll(),
        throwsA(predicate((e) =>
            '$e'.contains('boom') && e is! AddressedInterruptSignal)),
      );

      // Through an agent: an error event, no interrupt.
      final model = _callingModel('bad', '{"text":"x"}', 'never');
      final events = await Runner(
        agent: ChatModelAgent(ChatModelAgentConfig(
          name: 'A',
          description: 'd',
          model: model,
          toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [tool])),
        )),
        checkpointStore: InMemoryCheckpointStore(),
      ).query(ctx, 'go', options: [AgentRunOption.checkpointId('f')]).collectAll();
      expect('${events.last.error}', contains('boom'));
      expect(events.map((e) => e.action?.interrupted), everyElement(isNull));
      expect(model.calls, hasLength(1));
    });

    test('the streamable tool streams one JSON chunk per chunk of the graph',
        () async {
      final tool = GraphTool.streamable<_In, _Out>(
        name: 'words',
        description: 'd',
        params: _inParams,
        fromJson: _In.fromJson,
        graph: _wordsGraph(),
        toJson: (output) => output.toJson(),
      );
      final reader = await tool.streamableRun(ctx, '{"text":"one two three"}');
      final chunks = <String>[];
      for (var c = await reader.nextOrNull(); c != null; c = await reader.nextOrNull()) {
        chunks.add(c);
      }
      expect(chunks, [
        '{"text":"one","length":3}',
        '{"text":"two","length":3}',
        '{"text":"three","length":5}',
      ]);

      // Through an agent (streaming): the tool's chunks are its event's
      // stream, and the model sees them concatenated.
      final model = _callingModel('words', '{"text":"a bb"}', 'ok');
      final events = await _collectOk(Runner(
        agent: ChatModelAgent(ChatModelAgentConfig(
          name: 'A',
          description: 'd',
          model: model,
          toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [tool])),
        )),
        enableStreaming: true,
      ).query(ctx, 'go'));
      final variant = events[1].output!.messageOutput!;
      expect(variant.isStreaming, isTrue);
      expect(variant.toolName, 'words');
      expect(
        (await variant.messageStream!.collectAll()).map((m) => m.content),
        ['{"text":"a","length":1}', '{"text":"bb","length":2}'],
      );
      expect(
        _toolResultOf(model.calls[1], 'call_1'),
        '{"text":"a","length":1}{"text":"bb","length":2}',
      );
    });

    test('an interrupt of the graph is the composite interrupt of the tool, '
        'with its checkpoint and arguments', () async {
      final gateLog = <String>[];
      final invokable = GraphTool.invokable<_In, _Out>(
        name: 'gated',
        description: 'd',
        params: _inParams,
        fromJson: _In.fromJson,
        graph: _gatedWordsGraph(gateLog),
      );
      Object? error;
      try {
        await invokable.invokableRun(ctx, '{"text":"go"}');
        // The interrupt under test.
        // ignore: avoid_catches_without_on_clauses
      } catch (e) {
        error = e;
      }
      _expectGraphToolInterrupt(error, '{"text":"go"}', 'confirm go?');

      final streamable = GraphTool.streamable<_In, _Out>(
        name: 'gated',
        description: 'd',
        params: _inParams,
        fromJson: _In.fromJson,
        graph: _gatedWordsGraph(gateLog),
      );
      final reader = await streamable.streamableRun(ctx, '{"text":"go"}');
      error = null;
      try {
        await reader.recv();
        // The interrupt under test.
        // ignore: avoid_catches_without_on_clauses
      } catch (e) {
        error = e;
      }
      _expectGraphToolInterrupt(error, '{"text":"go"}', 'confirm go?');
      expect(gateLog, ['interrupt go', 'interrupt go']);
    });

    for (final streaming in [false, true]) {
      test('the streamable tool interrupts the agent and resumes its graph '
          '(streaming: $streaming)', () async {
        final gateLog = <String>[];
        final tool = GraphTool.streamable<_In, _Out>(
          name: 'gated',
          description: 'd',
          params: _inParams,
          fromJson: _In.fromJson,
          graph: _gatedWordsGraph(gateLog),
          toJson: (output) => output.toJson(),
        );
        final model = _callingModel('gated', '{"text":"go"}', 'finished');
        final store = InMemoryCheckpointStore();
        final runner = Runner(
          agent: ChatModelAgent(ChatModelAgentConfig(
            name: 'A',
            description: 'd',
            model: model,
            toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [tool])),
          )),
          enableStreaming: streaming,
          checkpointStore: store,
        );
        final (_, interrupted) = await _runUntilInterrupt(runner.query(
          ctx,
          'go',
          options: [AgentRunOption.checkpointId('s')],
        ));
        final point = interrupted.interruptContexts.single;
        expect(point.info, 'confirm go?');
        expect(point.isRootCause, isTrue);
        expect(point.address.toString(), 'agent:A;tool:gated:call_1');
        expect(point.parent?.info, 'graph tool interrupt');
        expect(point.parent?.isRootCause, isFalse);
        expect(store.keys, ['s']);
        expect(gateLog, ['interrupt go']);

        final events =
            await _collectOk(await _resume(runner, 's', point.id, 'yes'));
        expect(gateLog, ['interrupt go', 'resumed go with yes']);
        const chunks = ['{"text":"go","length":2}', '{"text":"yes","length":3}'];
        expect(_toolResultOf(model.calls[1], 'call_1'), chunks.join());
        // A streamable tool's event is a stream also when the agent does not
        // stream (Go: the event sender wraps the streamable endpoint, and the
        // tools node derives the invokable one from it).
        final variant = events[0].output!.messageOutput!;
        expect(variant.toolName, 'gated');
        expect(variant.isStreaming, isTrue);
        expect(
          (await variant.messageStream!.collectAll()).map((m) => m.content),
          chunks,
        );
        expect((await getMessageFromEvent(events.last))!.content, 'finished');
      });
    }
  });
}
