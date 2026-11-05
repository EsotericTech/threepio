// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'message.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_FunctionCall _$FunctionCallFromJson(Map<String, dynamic> json) =>
    _FunctionCall(
      name: json['name'] as String,
      arguments: json['arguments'] as String,
    );

Map<String, dynamic> _$FunctionCallToJson(_FunctionCall instance) =>
    <String, dynamic>{'name': instance.name, 'arguments': instance.arguments};

_ToolCall _$ToolCallFromJson(Map<String, dynamic> json) => _ToolCall(
  index: (json['index'] as num?)?.toInt(),
  id: json['id'] as String,
  type: json['type'] as String? ?? 'function',
  function: FunctionCall.fromJson(json['function'] as Map<String, dynamic>),
  extra: json['extra'] as Map<String, dynamic>?,
);

Map<String, dynamic> _$ToolCallToJson(_ToolCall instance) => <String, dynamic>{
  'index': instance.index,
  'id': instance.id,
  'type': instance.type,
  'function': instance.function.toJson(),
  'extra': instance.extra,
};

_MessagePartCommon _$MessagePartCommonFromJson(Map<String, dynamic> json) =>
    _MessagePartCommon(
      url: json['url'] as String?,
      base64Data: json['base64Data'] as String?,
      fileId: json['fileId'] as String?,
      mimeType: json['mimeType'] as String?,
      extra: json['extra'] as Map<String, dynamic>?,
    );

Map<String, dynamic> _$MessagePartCommonToJson(_MessagePartCommon instance) =>
    <String, dynamic>{
      'url': instance.url,
      'base64Data': instance.base64Data,
      'fileId': instance.fileId,
      'mimeType': instance.mimeType,
      'extra': instance.extra,
    };

_MessageInputImage _$MessageInputImageFromJson(Map<String, dynamic> json) =>
    _MessageInputImage(
      common: MessagePartCommon.fromJson(
        json['common'] as Map<String, dynamic>,
      ),
      detail: $enumDecodeNullable(_$ImageURLDetailEnumMap, json['detail']),
    );

Map<String, dynamic> _$MessageInputImageToJson(_MessageInputImage instance) =>
    <String, dynamic>{
      'common': instance.common.toJson(),
      'detail': _$ImageURLDetailEnumMap[instance.detail],
    };

const _$ImageURLDetailEnumMap = {
  ImageURLDetail.high: 'high',
  ImageURLDetail.low: 'low',
  ImageURLDetail.auto: 'auto',
};

_MessageInputAudio _$MessageInputAudioFromJson(Map<String, dynamic> json) =>
    _MessageInputAudio(
      common: MessagePartCommon.fromJson(
        json['common'] as Map<String, dynamic>,
      ),
    );

Map<String, dynamic> _$MessageInputAudioToJson(_MessageInputAudio instance) =>
    <String, dynamic>{'common': instance.common.toJson()};

_MessageInputVideo _$MessageInputVideoFromJson(Map<String, dynamic> json) =>
    _MessageInputVideo(
      common: MessagePartCommon.fromJson(
        json['common'] as Map<String, dynamic>,
      ),
    );

Map<String, dynamic> _$MessageInputVideoToJson(_MessageInputVideo instance) =>
    <String, dynamic>{'common': instance.common.toJson()};

_MessageInputFile _$MessageInputFileFromJson(Map<String, dynamic> json) =>
    _MessageInputFile(
      common: MessagePartCommon.fromJson(
        json['common'] as Map<String, dynamic>,
      ),
      name: json['name'] as String?,
    );

Map<String, dynamic> _$MessageInputFileToJson(_MessageInputFile instance) =>
    <String, dynamic>{
      'common': instance.common.toJson(),
      'name': instance.name,
    };

_MessageInputPart _$MessageInputPartFromJson(Map<String, dynamic> json) =>
    _MessageInputPart(
      type: $enumDecode(_$ChatMessagePartTypeEnumMap, json['type']),
      text: json['text'] as String?,
      image: json['image'] == null
          ? null
          : MessageInputImage.fromJson(json['image'] as Map<String, dynamic>),
      audio: json['audio'] == null
          ? null
          : MessageInputAudio.fromJson(json['audio'] as Map<String, dynamic>),
      video: json['video'] == null
          ? null
          : MessageInputVideo.fromJson(json['video'] as Map<String, dynamic>),
      file: json['file'] == null
          ? null
          : MessageInputFile.fromJson(json['file'] as Map<String, dynamic>),
      toolSearchResult: json['toolSearchResult'] == null
          ? null
          : ToolSearchResult.fromJson(
              json['toolSearchResult'] as Map<String, dynamic>,
            ),
      extra: json['extra'] as Map<String, dynamic>?,
    );

Map<String, dynamic> _$MessageInputPartToJson(_MessageInputPart instance) =>
    <String, dynamic>{
      'type': _$ChatMessagePartTypeEnumMap[instance.type]!,
      'text': instance.text,
      'image': instance.image?.toJson(),
      'audio': instance.audio?.toJson(),
      'video': instance.video?.toJson(),
      'file': instance.file?.toJson(),
      'toolSearchResult': instance.toolSearchResult?.toJson(),
      'extra': instance.extra,
    };

const _$ChatMessagePartTypeEnumMap = {
  ChatMessagePartType.text: 'text',
  ChatMessagePartType.imageUrl: 'image_url',
  ChatMessagePartType.audioUrl: 'audio_url',
  ChatMessagePartType.videoUrl: 'video_url',
  ChatMessagePartType.fileUrl: 'file_url',
  ChatMessagePartType.reasoning: 'reasoning',
  ChatMessagePartType.toolSearchResult: 'tool_search_result',
};

_MessageOutputReasoning _$MessageOutputReasoningFromJson(
  Map<String, dynamic> json,
) => _MessageOutputReasoning(
  text: json['text'] as String? ?? '',
  signature: json['signature'] as String? ?? '',
);

Map<String, dynamic> _$MessageOutputReasoningToJson(
  _MessageOutputReasoning instance,
) => <String, dynamic>{'text': instance.text, 'signature': instance.signature};

_MessageStreamingMeta _$MessageStreamingMetaFromJson(
  Map<String, dynamic> json,
) => _MessageStreamingMeta(index: (json['index'] as num?)?.toInt() ?? 0);

Map<String, dynamic> _$MessageStreamingMetaToJson(
  _MessageStreamingMeta instance,
) => <String, dynamic>{'index': instance.index};

_MessageOutputPart _$MessageOutputPartFromJson(Map<String, dynamic> json) =>
    _MessageOutputPart(
      type: $enumDecode(_$ChatMessagePartTypeEnumMap, json['type']),
      text: json['text'] as String?,
      image: json['image'] == null
          ? null
          : MessagePartCommon.fromJson(json['image'] as Map<String, dynamic>),
      audio: json['audio'] == null
          ? null
          : MessagePartCommon.fromJson(json['audio'] as Map<String, dynamic>),
      video: json['video'] == null
          ? null
          : MessagePartCommon.fromJson(json['video'] as Map<String, dynamic>),
      reasoning: json['reasoning'] == null
          ? null
          : MessageOutputReasoning.fromJson(
              json['reasoning'] as Map<String, dynamic>,
            ),
      extra: json['extra'] as Map<String, dynamic>?,
    );

Map<String, dynamic> _$MessageOutputPartToJson(_MessageOutputPart instance) =>
    <String, dynamic>{
      'type': _$ChatMessagePartTypeEnumMap[instance.type]!,
      'text': instance.text,
      'image': instance.image?.toJson(),
      'audio': instance.audio?.toJson(),
      'video': instance.video?.toJson(),
      'reasoning': instance.reasoning?.toJson(),
      'extra': instance.extra,
    };

_TokenUsage _$TokenUsageFromJson(Map<String, dynamic> json) => _TokenUsage(
  promptTokens: (json['promptTokens'] as num).toInt(),
  completionTokens: (json['completionTokens'] as num).toInt(),
  totalTokens: (json['totalTokens'] as num).toInt(),
  promptTokenDetails: json['promptTokenDetails'] == null
      ? null
      : PromptTokenDetails.fromJson(
          json['promptTokenDetails'] as Map<String, dynamic>,
        ),
  completionTokenDetails: json['completionTokenDetails'] == null
      ? null
      : CompletionTokenDetails.fromJson(
          json['completionTokenDetails'] as Map<String, dynamic>,
        ),
  cost: (json['cost'] as num?)?.toDouble(),
);

Map<String, dynamic> _$TokenUsageToJson(_TokenUsage instance) =>
    <String, dynamic>{
      'promptTokens': instance.promptTokens,
      'completionTokens': instance.completionTokens,
      'totalTokens': instance.totalTokens,
      'promptTokenDetails': instance.promptTokenDetails?.toJson(),
      'completionTokenDetails': instance.completionTokenDetails?.toJson(),
      'cost': instance.cost,
    };

_CompletionTokenDetails _$CompletionTokenDetailsFromJson(
  Map<String, dynamic> json,
) => _CompletionTokenDetails(
  reasoningTokens: (json['reasoningTokens'] as num?)?.toInt() ?? 0,
  imageTokens: (json['imageTokens'] as num?)?.toInt() ?? 0,
  audioTokens: (json['audioTokens'] as num?)?.toInt() ?? 0,
);

Map<String, dynamic> _$CompletionTokenDetailsToJson(
  _CompletionTokenDetails instance,
) => <String, dynamic>{
  'reasoningTokens': instance.reasoningTokens,
  'imageTokens': instance.imageTokens,
  'audioTokens': instance.audioTokens,
};

_PromptTokenDetails _$PromptTokenDetailsFromJson(Map<String, dynamic> json) =>
    _PromptTokenDetails(
      cachedTokens: (json['cachedTokens'] as num?)?.toInt() ?? 0,
      cacheWriteTokens: (json['cacheWriteTokens'] as num?)?.toInt() ?? 0,
    );

Map<String, dynamic> _$PromptTokenDetailsToJson(_PromptTokenDetails instance) =>
    <String, dynamic>{
      'cachedTokens': instance.cachedTokens,
      'cacheWriteTokens': instance.cacheWriteTokens,
    };

_LogProb _$LogProbFromJson(Map<String, dynamic> json) => _LogProb(
  token: json['token'] as String,
  logProb: (json['logProb'] as num).toDouble(),
  bytes: (json['bytes'] as List<dynamic>?)
      ?.map((e) => (e as num).toInt())
      .toList(),
  topLogProbs:
      (json['topLogProbs'] as List<dynamic>?)
          ?.map((e) => TopLogProb.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const [],
);

Map<String, dynamic> _$LogProbToJson(_LogProb instance) => <String, dynamic>{
  'token': instance.token,
  'logProb': instance.logProb,
  'bytes': instance.bytes,
  'topLogProbs': instance.topLogProbs.map((e) => e.toJson()).toList(),
};

_TopLogProb _$TopLogProbFromJson(Map<String, dynamic> json) => _TopLogProb(
  token: json['token'] as String,
  logProb: (json['logProb'] as num).toDouble(),
  bytes: (json['bytes'] as List<dynamic>?)
      ?.map((e) => (e as num).toInt())
      .toList(),
);

Map<String, dynamic> _$TopLogProbToJson(_TopLogProb instance) =>
    <String, dynamic>{
      'token': instance.token,
      'logProb': instance.logProb,
      'bytes': instance.bytes,
    };

_LogProbs _$LogProbsFromJson(Map<String, dynamic> json) => _LogProbs(
  content:
      (json['content'] as List<dynamic>?)
          ?.map((e) => LogProb.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const [],
);

Map<String, dynamic> _$LogProbsToJson(_LogProbs instance) => <String, dynamic>{
  'content': instance.content.map((e) => e.toJson()).toList(),
};

_ResponseMeta _$ResponseMetaFromJson(Map<String, dynamic> json) =>
    _ResponseMeta(
      finishReason: json['finishReason'] as String?,
      usage: json['usage'] == null
          ? null
          : TokenUsage.fromJson(json['usage'] as Map<String, dynamic>),
      logProbs: json['logProbs'] == null
          ? null
          : LogProbs.fromJson(json['logProbs'] as Map<String, dynamic>),
    );

Map<String, dynamic> _$ResponseMetaToJson(_ResponseMeta instance) =>
    <String, dynamic>{
      'finishReason': instance.finishReason,
      'usage': instance.usage?.toJson(),
      'logProbs': instance.logProbs?.toJson(),
    };

_Message _$MessageFromJson(Map<String, dynamic> json) => _Message(
  role: $enumDecode(_$RoleTypeEnumMap, json['role']),
  content: json['content'] as String? ?? '',
  userInputMultiContent: (json['userInputMultiContent'] as List<dynamic>?)
      ?.map((e) => MessageInputPart.fromJson(e as Map<String, dynamic>))
      .toList(),
  assistantGenMultiContent: (json['assistantGenMultiContent'] as List<dynamic>?)
      ?.map((e) => MessageOutputPart.fromJson(e as Map<String, dynamic>))
      .toList(),
  name: json['name'] as String?,
  toolCalls: (json['toolCalls'] as List<dynamic>?)
      ?.map((e) => ToolCall.fromJson(e as Map<String, dynamic>))
      .toList(),
  toolCallId: json['toolCallId'] as String?,
  toolName: json['toolName'] as String?,
  responseMeta: json['responseMeta'] == null
      ? null
      : ResponseMeta.fromJson(json['responseMeta'] as Map<String, dynamic>),
  reasoningContent: json['reasoningContent'] as String?,
  extra: json['extra'] as Map<String, dynamic>?,
);

Map<String, dynamic> _$MessageToJson(_Message instance) => <String, dynamic>{
  'role': _$RoleTypeEnumMap[instance.role]!,
  'content': instance.content,
  'userInputMultiContent': instance.userInputMultiContent
      ?.map((e) => e.toJson())
      .toList(),
  'assistantGenMultiContent': instance.assistantGenMultiContent
      ?.map((e) => e.toJson())
      .toList(),
  'name': instance.name,
  'toolCalls': instance.toolCalls?.map((e) => e.toJson()).toList(),
  'toolCallId': instance.toolCallId,
  'toolName': instance.toolName,
  'responseMeta': instance.responseMeta?.toJson(),
  'reasoningContent': instance.reasoningContent,
  'extra': instance.extra,
};

const _$RoleTypeEnumMap = {
  RoleType.assistant: 'assistant',
  RoleType.user: 'user',
  RoleType.system: 'system',
  RoleType.tool: 'tool',
};
