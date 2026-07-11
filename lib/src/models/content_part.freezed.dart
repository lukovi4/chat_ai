// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'content_part.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$ContentPart {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ContentPart);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'ContentPart()';
}


}

/// @nodoc
class $ContentPartCopyWith<$Res>  {
$ContentPartCopyWith(ContentPart _, $Res Function(ContentPart) __);
}


/// Adds pattern-matching-related methods to [ContentPart].
extension ContentPartPatterns on ContentPart {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( TextPart value)?  text,TResult Function( ImagePart value)?  image,TResult Function( ToolCallPart value)?  toolCall,TResult Function( ToolResultPart value)?  toolResult,TResult Function( ProviderOpaquePart value)?  providerOpaque,required TResult orElse(),}){
final _that = this;
switch (_that) {
case TextPart() when text != null:
return text(_that);case ImagePart() when image != null:
return image(_that);case ToolCallPart() when toolCall != null:
return toolCall(_that);case ToolResultPart() when toolResult != null:
return toolResult(_that);case ProviderOpaquePart() when providerOpaque != null:
return providerOpaque(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( TextPart value)  text,required TResult Function( ImagePart value)  image,required TResult Function( ToolCallPart value)  toolCall,required TResult Function( ToolResultPart value)  toolResult,required TResult Function( ProviderOpaquePart value)  providerOpaque,}){
final _that = this;
switch (_that) {
case TextPart():
return text(_that);case ImagePart():
return image(_that);case ToolCallPart():
return toolCall(_that);case ToolResultPart():
return toolResult(_that);case ProviderOpaquePart():
return providerOpaque(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( TextPart value)?  text,TResult? Function( ImagePart value)?  image,TResult? Function( ToolCallPart value)?  toolCall,TResult? Function( ToolResultPart value)?  toolResult,TResult? Function( ProviderOpaquePart value)?  providerOpaque,}){
final _that = this;
switch (_that) {
case TextPart() when text != null:
return text(_that);case ImagePart() when image != null:
return image(_that);case ToolCallPart() when toolCall != null:
return toolCall(_that);case ToolResultPart() when toolResult != null:
return toolResult(_that);case ProviderOpaquePart() when providerOpaque != null:
return providerOpaque(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String text)?  text,TResult Function( Uint8List bytes)?  image,TResult Function( String toolCallId,  String name,  Map<String, dynamic> args)?  toolCall,TResult Function( String toolCallId,  String content,  bool isError)?  toolResult,TResult Function( String provider,  Uint8List data)?  providerOpaque,required TResult orElse(),}) {final _that = this;
switch (_that) {
case TextPart() when text != null:
return text(_that.text);case ImagePart() when image != null:
return image(_that.bytes);case ToolCallPart() when toolCall != null:
return toolCall(_that.toolCallId,_that.name,_that.args);case ToolResultPart() when toolResult != null:
return toolResult(_that.toolCallId,_that.content,_that.isError);case ProviderOpaquePart() when providerOpaque != null:
return providerOpaque(_that.provider,_that.data);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String text)  text,required TResult Function( Uint8List bytes)  image,required TResult Function( String toolCallId,  String name,  Map<String, dynamic> args)  toolCall,required TResult Function( String toolCallId,  String content,  bool isError)  toolResult,required TResult Function( String provider,  Uint8List data)  providerOpaque,}) {final _that = this;
switch (_that) {
case TextPart():
return text(_that.text);case ImagePart():
return image(_that.bytes);case ToolCallPart():
return toolCall(_that.toolCallId,_that.name,_that.args);case ToolResultPart():
return toolResult(_that.toolCallId,_that.content,_that.isError);case ProviderOpaquePart():
return providerOpaque(_that.provider,_that.data);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String text)?  text,TResult? Function( Uint8List bytes)?  image,TResult? Function( String toolCallId,  String name,  Map<String, dynamic> args)?  toolCall,TResult? Function( String toolCallId,  String content,  bool isError)?  toolResult,TResult? Function( String provider,  Uint8List data)?  providerOpaque,}) {final _that = this;
switch (_that) {
case TextPart() when text != null:
return text(_that.text);case ImagePart() when image != null:
return image(_that.bytes);case ToolCallPart() when toolCall != null:
return toolCall(_that.toolCallId,_that.name,_that.args);case ToolResultPart() when toolResult != null:
return toolResult(_that.toolCallId,_that.content,_that.isError);case ProviderOpaquePart() when providerOpaque != null:
return providerOpaque(_that.provider,_that.data);case _:
  return null;

}
}

}

/// @nodoc


class TextPart extends ContentPart {
  const TextPart(this.text): super._();
  

 final  String text;

/// Create a copy of ContentPart
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$TextPartCopyWith<TextPart> get copyWith => _$TextPartCopyWithImpl<TextPart>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is TextPart&&(identical(other.text, text) || other.text == text));
}


@override
int get hashCode => Object.hash(runtimeType,text);

@override
String toString() {
  return 'ContentPart.text(text: $text)';
}


}

/// @nodoc
abstract mixin class $TextPartCopyWith<$Res> implements $ContentPartCopyWith<$Res> {
  factory $TextPartCopyWith(TextPart value, $Res Function(TextPart) _then) = _$TextPartCopyWithImpl;
@useResult
$Res call({
 String text
});




}
/// @nodoc
class _$TextPartCopyWithImpl<$Res>
    implements $TextPartCopyWith<$Res> {
  _$TextPartCopyWithImpl(this._self, this._then);

  final TextPart _self;
  final $Res Function(TextPart) _then;

/// Create a copy of ContentPart
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? text = null,}) {
  return _then(TextPart(
null == text ? _self.text : text // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class ImagePart extends ContentPart {
  const ImagePart(this.bytes): super._();
  

 final  Uint8List bytes;

/// Create a copy of ContentPart
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ImagePartCopyWith<ImagePart> get copyWith => _$ImagePartCopyWithImpl<ImagePart>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ImagePart&&const DeepCollectionEquality().equals(other.bytes, bytes));
}


@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(bytes));

@override
String toString() {
  return 'ContentPart.image(bytes: $bytes)';
}


}

/// @nodoc
abstract mixin class $ImagePartCopyWith<$Res> implements $ContentPartCopyWith<$Res> {
  factory $ImagePartCopyWith(ImagePart value, $Res Function(ImagePart) _then) = _$ImagePartCopyWithImpl;
@useResult
$Res call({
 Uint8List bytes
});




}
/// @nodoc
class _$ImagePartCopyWithImpl<$Res>
    implements $ImagePartCopyWith<$Res> {
  _$ImagePartCopyWithImpl(this._self, this._then);

  final ImagePart _self;
  final $Res Function(ImagePart) _then;

/// Create a copy of ContentPart
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? bytes = null,}) {
  return _then(ImagePart(
null == bytes ? _self.bytes : bytes // ignore: cast_nullable_to_non_nullable
as Uint8List,
  ));
}


}

/// @nodoc


class ToolCallPart extends ContentPart {
  const ToolCallPart(this.toolCallId, this.name, final  Map<String, dynamic> args): _args = args,super._();
  

 final  String toolCallId;
 final  String name;
 final  Map<String, dynamic> _args;
 Map<String, dynamic> get args {
  if (_args is EqualUnmodifiableMapView) return _args;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableMapView(_args);
}


/// Create a copy of ContentPart
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ToolCallPartCopyWith<ToolCallPart> get copyWith => _$ToolCallPartCopyWithImpl<ToolCallPart>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ToolCallPart&&(identical(other.toolCallId, toolCallId) || other.toolCallId == toolCallId)&&(identical(other.name, name) || other.name == name)&&const DeepCollectionEquality().equals(other._args, _args));
}


@override
int get hashCode => Object.hash(runtimeType,toolCallId,name,const DeepCollectionEquality().hash(_args));

@override
String toString() {
  return 'ContentPart.toolCall(toolCallId: $toolCallId, name: $name, args: $args)';
}


}

/// @nodoc
abstract mixin class $ToolCallPartCopyWith<$Res> implements $ContentPartCopyWith<$Res> {
  factory $ToolCallPartCopyWith(ToolCallPart value, $Res Function(ToolCallPart) _then) = _$ToolCallPartCopyWithImpl;
@useResult
$Res call({
 String toolCallId, String name, Map<String, dynamic> args
});




}
/// @nodoc
class _$ToolCallPartCopyWithImpl<$Res>
    implements $ToolCallPartCopyWith<$Res> {
  _$ToolCallPartCopyWithImpl(this._self, this._then);

  final ToolCallPart _self;
  final $Res Function(ToolCallPart) _then;

/// Create a copy of ContentPart
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? toolCallId = null,Object? name = null,Object? args = null,}) {
  return _then(ToolCallPart(
null == toolCallId ? _self.toolCallId : toolCallId // ignore: cast_nullable_to_non_nullable
as String,null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,null == args ? _self._args : args // ignore: cast_nullable_to_non_nullable
as Map<String, dynamic>,
  ));
}


}

/// @nodoc


class ToolResultPart extends ContentPart {
  const ToolResultPart(this.toolCallId, this.content, this.isError): super._();
  

 final  String toolCallId;
 final  String content;
 final  bool isError;

/// Create a copy of ContentPart
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ToolResultPartCopyWith<ToolResultPart> get copyWith => _$ToolResultPartCopyWithImpl<ToolResultPart>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ToolResultPart&&(identical(other.toolCallId, toolCallId) || other.toolCallId == toolCallId)&&(identical(other.content, content) || other.content == content)&&(identical(other.isError, isError) || other.isError == isError));
}


@override
int get hashCode => Object.hash(runtimeType,toolCallId,content,isError);

@override
String toString() {
  return 'ContentPart.toolResult(toolCallId: $toolCallId, content: $content, isError: $isError)';
}


}

/// @nodoc
abstract mixin class $ToolResultPartCopyWith<$Res> implements $ContentPartCopyWith<$Res> {
  factory $ToolResultPartCopyWith(ToolResultPart value, $Res Function(ToolResultPart) _then) = _$ToolResultPartCopyWithImpl;
@useResult
$Res call({
 String toolCallId, String content, bool isError
});




}
/// @nodoc
class _$ToolResultPartCopyWithImpl<$Res>
    implements $ToolResultPartCopyWith<$Res> {
  _$ToolResultPartCopyWithImpl(this._self, this._then);

  final ToolResultPart _self;
  final $Res Function(ToolResultPart) _then;

/// Create a copy of ContentPart
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? toolCallId = null,Object? content = null,Object? isError = null,}) {
  return _then(ToolResultPart(
null == toolCallId ? _self.toolCallId : toolCallId // ignore: cast_nullable_to_non_nullable
as String,null == content ? _self.content : content // ignore: cast_nullable_to_non_nullable
as String,null == isError ? _self.isError : isError // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc


class ProviderOpaquePart extends ContentPart {
  const ProviderOpaquePart(this.provider, this.data): super._();
  

 final  String provider;
 final  Uint8List data;

/// Create a copy of ContentPart
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ProviderOpaquePartCopyWith<ProviderOpaquePart> get copyWith => _$ProviderOpaquePartCopyWithImpl<ProviderOpaquePart>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ProviderOpaquePart&&(identical(other.provider, provider) || other.provider == provider)&&const DeepCollectionEquality().equals(other.data, data));
}


@override
int get hashCode => Object.hash(runtimeType,provider,const DeepCollectionEquality().hash(data));

@override
String toString() {
  return 'ContentPart.providerOpaque(provider: $provider, data: $data)';
}


}

/// @nodoc
abstract mixin class $ProviderOpaquePartCopyWith<$Res> implements $ContentPartCopyWith<$Res> {
  factory $ProviderOpaquePartCopyWith(ProviderOpaquePart value, $Res Function(ProviderOpaquePart) _then) = _$ProviderOpaquePartCopyWithImpl;
@useResult
$Res call({
 String provider, Uint8List data
});




}
/// @nodoc
class _$ProviderOpaquePartCopyWithImpl<$Res>
    implements $ProviderOpaquePartCopyWith<$Res> {
  _$ProviderOpaquePartCopyWithImpl(this._self, this._then);

  final ProviderOpaquePart _self;
  final $Res Function(ProviderOpaquePart) _then;

/// Create a copy of ContentPart
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? provider = null,Object? data = null,}) {
  return _then(ProviderOpaquePart(
null == provider ? _self.provider : provider // ignore: cast_nullable_to_non_nullable
as String,null == data ? _self.data : data // ignore: cast_nullable_to_non_nullable
as Uint8List,
  ));
}


}

// dart format on
