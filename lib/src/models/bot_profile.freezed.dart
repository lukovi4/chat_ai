// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'bot_profile.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$BotProfile {

 String get id; String get systemPrompt; List<Tool> get tools;
/// Create a copy of BotProfile
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$BotProfileCopyWith<BotProfile> get copyWith => _$BotProfileCopyWithImpl<BotProfile>(this as BotProfile, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BotProfile&&(identical(other.id, id) || other.id == id)&&(identical(other.systemPrompt, systemPrompt) || other.systemPrompt == systemPrompt)&&const DeepCollectionEquality().equals(other.tools, tools));
}


@override
int get hashCode => Object.hash(runtimeType,id,systemPrompt,const DeepCollectionEquality().hash(tools));

@override
String toString() {
  return 'BotProfile(id: $id, systemPrompt: $systemPrompt, tools: $tools)';
}


}

/// @nodoc
abstract mixin class $BotProfileCopyWith<$Res>  {
  factory $BotProfileCopyWith(BotProfile value, $Res Function(BotProfile) _then) = _$BotProfileCopyWithImpl;
@useResult
$Res call({
 String id, String systemPrompt, List<Tool> tools
});




}
/// @nodoc
class _$BotProfileCopyWithImpl<$Res>
    implements $BotProfileCopyWith<$Res> {
  _$BotProfileCopyWithImpl(this._self, this._then);

  final BotProfile _self;
  final $Res Function(BotProfile) _then;

/// Create a copy of BotProfile
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? systemPrompt = null,Object? tools = null,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,systemPrompt: null == systemPrompt ? _self.systemPrompt : systemPrompt // ignore: cast_nullable_to_non_nullable
as String,tools: null == tools ? _self.tools : tools // ignore: cast_nullable_to_non_nullable
as List<Tool>,
  ));
}

}


/// Adds pattern-matching-related methods to [BotProfile].
extension BotProfilePatterns on BotProfile {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _BotProfile value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _BotProfile() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _BotProfile value)  $default,){
final _that = this;
switch (_that) {
case _BotProfile():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _BotProfile value)?  $default,){
final _that = this;
switch (_that) {
case _BotProfile() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String systemPrompt,  List<Tool> tools)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _BotProfile() when $default != null:
return $default(_that.id,_that.systemPrompt,_that.tools);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String systemPrompt,  List<Tool> tools)  $default,) {final _that = this;
switch (_that) {
case _BotProfile():
return $default(_that.id,_that.systemPrompt,_that.tools);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String systemPrompt,  List<Tool> tools)?  $default,) {final _that = this;
switch (_that) {
case _BotProfile() when $default != null:
return $default(_that.id,_that.systemPrompt,_that.tools);case _:
  return null;

}
}

}

/// @nodoc


class _BotProfile implements BotProfile {
  const _BotProfile({required this.id, required this.systemPrompt, required final  List<Tool> tools}): _tools = tools;
  

@override final  String id;
@override final  String systemPrompt;
 final  List<Tool> _tools;
@override List<Tool> get tools {
  if (_tools is EqualUnmodifiableListView) return _tools;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_tools);
}


/// Create a copy of BotProfile
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$BotProfileCopyWith<_BotProfile> get copyWith => __$BotProfileCopyWithImpl<_BotProfile>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _BotProfile&&(identical(other.id, id) || other.id == id)&&(identical(other.systemPrompt, systemPrompt) || other.systemPrompt == systemPrompt)&&const DeepCollectionEquality().equals(other._tools, _tools));
}


@override
int get hashCode => Object.hash(runtimeType,id,systemPrompt,const DeepCollectionEquality().hash(_tools));

@override
String toString() {
  return 'BotProfile(id: $id, systemPrompt: $systemPrompt, tools: $tools)';
}


}

/// @nodoc
abstract mixin class _$BotProfileCopyWith<$Res> implements $BotProfileCopyWith<$Res> {
  factory _$BotProfileCopyWith(_BotProfile value, $Res Function(_BotProfile) _then) = __$BotProfileCopyWithImpl;
@override @useResult
$Res call({
 String id, String systemPrompt, List<Tool> tools
});




}
/// @nodoc
class __$BotProfileCopyWithImpl<$Res>
    implements _$BotProfileCopyWith<$Res> {
  __$BotProfileCopyWithImpl(this._self, this._then);

  final _BotProfile _self;
  final $Res Function(_BotProfile) _then;

/// Create a copy of BotProfile
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? systemPrompt = null,Object? tools = null,}) {
  return _then(_BotProfile(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,systemPrompt: null == systemPrompt ? _self.systemPrompt : systemPrompt // ignore: cast_nullable_to_non_nullable
as String,tools: null == tools ? _self._tools : tools // ignore: cast_nullable_to_non_nullable
as List<Tool>,
  ));
}


}

// dart format on
