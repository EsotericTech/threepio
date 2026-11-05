// The flows of the eino example `compose/batch` (main.go), with a
// deterministic review function in place of the random one, and unit tests
// of `BatchNode`.
import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/callbacks.dart';
import 'package:threepio_core/compose.dart';

final class ReviewRequest {
  const ReviewRequest(this.documentId, this.content, this.priority);

  factory ReviewRequest.fromJson(Map<String, Object?> json) => ReviewRequest(
        json['document_id']! as String,
        json['content']! as String,
        json['priority']! as String,
      );

  final String documentId;
  final String content;
  final String priority;

  Map<String, Object?> toJson() =>
      {'document_id': documentId, 'content': content, 'priority': priority};
}

final class ReviewResult {
  const ReviewResult(this.documentId, this.comments, {required this.approved, required this.score});

  factory ReviewResult.fromJson(Map<String, Object?> json) => ReviewResult(
        json['document_id']! as String,
        json['comments']! as String,
        approved: json['approved']! as bool,
        score: (json['score']! as num).toDouble(),
      );

  final String documentId;
  final bool approved;
  final double score;
  final String comments;

  Map<String, Object?> toJson() => {
        'document_id': documentId,
        'approved': approved,
        'score': score,
        'comments': comments,
      };

  @override
  String toString() => '$documentId:$approved:$comments';
}

final class ApprovalDecision {
  const ApprovalDecision(this.comments, {required this.approved});
  final bool approved;
  final String comments;
}

final class BatchReviewInput {
  const BatchReviewInput(this.documents, this.batchName);
  final List<ReviewRequest> documents;
  final String batchName;
}

final class ReviewReport {
  const ReviewReport(this.results, this.approvedCount, this.averageScore);
  final List<ReviewResult> results;
  final int approvedCount;
  final double averageScore;
}

List<ReviewRequest> sampleDocuments(int count) {
  const priorities = ['high', 'medium', 'low'];
  return [
    for (var i = 0; i < count; i++)
      ReviewRequest(
        'DOC-${'${i + 1}'.padLeft(3, '0')}',
        'Document content for review #${i + 1}.',
        priorities[i % priorities.length],
      ),
  ];
}

/// The workflow of the example: one node that reviews a document.
Workflow<ReviewRequest, ReviewResult> simpleReviewWorkflow({
  void Function(ReviewRequest request)? onReview,
  Future<void> Function(ReviewRequest request)? wait,
}) {
  final workflow = Workflow<ReviewRequest, ReviewResult>();
  workflow
      .addLambdaNode(
        'analyze',
        Lambda.invokable((ctx, ReviewRequest request) async {
          onReview?.call(request);
          await wait?.call(request);
          // The example draws the score at random.
          final score = request.priority == 'low' ? 0.6 : 0.9;
          return ReviewResult(
            request.documentId,
            'Auto-reviewed document ${request.documentId} with priority '
            '${request.priority}',
            approved: score >= 0.7,
            score: score,
          );
        }),
      )
      .addInput(Graph.start);
  workflow.end().addInput('analyze');
  return workflow;
}

void main() {
  setUpAll(() {
    TypeRegistry.registerName<ReviewRequest>(
      'batch_example.ReviewRequest',
      fromJson: ReviewRequest.fromJson,
      toJson: (value) => value.toJson(),
    );
    TypeRegistry.registerName<ReviewResult>(
      'batch_example.ReviewResult',
      fromJson: ReviewResult.fromJson,
      toJson: (value) => value.toJson(),
    );
  });

  final ctx = RunContext.background();

  group('eino example compose/batch', () {
    test('scenario 1: basic sequential processing', () async {
      final order = <String>[];
      final node = BatchNode<ReviewRequest, ReviewResult>(
        name: 'SequentialReviewer',
        innerTask: simpleReviewWorkflow(onReview: (r) => order.add(r.documentId)),
      );
      final results = await node.invoke(ctx, sampleDocuments(3));
      expect(
        [for (final r in results) r.documentId],
        ['DOC-001', 'DOC-002', 'DOC-003'],
      );
      expect([for (final r in results) r.approved], [true, true, false]);
      expect(order, ['DOC-001', 'DOC-002', 'DOC-003']);
    });

    test('scenario 2: concurrent processing, at most three at a time',
        () async {
      var running = 0;
      var most = 0;
      final gates = <String, Completer<void>>{};
      final node = BatchNode<ReviewRequest, ReviewResult>(
        name: 'ConcurrentReviewer',
        maxConcurrency: 3,
        innerTask: simpleReviewWorkflow(
          wait: (request) async {
            running++;
            if (running > most) most = running;
            await (gates[request.documentId] = Completer<void>()).future;
            running--;
          },
        ),
      );
      final run = node.invoke(ctx, sampleDocuments(5));
      // Let the first three start, then finish the items one by one; the
      // others start as places come free.
      for (var released = 0; released < 5;) {
        await Future<void>.delayed(Duration.zero);
        final open = [
          for (final gate in gates.values)
            if (!gate.isCompleted) gate,
        ];
        if (open.isEmpty) continue;
        expect(running, lessThanOrEqualTo(3));
        open.first.complete();
        released++;
      }
      final results = await run;
      expect(most, 3);
      expect(
        [for (final r in results) r.documentId],
        ['DOC-001', 'DOC-002', 'DOC-003', 'DOC-004', 'DOC-005'],
      );
    });

    test('scenario 3: with compile options, the inner workflow has a name',
        () async {
      final addresses = <String>[];
      final workflow = Workflow<ReviewRequest, ReviewResult>();
      workflow
          .addLambdaNode(
            'analyze',
            Lambda.invokable((ctx, ReviewRequest request) {
              addresses.add(ctx.currentAddress.toString());
              return ReviewResult(request.documentId, '', approved: true, score: 1);
            }),
          )
          .addInput(Graph.start);
      workflow.end().addInput('analyze');
      final node = BatchNode<ReviewRequest, ReviewResult>(
        name: 'NamedReviewer',
        maxConcurrency: 2,
        innerTask: workflow,
        innerCompileOptions:
            const GraphCompileOptions(graphName: 'SingleDocumentReviewWorkflow'),
      );
      final results = await node.invoke(ctx, sampleDocuments(3));
      expect(results, hasLength(3));
      expect(addresses, [
        for (var i = 0; i < 3; i++)
          'batch_process:$i;runnable:SingleDocumentReviewWorkflow;node:analyze',
      ]);
    });

    test('scenario 4: callbacks hear the batch and every inner workflow',
        () async {
      final events = <String>[];
      final handler = CallbackHandlerBuilder()
          .onStart((ctx, info, input) {
            events.add('start ${info.componentType.einoName}/${info.type}');
            return ctx;
          })
          .onEnd((ctx, info, output) {
            events.add('end ${info.componentType.einoName}/${info.type}');
            return ctx;
          })
          .build();
      final node = BatchNode<ReviewRequest, ReviewResult>(
        name: 'CallbackReviewer',
        innerTask: simpleReviewWorkflow(),
      );
      final results = await node.invoke(
        ctx.withHandlers([handler]),
        sampleDocuments(2),
      );
      expect(results, hasLength(2));
      expect(events.first, 'start Unknown/CallbackReviewer');
      expect(events.last, 'end Unknown/CallbackReviewer');
      expect(events.where((e) => e == 'start Workflow/'), hasLength(2));
      expect(events.where((e) => e == 'end Workflow/'), hasLength(2));
    });

    test('scenario 5: the first failure of an item fails the batch', () async {
      final reviewed = <String>[];
      final workflow = Workflow<ReviewRequest, ReviewResult>();
      workflow
          .addLambdaNode(
            'analyze',
            Lambda.invokable((ctx, ReviewRequest request) {
              reviewed.add(request.documentId);
              if (request.documentId == 'DOC-002') {
                throw StateError(
                  'validation failed for document ${request.documentId}: '
                  'content too short',
                );
              }
              return ReviewResult(
                request.documentId,
                'Passed validation',
                approved: true,
                score: 0.9,
              );
            }),
          )
          .addInput(Graph.start);
      workflow.end().addInput('analyze');
      final node = BatchNode<ReviewRequest, ReviewResult>(
        name: 'ErrorHandlingReviewer',
        innerTask: workflow,
      );
      await expectLater(
        node.invoke(ctx, sampleDocuments(3)),
        throwsA(
          isA<BatchItemException>()
              .having((e) => e.index, 'index', 1)
              .having(
                (e) => e.message,
                'message',
                allOf(
                  startsWith('task 1 failed: '),
                  contains('validation failed for document DOC-002'),
                ),
              ),
        ),
      );
      // As in the example, the other items still run.
      expect(reviewed, ['DOC-001', 'DOC-002', 'DOC-003']);
    });

    test('scenario 6: interrupt and resume', () async {
      final analyzed = <String>[];
      final inner = Workflow<ReviewRequest, ReviewResult>();
      inner
          .addLambdaNode(
            'analyze',
            Lambda.invokable((ctx, ReviewRequest request) {
              analyzed.add(request.documentId);
              if (request.priority == 'high') {
                if (!getInterruptState<Object>(ctx).wasInterrupted) {
                  throw interrupt(ctx, {
                    'document_id': request.documentId,
                    'reason': 'High priority document requires human approval',
                  });
                }
                final resumed = getResumeContext<ApprovalDecision>(ctx);
                final decision = resumed.data;
                if (resumed.isResumeTarget && decision != null) {
                  return ReviewResult(
                    request.documentId,
                    'Human review: ${decision.comments}',
                    approved: decision.approved,
                    score: 1,
                  );
                }
                throw interrupt(ctx, {
                  'document_id': request.documentId,
                  'reason': 'Still waiting for human approval',
                });
              }
              return ReviewResult(
                request.documentId,
                'Auto-approved (non-high priority)',
                approved: true,
                score: 0.85,
              );
            }),
          )
          .addInput(Graph.start);
      inner.end().addInput('analyze');

      final batch = BatchNode<ReviewRequest, ReviewResult>(
        name: 'InterruptReviewer',
        innerTask: inner,
      );
      final parent = Graph<List<ReviewRequest>, List<ReviewResult>>()
        ..addLambdaNode('batch_review', batch.toLambda())
        ..addEdge(Graph.start, 'batch_review')
        ..addEdge('batch_review', Graph.end);
      final runner = await parent.compile(
        ctx,
        options: GraphCompileOptions(
          graphName: 'InterruptResumeDemo',
          checkpointStore: InMemoryCheckpointStore(),
        ),
      );

      const docs = [
        ReviewRequest('DOC-001', 'Content 1', 'high'),
        ReviewRequest('DOC-002', 'Content 2', 'medium'),
        ReviewRequest('DOC-003', 'Content 3', 'high'),
        ReviewRequest('DOC-004', 'Content 4', 'low'),
      ];
      const checkpointId = 'interrupt-resume-demo-001';

      GraphInterruptInfo? info;
      try {
        await runner.invoke(
          ctx,
          docs,
          options: [CallOption.checkpointId(checkpointId)],
        );
        fail('expected an interrupt');
      } on GraphInterruptedException catch (interrupted) {
        info = interrupted.info;
      }
      expect(analyzed, ['DOC-001', 'DOC-002', 'DOC-003', 'DOC-004']);
      expect(info.rerunNodes, ['batch_review']);
      expect(info.interruptContexts, hasLength(2));
      expect(
        [for (final point in info.interruptContexts) '${point.address}'],
        [
          'runnable:InterruptResumeDemo;node:batch_review;batch_process:0;'
              'runnable:;node:analyze',
          'runnable:InterruptResumeDemo;node:batch_review;batch_process:2;'
              'runnable:;node:analyze',
        ],
      );

      // Only the first document is approved: the other one interrupts again.
      analyzed.clear();
      final first = info.interruptContexts.first;
      expect((first.info! as Map)['document_id'], 'DOC-001');
      GraphInterruptInfo? second;
      try {
        await runner.invoke(
          ctx.resumeWithData(
            first.id,
            const ApprovalDecision('Approved by supervisor', approved: true),
          ),
          const <ReviewRequest>[],
          options: [CallOption.checkpointId(checkpointId)],
        );
        fail('expected a second interrupt');
      } on GraphInterruptedException catch (interrupted) {
        second = interrupted.info;
      }
      // Only the documents that had interrupted ran again.
      expect(analyzed, ['DOC-001', 'DOC-003']);
      expect(second.interruptContexts, hasLength(1));
      final waiting = second.interruptContexts.single;
      expect((waiting.info! as Map)['document_id'], 'DOC-003');
      expect((waiting.info! as Map)['reason'], 'Still waiting for human approval');

      analyzed.clear();
      final results = await runner.invoke(
        ctx.batchResumeWithData({
          waiting.id: const ApprovalDecision('Rejected', approved: false),
        }),
        const <ReviewRequest>[],
        options: [CallOption.checkpointId(checkpointId)],
      );
      expect(analyzed, ['DOC-003']);
      expect([for (final r in results) '$r'], [
        'DOC-001:true:Human review: Approved by supervisor',
        'DOC-002:true:Auto-approved (non-high priority)',
        'DOC-003:false:Human review: Rejected',
        'DOC-004:true:Auto-approved (non-high priority)',
      ]);
    });

    test('scenario 7: a parent graph with a reduce node', () async {
      var completed = 0;
      final batch = BatchNode<ReviewRequest, ReviewResult>(
        name: 'BatchDocumentReviewer',
        maxConcurrency: 3,
        innerTask: simpleReviewWorkflow(),
        innerCompileOptions: const GraphCompileOptions(graphName: 'SingleDocReview'),
      );
      final progress = CallbackHandlerBuilder().onEnd((ctx, info, output) {
        if (info.componentType == ComponentType.workflow) completed++;
        return ctx;
      }).build();

      final parent = Graph<BatchReviewInput, ReviewReport>()
        ..addLambdaNode(
          'preprocess',
          Lambda.invokable((ctx, BatchReviewInput input) => input.documents),
        )
        ..addLambdaNode(
          'batch_review',
          batch.toLambda(innerOptions: [CallOption.callbacks([progress])]),
        )
        ..addLambdaNode(
          'reduce',
          Lambda.invokable((ctx, List<ReviewResult> results) {
            final total = results.fold<double>(0, (sum, r) => sum + r.score);
            return ReviewReport(
              results,
              results.where((r) => r.approved).length,
              results.isEmpty ? 0 : total / results.length,
            );
          }),
        )
        ..addEdge(Graph.start, 'preprocess')
        ..addEdge('preprocess', 'batch_review')
        ..addEdge('batch_review', 'reduce')
        ..addEdge('reduce', Graph.end);
      final runner = await parent.compile(
        ctx,
        options: const GraphCompileOptions(graphName: 'DocumentReviewPipeline'),
      );

      final report = await runner.invoke(
        ctx,
        BatchReviewInput(sampleDocuments(5), 'Q4-Compliance-Review'),
      );
      expect(report.results, hasLength(5));
      expect(report.approvedCount, 4);
      expect(report.averageScore, closeTo((0.9 * 4 + 0.6) / 5, 1e-9));
      expect(completed, 5);
    });
  });

  group('BatchNode', () {
    test('an empty batch gives an empty list', () async {
      final node = BatchNode<ReviewRequest, ReviewResult>(
        innerTask: simpleReviewWorkflow(),
      );
      expect(await node.invoke(ctx, const []), isEmpty);
    });

    test('reports itself: name, callbacks of its own', () {
      final node = BatchNode<ReviewRequest, ReviewResult>(
        name: 'Mine',
        innerTask: simpleReviewWorkflow(),
      );
      expect(node.componentTypeName, 'Mine');
      expect(node.isCallbacksEnabled, isTrue);
      expect(
        BatchNode<ReviewRequest, ReviewResult>(innerTask: simpleReviewWorkflow())
            .name,
        'Node',
      );
      expect(BatchNode.segmentType, const AddressSegmentType('batch_process'));
    });

    test('refuses an inner task of other types', () {
      expect(
        () => BatchNode<String, ReviewResult>(innerTask: simpleReviewWorkflow()),
        throwsArgumentError,
      );
      expect(
        () => BatchNode<ReviewRequest, String>(innerTask: simpleReviewWorkflow()),
        throwsArgumentError,
      );
      expect(
        () => BatchNode<ReviewRequest, ReviewResult>(
          innerTask: simpleReviewWorkflow(),
          maxConcurrency: -1,
        ),
        throwsArgumentError,
      );
    });

    test('the error callback hears a failed batch', () async {
      final errors = <Object>[];
      final handler = CallbackHandlerBuilder().onError((ctx, info, error, stackTrace) {
        if (info.type == 'Failing') errors.add(error);
        return ctx;
      }).build();
      final workflow = Workflow<ReviewRequest, ReviewResult>();
      workflow
          .addLambdaNode(
            'analyze',
            Lambda<ReviewRequest, ReviewResult>.invokable(
              (ctx, request) => throw const FormatException('bad'),
            ),
          )
          .addInput(Graph.start);
      workflow.end().addInput('analyze');
      final node = BatchNode<ReviewRequest, ReviewResult>(
        name: 'Failing',
        innerTask: workflow,
        maxConcurrency: 2,
      );
      await expectLater(
        node.invoke(ctx.withHandlers([handler]), sampleDocuments(2)),
        throwsA(isA<BatchItemException>()),
      );
      expect(errors.single, isA<BatchItemException>());
    });
  });
}
