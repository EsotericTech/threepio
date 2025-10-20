/// Langfuse usage and cost tracking models
///
/// **Framework Source: Eino (CloudWeGo)** - Usage tracking structure
/// **Framework Source: Langfuse** - Token usage API specification
/// **Framework Source: LangChain** - Cost calculation patterns
///
/// Tracks token usage and calculates costs for LLM API calls.

/// Token usage for LLM generations
///
/// Example:
/// ```dart
/// final usage = LangfuseUsage(
///   promptTokens: 100,
///   completionTokens: 50,
///   totalTokens: 150,
/// );
///
/// // Calculate cost based on provider pricing
/// final cost = usage.calculateCost(
///   inputCostPer1kTokens: 0.03,
///   outputCostPer1kTokens: 0.06,
/// );
/// ```
class LangfuseUsage {
  /// Number of tokens in the prompt/input
  final int? promptTokens;

  /// Number of tokens in the completion/output
  final int? completionTokens;

  /// Total tokens (prompt + completion)
  final int? totalTokens;

  const LangfuseUsage({
    this.promptTokens,
    this.completionTokens,
    this.totalTokens,
  });

  /// Calculate cost based on provider pricing
  ///
  /// Parameters:
  /// - inputCostPer1kTokens: Cost per 1000 input tokens
  /// - outputCostPer1kTokens: Cost per 1000 output tokens
  ///
  /// Returns: Total cost in dollars
  double calculateCost({
    required double inputCostPer1kTokens,
    required double outputCostPer1kTokens,
  }) {
    final inputCost = (promptTokens ?? 0) / 1000 * inputCostPer1kTokens;
    final outputCost = (completionTokens ?? 0) / 1000 * outputCostPer1kTokens;
    return inputCost + outputCost;
  }

  Map<String, dynamic> toJson() {
    return {
      if (promptTokens != null) 'promptTokens': promptTokens,
      if (completionTokens != null) 'completionTokens': completionTokens,
      if (totalTokens != null) 'totalTokens': totalTokens,
    };
  }

  factory LangfuseUsage.fromJson(Map<String, dynamic> json) {
    return LangfuseUsage(
      promptTokens: json['promptTokens'] as int?,
      completionTokens: json['completionTokens'] as int?,
      totalTokens: json['totalTokens'] as int?,
    );
  }

  LangfuseUsage copyWith({
    int? promptTokens,
    int? completionTokens,
    int? totalTokens,
  }) {
    return LangfuseUsage(
      promptTokens: promptTokens ?? this.promptTokens,
      completionTokens: completionTokens ?? this.completionTokens,
      totalTokens: totalTokens ?? this.totalTokens,
    );
  }

  @override
  String toString() {
    return 'LangfuseUsage(promptTokens: $promptTokens, '
        'completionTokens: $completionTokens, totalTokens: $totalTokens)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is LangfuseUsage &&
        other.promptTokens == promptTokens &&
        other.completionTokens == completionTokens &&
        other.totalTokens == totalTokens;
  }

  @override
  int get hashCode =>
      promptTokens.hashCode ^ completionTokens.hashCode ^ totalTokens.hashCode;
}
