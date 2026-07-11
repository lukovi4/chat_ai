import 'package:freezed_annotation/freezed_annotation.dart';

/// Internal json converter: `DateTime` ⇄ ISO-8601 **UTC** string
/// (V1_SPEC §5 — `createdAt` is stored as ISO-8601 UTC).
///
/// Writing always converts to UTC first. Reading accepts only strings with an
/// explicit timezone designator (`Z` or a `±hh[:mm]` offset) and normalizes
/// them to UTC; a timezone-naive string is a read error — `DateTime.parse`
/// would interpret it in the device's local zone, so one JSON could restore
/// to different instants on different devices. Not exported from the public
/// barrel.
class UtcDateTimeConverter implements JsonConverter<DateTime, String> {
  const UtcDateTimeConverter();

  /// A full ISO-8601 timestamp with a mandatory time part and a mandatory
  /// timezone designator: `Z`/`z` or an explicit offset (`+03`, `+0300`,
  /// `+03:00`, `-07:00`, …). A tail-only offset check is not enough: a bare
  /// date like `2026-07-10` ends in `-10`, which reads as an offset.
  static final RegExp _zonedIso8601 = RegExp(
    r'^\d{4}-\d{2}-\d{2}[Tt ]\d{2}:\d{2}(?::\d{2}(?:\.\d{1,6})?)?'
    r'(?:[zZ]|[+-]\d{2}(?::?\d{2})?)$',
  );

  @override
  DateTime fromJson(String json) {
    if (!_zonedIso8601.hasMatch(json)) {
      throw FormatException(
        'createdAt must be an ISO-8601 timestamp with an explicit timezone '
        '(Z or ±hh:mm): "$json"',
      );
    }
    return DateTime.parse(json).toUtc();
  }

  @override
  String toJson(DateTime object) => object.toUtc().toIso8601String();
}
