// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'backend_event.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$BackendEvent {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BackendEvent);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'BackendEvent()';
}


}




/// Adds pattern-matching-related methods to [BackendEvent].
extension BackendEventPatterns on BackendEvent {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( Accepted value)?  accepted,TResult Function( Delta value)?  delta,TResult Function( ProviderStateEvent value)?  providerState,TResult Function( ToolCallEvent value)?  toolCall,TResult Function( DoneEvent value)?  done,TResult Function( ErrorEvent value)?  error,TResult Function( ConflictEvent value)?  conflict,TResult Function( GoneEvent value)?  gone,required TResult orElse(),}){
final _that = this;
switch (_that) {
case Accepted() when accepted != null:
return accepted(_that);case Delta() when delta != null:
return delta(_that);case ProviderStateEvent() when providerState != null:
return providerState(_that);case ToolCallEvent() when toolCall != null:
return toolCall(_that);case DoneEvent() when done != null:
return done(_that);case ErrorEvent() when error != null:
return error(_that);case ConflictEvent() when conflict != null:
return conflict(_that);case GoneEvent() when gone != null:
return gone(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( Accepted value)  accepted,required TResult Function( Delta value)  delta,required TResult Function( ProviderStateEvent value)  providerState,required TResult Function( ToolCallEvent value)  toolCall,required TResult Function( DoneEvent value)  done,required TResult Function( ErrorEvent value)  error,required TResult Function( ConflictEvent value)  conflict,required TResult Function( GoneEvent value)  gone,}){
final _that = this;
switch (_that) {
case Accepted():
return accepted(_that);case Delta():
return delta(_that);case ProviderStateEvent():
return providerState(_that);case ToolCallEvent():
return toolCall(_that);case DoneEvent():
return done(_that);case ErrorEvent():
return error(_that);case ConflictEvent():
return conflict(_that);case GoneEvent():
return gone(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( Accepted value)?  accepted,TResult? Function( Delta value)?  delta,TResult? Function( ProviderStateEvent value)?  providerState,TResult? Function( ToolCallEvent value)?  toolCall,TResult? Function( DoneEvent value)?  done,TResult? Function( ErrorEvent value)?  error,TResult? Function( ConflictEvent value)?  conflict,TResult? Function( GoneEvent value)?  gone,}){
final _that = this;
switch (_that) {
case Accepted() when accepted != null:
return accepted(_that);case Delta() when delta != null:
return delta(_that);case ProviderStateEvent() when providerState != null:
return providerState(_that);case ToolCallEvent() when toolCall != null:
return toolCall(_that);case DoneEvent() when done != null:
return done(_that);case ErrorEvent() when error != null:
return error(_that);case ConflictEvent() when conflict != null:
return conflict(_that);case GoneEvent() when gone != null:
return gone(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function()?  accepted,TResult Function( String text)?  delta,TResult Function( ProviderOpaquePart part)?  providerState,TResult Function( ToolCall call,  Usage? usage)?  toolCall,TResult Function( Usage? usage)?  done,TResult Function( FailureCause cause,  String? detail,  Usage? usage,  Duration? retryAfter)?  error,TResult Function()?  conflict,TResult Function()?  gone,required TResult orElse(),}) {final _that = this;
switch (_that) {
case Accepted() when accepted != null:
return accepted();case Delta() when delta != null:
return delta(_that.text);case ProviderStateEvent() when providerState != null:
return providerState(_that.part);case ToolCallEvent() when toolCall != null:
return toolCall(_that.call,_that.usage);case DoneEvent() when done != null:
return done(_that.usage);case ErrorEvent() when error != null:
return error(_that.cause,_that.detail,_that.usage,_that.retryAfter);case ConflictEvent() when conflict != null:
return conflict();case GoneEvent() when gone != null:
return gone();case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function()  accepted,required TResult Function( String text)  delta,required TResult Function( ProviderOpaquePart part)  providerState,required TResult Function( ToolCall call,  Usage? usage)  toolCall,required TResult Function( Usage? usage)  done,required TResult Function( FailureCause cause,  String? detail,  Usage? usage,  Duration? retryAfter)  error,required TResult Function()  conflict,required TResult Function()  gone,}) {final _that = this;
switch (_that) {
case Accepted():
return accepted();case Delta():
return delta(_that.text);case ProviderStateEvent():
return providerState(_that.part);case ToolCallEvent():
return toolCall(_that.call,_that.usage);case DoneEvent():
return done(_that.usage);case ErrorEvent():
return error(_that.cause,_that.detail,_that.usage,_that.retryAfter);case ConflictEvent():
return conflict();case GoneEvent():
return gone();}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function()?  accepted,TResult? Function( String text)?  delta,TResult? Function( ProviderOpaquePart part)?  providerState,TResult? Function( ToolCall call,  Usage? usage)?  toolCall,TResult? Function( Usage? usage)?  done,TResult? Function( FailureCause cause,  String? detail,  Usage? usage,  Duration? retryAfter)?  error,TResult? Function()?  conflict,TResult? Function()?  gone,}) {final _that = this;
switch (_that) {
case Accepted() when accepted != null:
return accepted();case Delta() when delta != null:
return delta(_that.text);case ProviderStateEvent() when providerState != null:
return providerState(_that.part);case ToolCallEvent() when toolCall != null:
return toolCall(_that.call,_that.usage);case DoneEvent() when done != null:
return done(_that.usage);case ErrorEvent() when error != null:
return error(_that.cause,_that.detail,_that.usage,_that.retryAfter);case ConflictEvent() when conflict != null:
return conflict();case GoneEvent() when gone != null:
return gone();case _:
  return null;

}
}

}

/// @nodoc


class Accepted implements BackendEvent {
  const Accepted();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Accepted);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'BackendEvent.accepted()';
}


}




/// @nodoc


class Delta implements BackendEvent {
  const Delta(this.text);
  

 final  String text;




@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is Delta&&(identical(other.text, text) || other.text == text));
}


@override
int get hashCode => Object.hash(runtimeType,text);

@override
String toString() {
  return 'BackendEvent.delta(text: $text)';
}


}




/// @nodoc


class ProviderStateEvent implements BackendEvent {
  const ProviderStateEvent(this.part);
  

 final  ProviderOpaquePart part;




@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ProviderStateEvent&&const DeepCollectionEquality().equals(other.part, part));
}


@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(part));

@override
String toString() {
  return 'BackendEvent.providerState(part: $part)';
}


}




/// @nodoc


class ToolCallEvent implements BackendEvent {
  const ToolCallEvent(this.call, {this.usage});
  

 final  ToolCall call;
 final  Usage? usage;




@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ToolCallEvent&&(identical(other.call, call) || other.call == call)&&(identical(other.usage, usage) || other.usage == usage));
}


@override
int get hashCode => Object.hash(runtimeType,call,usage);

@override
String toString() {
  return 'BackendEvent.toolCall(call: $call, usage: $usage)';
}


}




/// @nodoc


class DoneEvent implements BackendEvent {
  const DoneEvent({this.usage});
  

 final  Usage? usage;




@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is DoneEvent&&(identical(other.usage, usage) || other.usage == usage));
}


@override
int get hashCode => Object.hash(runtimeType,usage);

@override
String toString() {
  return 'BackendEvent.done(usage: $usage)';
}


}




/// @nodoc


class ErrorEvent implements BackendEvent {
  const ErrorEvent(this.cause, {this.detail, this.usage, this.retryAfter});
  

 final  FailureCause cause;
 final  String? detail;
 final  Usage? usage;
 final  Duration? retryAfter;




@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ErrorEvent&&(identical(other.cause, cause) || other.cause == cause)&&(identical(other.detail, detail) || other.detail == detail)&&(identical(other.usage, usage) || other.usage == usage)&&(identical(other.retryAfter, retryAfter) || other.retryAfter == retryAfter));
}


@override
int get hashCode => Object.hash(runtimeType,cause,detail,usage,retryAfter);

@override
String toString() {
  return 'BackendEvent.error(cause: $cause, detail: $detail, usage: $usage, retryAfter: $retryAfter)';
}


}




/// @nodoc


class ConflictEvent implements BackendEvent {
  const ConflictEvent();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is ConflictEvent);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'BackendEvent.conflict()';
}


}




/// @nodoc


class GoneEvent implements BackendEvent {
  const GoneEvent();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is GoneEvent);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'BackendEvent.gone()';
}


}




// dart format on
