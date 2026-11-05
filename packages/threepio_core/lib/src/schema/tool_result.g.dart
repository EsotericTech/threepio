// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'tool_result.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_ToolOutputImage _$ToolOutputImageFromJson(Map<String, dynamic> json) =>
    _ToolOutputImage(
      common: MessagePartCommon.fromJson(
        json['common'] as Map<String, dynamic>,
      ),
    );

Map<String, dynamic> _$ToolOutputImageToJson(_ToolOutputImage instance) =>
    <String, dynamic>{'common': instance.common.toJson()};

_ToolOutputAudio _$ToolOutputAudioFromJson(Map<String, dynamic> json) =>
    _ToolOutputAudio(
      common: MessagePartCommon.fromJson(
        json['common'] as Map<String, dynamic>,
      ),
    );

Map<String, dynamic> _$ToolOutputAudioToJson(_ToolOutputAudio instance) =>
    <String, dynamic>{'common': instance.common.toJson()};

_ToolOutputVideo _$ToolOutputVideoFromJson(Map<String, dynamic> json) =>
    _ToolOutputVideo(
      common: MessagePartCommon.fromJson(
        json['common'] as Map<String, dynamic>,
      ),
    );

Map<String, dynamic> _$ToolOutputVideoToJson(_ToolOutputVideo instance) =>
    <String, dynamic>{'common': instance.common.toJson()};

_ToolOutputFile _$ToolOutputFileFromJson(Map<String, dynamic> json) =>
    _ToolOutputFile(
      common: MessagePartCommon.fromJson(
        json['common'] as Map<String, dynamic>,
      ),
    );

Map<String, dynamic> _$ToolOutputFileToJson(_ToolOutputFile instance) =>
    <String, dynamic>{'common': instance.common.toJson()};

_ToolOutputPart _$ToolOutputPartFromJson(Map<String, dynamic> json) =>
    _ToolOutputPart(
      type: $enumDecode(_$ToolPartTypeEnumMap, json['type']),
      text: json['text'] as String?,
      image: json['image'] == null
          ? null
          : ToolOutputImage.fromJson(json['image'] as Map<String, dynamic>),
      audio: json['audio'] == null
          ? null
          : ToolOutputAudio.fromJson(json['audio'] as Map<String, dynamic>),
      video: json['video'] == null
          ? null
          : ToolOutputVideo.fromJson(json['video'] as Map<String, dynamic>),
      file: json['file'] == null
          ? null
          : ToolOutputFile.fromJson(json['file'] as Map<String, dynamic>),
      toolSearchResult: json['toolSearchResult'] == null
          ? null
          : ToolSearchResult.fromJson(
              json['toolSearchResult'] as Map<String, dynamic>,
            ),
      extra: json['extra'] as Map<String, dynamic>?,
    );

Map<String, dynamic> _$ToolOutputPartToJson(_ToolOutputPart instance) =>
    <String, dynamic>{
      'type': _$ToolPartTypeEnumMap[instance.type]!,
      'text': instance.text,
      'image': instance.image?.toJson(),
      'audio': instance.audio?.toJson(),
      'video': instance.video?.toJson(),
      'file': instance.file?.toJson(),
      'toolSearchResult': instance.toolSearchResult?.toJson(),
      'extra': instance.extra,
    };

const _$ToolPartTypeEnumMap = {
  ToolPartType.text: 'text',
  ToolPartType.image: 'image',
  ToolPartType.audio: 'audio',
  ToolPartType.video: 'video',
  ToolPartType.file: 'file',
  ToolPartType.toolSearchResult: 'tool_search_result',
};

_ToolArgument _$ToolArgumentFromJson(Map<String, dynamic> json) =>
    _ToolArgument(json['text'] as String);

Map<String, dynamic> _$ToolArgumentToJson(_ToolArgument instance) =>
    <String, dynamic>{'text': instance.text};

_ToolResult _$ToolResultFromJson(Map<String, dynamic> json) => _ToolResult(
  (json['parts'] as List<dynamic>?)
          ?.map((e) => ToolOutputPart.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const <ToolOutputPart>[],
);

Map<String, dynamic> _$ToolResultToJson(_ToolResult instance) =>
    <String, dynamic>{'parts': instance.parts.map((e) => e.toJson()).toList()};
