// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'image_send_options.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$ImageSendOptions {

 int get maxLongEdge; int get jpegQuality; int get maxImagesPerMessage;
/// Create a copy of ImageSendOptions
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$ImageSendOptionsCopyWith<ImageSendOptions> get copyWith => _$ImageSendOptionsCopyWithImpl<ImageSendOptions>(this as ImageSendOptions, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ImageSendOptions&&(identical(other.maxLongEdge, maxLongEdge) || other.maxLongEdge == maxLongEdge)&&(identical(other.jpegQuality, jpegQuality) || other.jpegQuality == jpegQuality)&&(identical(other.maxImagesPerMessage, maxImagesPerMessage) || other.maxImagesPerMessage == maxImagesPerMessage));
}


@override
int get hashCode => Object.hash(runtimeType,maxLongEdge,jpegQuality,maxImagesPerMessage);

@override
String toString() {
  return 'ImageSendOptions(maxLongEdge: $maxLongEdge, jpegQuality: $jpegQuality, maxImagesPerMessage: $maxImagesPerMessage)';
}


}

/// @nodoc
abstract mixin class $ImageSendOptionsCopyWith<$Res>  {
  factory $ImageSendOptionsCopyWith(ImageSendOptions value, $Res Function(ImageSendOptions) _then) = _$ImageSendOptionsCopyWithImpl;
@useResult
$Res call({
 int maxLongEdge, int jpegQuality, int maxImagesPerMessage
});




}
/// @nodoc
class _$ImageSendOptionsCopyWithImpl<$Res>
    implements $ImageSendOptionsCopyWith<$Res> {
  _$ImageSendOptionsCopyWithImpl(this._self, this._then);

  final ImageSendOptions _self;
  final $Res Function(ImageSendOptions) _then;

/// Create a copy of ImageSendOptions
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? maxLongEdge = null,Object? jpegQuality = null,Object? maxImagesPerMessage = null,}) {
  return _then(_self.copyWith(
maxLongEdge: null == maxLongEdge ? _self.maxLongEdge : maxLongEdge // ignore: cast_nullable_to_non_nullable
as int,jpegQuality: null == jpegQuality ? _self.jpegQuality : jpegQuality // ignore: cast_nullable_to_non_nullable
as int,maxImagesPerMessage: null == maxImagesPerMessage ? _self.maxImagesPerMessage : maxImagesPerMessage // ignore: cast_nullable_to_non_nullable
as int,
  ));
}

}


/// Adds pattern-matching-related methods to [ImageSendOptions].
extension ImageSendOptionsPatterns on ImageSendOptions {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _ImageSendOptions value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _ImageSendOptions() when $default != null:
return $default(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _ImageSendOptions value)  $default,){
final _that = this;
switch (_that) {
case _ImageSendOptions():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _ImageSendOptions value)?  $default,){
final _that = this;
switch (_that) {
case _ImageSendOptions() when $default != null:
return $default(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( int maxLongEdge,  int jpegQuality,  int maxImagesPerMessage)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _ImageSendOptions() when $default != null:
return $default(_that.maxLongEdge,_that.jpegQuality,_that.maxImagesPerMessage);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( int maxLongEdge,  int jpegQuality,  int maxImagesPerMessage)  $default,) {final _that = this;
switch (_that) {
case _ImageSendOptions():
return $default(_that.maxLongEdge,_that.jpegQuality,_that.maxImagesPerMessage);case _:
  throw StateError('Unexpected subclass');

}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( int maxLongEdge,  int jpegQuality,  int maxImagesPerMessage)?  $default,) {final _that = this;
switch (_that) {
case _ImageSendOptions() when $default != null:
return $default(_that.maxLongEdge,_that.jpegQuality,_that.maxImagesPerMessage);case _:
  return null;

}
}

}

/// @nodoc


class _ImageSendOptions implements ImageSendOptions {
  const _ImageSendOptions({this.maxLongEdge = 2048, this.jpegQuality = 85, this.maxImagesPerMessage = 4});
  

@override@JsonKey() final  int maxLongEdge;
@override@JsonKey() final  int jpegQuality;
@override@JsonKey() final  int maxImagesPerMessage;

/// Create a copy of ImageSendOptions
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$ImageSendOptionsCopyWith<_ImageSendOptions> get copyWith => __$ImageSendOptionsCopyWithImpl<_ImageSendOptions>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _ImageSendOptions&&(identical(other.maxLongEdge, maxLongEdge) || other.maxLongEdge == maxLongEdge)&&(identical(other.jpegQuality, jpegQuality) || other.jpegQuality == jpegQuality)&&(identical(other.maxImagesPerMessage, maxImagesPerMessage) || other.maxImagesPerMessage == maxImagesPerMessage));
}


@override
int get hashCode => Object.hash(runtimeType,maxLongEdge,jpegQuality,maxImagesPerMessage);

@override
String toString() {
  return 'ImageSendOptions(maxLongEdge: $maxLongEdge, jpegQuality: $jpegQuality, maxImagesPerMessage: $maxImagesPerMessage)';
}


}

/// @nodoc
abstract mixin class _$ImageSendOptionsCopyWith<$Res> implements $ImageSendOptionsCopyWith<$Res> {
  factory _$ImageSendOptionsCopyWith(_ImageSendOptions value, $Res Function(_ImageSendOptions) _then) = __$ImageSendOptionsCopyWithImpl;
@override @useResult
$Res call({
 int maxLongEdge, int jpegQuality, int maxImagesPerMessage
});




}
/// @nodoc
class __$ImageSendOptionsCopyWithImpl<$Res>
    implements _$ImageSendOptionsCopyWith<$Res> {
  __$ImageSendOptionsCopyWithImpl(this._self, this._then);

  final _ImageSendOptions _self;
  final $Res Function(_ImageSendOptions) _then;

/// Create a copy of ImageSendOptions
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? maxLongEdge = null,Object? jpegQuality = null,Object? maxImagesPerMessage = null,}) {
  return _then(_ImageSendOptions(
maxLongEdge: null == maxLongEdge ? _self.maxLongEdge : maxLongEdge // ignore: cast_nullable_to_non_nullable
as int,jpegQuality: null == jpegQuality ? _self.jpegQuality : jpegQuality // ignore: cast_nullable_to_non_nullable
as int,maxImagesPerMessage: null == maxImagesPerMessage ? _self.maxImagesPerMessage : maxImagesPerMessage // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

// dart format on
