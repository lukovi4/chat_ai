// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'message.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_Message _$MessageFromJson(Map<String, dynamic> json) => _Message(
  id: json['id'] as String,
  role: $enumDecode(_$MessageRoleEnumMap, json['role']),
  parts: (json['parts'] as List<dynamic>)
      .map((e) => ContentPart.fromJson(e as Map<String, dynamic>))
      .toList(),
  status: $enumDecode(_$MessageStatusEnumMap, json['status']),
  attemptKey: json['attemptKey'] as String?,
  createdAt: const UtcDateTimeConverter().fromJson(json['createdAt'] as String),
);

Map<String, dynamic> _$MessageToJson(_Message instance) => <String, dynamic>{
  'id': instance.id,
  'role': _$MessageRoleEnumMap[instance.role]!,
  'parts': instance.parts.map((e) => e.toJson()).toList(),
  'status': _$MessageStatusEnumMap[instance.status]!,
  'attemptKey': ?instance.attemptKey,
  'createdAt': const UtcDateTimeConverter().toJson(instance.createdAt),
};

const _$MessageRoleEnumMap = {
  MessageRole.user: 'user',
  MessageRole.assistant: 'assistant',
  MessageRole.system: 'system',
};

const _$MessageStatusEnumMap = {
  MessageStatus.sending: 'sending',
  MessageStatus.sent: 'sent',
  MessageStatus.failed: 'failed',
  MessageStatus.streaming: 'streaming',
  MessageStatus.complete: 'complete',
  MessageStatus.interrupted: 'interrupted',
};
