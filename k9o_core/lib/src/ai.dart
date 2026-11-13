import 'client.dart';
import 'envelope.dart';

/// Result of [AiNamespace.embed].
class EmbedResult {
  /// One vector per input string, in input order.
  final List<List<double>> embeddings;
  final String model;
  final int dimensions;
  const EmbedResult(this.embeddings, this.model, this.dimensions);

  factory EmbedResult.fromJson(Map<String, dynamic> j) => EmbedResult(
    [
      for (final v in (j['embeddings'] as List))
        [for (final x in (v as List)) (x as num).toDouble()],
    ],
    j['model'] as String,
    (j['dimensions'] as num).toInt(),
  );
}

/// Token counts the model server reported for an inference call.
class InferenceUsage {
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;
  const InferenceUsage(
    this.promptTokens,
    this.completionTokens,
    this.totalTokens,
  );

  factory InferenceUsage.fromJson(Map<String, dynamic> j) => InferenceUsage(
    (j['promptTokens'] as num).toInt(),
    (j['completionTokens'] as num).toInt(),
    (j['totalTokens'] as num).toInt(),
  );
}

/// Result of [AiNamespace.generate].
class InferenceResult {
  final String modelId;

  /// The generated text.
  final String content;
  final String? finishReason;
  final InferenceUsage usage;
  final String? usageType;
  const InferenceResult(
    this.modelId,
    this.content,
    this.finishReason,
    this.usage,
    this.usageType,
  );

  factory InferenceResult.fromJson(Map<String, dynamic> j) => InferenceResult(
    j['modelId'] as String,
    j['content'] as String,
    j['finishReason'] as String?,
    InferenceUsage.fromJson(j['usage'] as Map<String, dynamic>),
    j['usageType'] as String?,
  );
}

/// `core.ai.*` — platform AI primitives.
class AiNamespace {
  final K9oCore _core;
  AiNamespace(this._core);

  /// POST /@<projectSlug>/ai/embeddings — embed one or more strings.
  ///
  /// [input] is a `String` (sent as a string) or a `List<String>`.
  /// [model] is omitted from the request when null (server default).
  /// Input is sent exactly as given; bounds are enforced by the server.
  ///
  /// The gateway refuses an end user's token: callable by a project member's
  /// or an extension's token only.
  ///
  /// Throws [KError] with `K9O_MISSING_PROJECT_CONTEXT` (before any request)
  /// if the client has no projectSlug.
  Future<Envelope<EmbedResult>> embed({String? model, required Object input}) {
    if (input is! String && input is! List<String>) {
      throw ArgumentError.value(
        input,
        'input',
        'must be String or List<String>',
      );
    }
    final body = <String, dynamic>{
      if (model != null) 'model': model,
      'input': input,
    };
    return _core.post('ai/embeddings', body, EmbedResult.fromJson);
  }

  /// POST /@<projectSlug>/ai/generate — run one inference call.
  ///
  /// [model] is optional: when null the org's default LLM is used, and the
  /// gateway answers 400 `K9O_INVALID_FIELD_VALUE` if the org has none.
  /// [maxTokens] (1 to 32000) and [temperature] (0 to 2) are sent flat in the
  /// body; every null field is omitted. Callable with a project author's or
  /// admin's token or an extension's token.
  /// [usageType] labels the call for usage accounting; omitted when null.
  /// Models served by an external provider answer 501 `K9O_NOT_IMPLEMENTED`
  /// until that provider is built. The prompt never appears in errors.
  ///
  /// Throws [KError] with `K9O_MISSING_PROJECT_CONTEXT` (before any request)
  /// if the client has no projectSlug.
  Future<Envelope<InferenceResult>> generate(
    String prompt, {
    String? model,
    int? maxTokens,
    double? temperature,
    String? usageType,
  }) {
    final body = <String, dynamic>{
      'prompt': prompt,
      if (model != null) 'model': model,
      if (maxTokens != null) 'maxTokens': maxTokens,
      if (temperature != null) 'temperature': temperature,
      if (usageType != null) 'usageType': usageType,
    };
    return _core.post('ai/generate', body, InferenceResult.fromJson);
  }
}
