// Mirror of a ```dart block of doc/NEW_FEATURES.md (see
// test/unit/docs/doc_snippets_test.dart): the block is copied verbatim; the
// lines around it declare what it uses.
// Section 3, "Defining the State"; the other checkpoint mirrors import it.

import 'package:threepio_core/threepio_core.dart';

class WorkflowState extends GraphState {
  WorkflowState({
    this.document,
    this.analysis,
    this.review,
    this.approved = false,
  });

  factory WorkflowState.fromMap(Map<String, dynamic> map) => WorkflowState(
        document: map['document'] as String?,
        analysis: map['analysis'] as String?,
        review: map['review'] as String?,
        approved: map['approved'] as bool? ?? false,
      );

  final String? document;
  final String? analysis;
  final String? review;
  final bool approved;

  @override
  WorkflowState copyWith({
    String? document,
    String? analysis,
    String? review,
    bool? approved,
  }) =>
      WorkflowState(
        document: document ?? this.document,
        analysis: analysis ?? this.analysis,
        review: review ?? this.review,
        approved: approved ?? this.approved,
      );

  Map<String, dynamic> toMap() => {
        'document': document,
        'analysis': analysis,
        'review': review,
        'approved': approved,
      };
}
