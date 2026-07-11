// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'conversation_state.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$ConversationState {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ConversationState);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'ConversationState()';
}


}




/// Adds pattern-matching-related methods to [ConversationState].
extension ConversationStatePatterns on ConversationState {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( Idle value)?  idle,TResult Function( Sending value)?  sending,TResult Function( AwaitingTool value)?  awaitingTool,TResult Function( Streaming value)?  streaming,TResult Function( Done value)?  done,TResult Function( Failed value)?  failed,TResult Function( Cancelled value)?  cancelled,required TResult orElse(),}){
final _that = this;
switch (_that) {
case Idle() when idle != null:
return idle(_that);case Sending() when sending != null:
return sending(_that);case AwaitingTool() when awaitingTool != null:
return awaitingTool(_that);case Streaming() when streaming != null:
return streaming(_that);case Done() when done != null:
return done(_that);case Failed() when failed != null:
return failed(_that);case Cancelled() when cancelled != null:
return cancelled(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( Idle value)  idle,required TResult Function( Sending value)  sending,required TResult Function( AwaitingTool value)  awaitingTool,required TResult Function( Streaming value)  streaming,required TResult Function( Done value)  done,required TResult Function( Failed value)  failed,required TResult Function( Cancelled value)  cancelled,}){
final _that = this;
switch (_that) {
case Idle():
return idle(_that);case Sending():
return sending(_that);case AwaitingTool():
return awaitingTool(_that);case Streaming():
return streaming(_that);case Done():
return done(_that);case Failed():
return failed(_that);case Cancelled():
return cancelled(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( Idle value)?  idle,TResult? Function( Sending value)?  sending,TResult? Function( AwaitingTool value)?  awaitingTool,TResult? Function( Streaming value)?  streaming,TResult? Function( Done value)?  done,TResult? Function( Failed value)?  failed,TResult? Function( Cancelled value)?  cancelled,}){
final _that = this;
switch (_that) {
case Idle() when idle != null:
return idle(_that);case Sending() when sending != null:
return sending(_that);case AwaitingTool() when awaitingTool != null:
return awaitingTool(_that);case Streaming() when streaming != null:
return streaming(_that);case Done() when done != null:
return done(_that);case Failed() when failed != null:
return failed(_that);case Cancelled() when cancelled != null:
return cancelled(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function()?  idle,TResult Function()?  sending,TResult Function( ToolCall call)?  awaitingTool,TResult Function()?  streaming,TResult Function( Usage? usage)?  done,TResult Function( FailureCause cause,  FailurePhase phase,  String? developerDetail)?  failed,TResult Function()?  cancelled,required TResult orElse(),}) {final _that = this;
switch (_that) {
case Idle() when idle != null:
return idle();case Sending() when sending != null:
return sending();case AwaitingTool() when awaitingTool != null:
return awaitingTool(_that.call);case Streaming() when streaming != null:
return streaming();case Done() when done != null:
return done(_that.usage);case Failed() when failed != null:
return failed(_that.cause,_that.phase,_that.developerDetail);case Cancelled() when cancelled != null:
return cancelled();case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function()  idle,required TResult Function()  sending,required TResult Function( ToolCall call)  awaitingTool,required TResult Function()  streaming,required TResult Function( Usage? usage)  done,required TResult Function( FailureCause cause,  FailurePhase phase,  String? developerDetail)  failed,required TResult Function()  cancelled,}) {final _that = this;
switch (_that) {
case Idle():
return idle();case Sending():
return sending();case AwaitingTool():
return awaitingTool(_that.call);case Streaming():
return streaming();case Done():
return done(_that.usage);case Failed():
return failed(_that.cause,_that.phase,_that.developerDetail);case Cancelled():
return cancelled();}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function()?  idle,TResult? Function()?  sending,TResult? Function( ToolCall call)?  awaitingTool,TResult? Function()?  streaming,TResult? Function( Usage? usage)?  done,TResult? Function( FailureCause cause,  FailurePhase phase,  String? developerDetail)?  failed,TResult? Function()?  cancelled,}) {final _that = this;
switch (_that) {
case Idle() when idle != null:
return idle();case Sending() when sending != null:
return sending();case AwaitingTool() when awaitingTool != null:
return awaitingTool(_that.call);case Streaming() when streaming != null:
return streaming();case Done() when done != null:
return done(_that.usage);case Failed() when failed != null:
return failed(_that.cause,_that.phase,_that.developerDetail);case Cancelled() when cancelled != null:
return cancelled();case _:
  return null;

}
}

}

/// @nodoc


class Idle implements ConversationState {
  const Idle();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Idle);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'ConversationState.idle()';
}


}




/// @nodoc


class Sending implements ConversationState {
  const Sending();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Sending);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'ConversationState.sending()';
}


}




/// @nodoc


class AwaitingTool implements ConversationState {
  const AwaitingTool(this.call);
  

 final  ToolCall call;




@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is AwaitingTool&&(identical(other.call, call) || other.call == call));
}


@override
int get hashCode => Object.hash(runtimeType,call);

@override
String toString() {
  return 'ConversationState.awaitingTool(call: $call)';
}


}




/// @nodoc


class Streaming implements ConversationState {
  const Streaming();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Streaming);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'ConversationState.streaming()';
}


}




/// @nodoc


class Done implements ConversationState {
  const Done({this.usage});
  

 final  Usage? usage;




@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Done&&(identical(other.usage, usage) || other.usage == usage));
}


@override
int get hashCode => Object.hash(runtimeType,usage);

@override
String toString() {
  return 'ConversationState.done(usage: $usage)';
}


}




/// @nodoc


class Failed implements ConversationState {
  const Failed(this.cause, this.phase, {this.developerDetail});
  

 final  FailureCause cause;
 final  FailurePhase phase;
 final  String? developerDetail;




@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Failed&&(identical(other.cause, cause) || other.cause == cause)&&(identical(other.phase, phase) || other.phase == phase)&&(identical(other.developerDetail, developerDetail) || other.developerDetail == developerDetail));
}


@override
int get hashCode => Object.hash(runtimeType,cause,phase,developerDetail);

@override
String toString() {
  return 'ConversationState.failed(cause: $cause, phase: $phase, developerDetail: $developerDetail)';
}


}




/// @nodoc


class Cancelled implements ConversationState {
  const Cancelled();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Cancelled);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'ConversationState.cancelled()';
}


}




// dart format on
