/// Parse outcome types shared by every importer. Importers never throw on
/// user data; they report per-entry success, skip or failure with a reason.
library;

import '../models/node.dart';

enum ImportFailureKind {
  malformedLink('malformed_link'),
  unsupportedProtocol('unsupported_protocol'),
  unsupportedParameter('unsupported_parameter'),
  missingRequired('missing_required'),
  duplicate('duplicate'),
  emptyInput('empty_input'),
  decodeError('decode_error');

  const ImportFailureKind(this.wire);
  final String wire;
}

/// Longest rejected entry that is kept for display, in characters.
///
/// An entry is a single share link or one proxy mapping, so this is generous
/// for the former and enough to identify the latter. The full body is never
/// retained: a 4000-line subscription would otherwise be copied into the
/// database on every refresh.
const int importRawLimit = 240;

/// Collapses [value] to one line and clips it to [max] characters.
///
/// Used for the `raw` field of [ImportIssue]. Line breaks and long runs of
/// spaces are folded because the point is to show the entry in a list, and a
/// YAML mapping printed with its original indentation is unreadable there.
String clipImportEntry(Object? value, [int max = importRawLimit]) {
  if (value == null) return '';
  final text = '$value'.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.length <= max) return text;
  return '${text.substring(0, max)}…';
}

class ImportIssue {
  const ImportIssue({
    required this.kind,
    required this.message,
    this.line,
    this.note,
    this.raw,
  });

  final ImportFailureKind kind;
  final String message;

  /// 1-based source line or entry index, when known.
  final int? line;

  /// Non-sensitive context (protocol name, scheme) for the preview list.
  final String? note;

  /// The rejected entry itself, clipped to [importRawLimit] characters.
  ///
  /// A message names the defect ("VMess 缺少 UUID") but not the entry it came
  /// from, which leaves a refresh reporting "1462 条不支持" with nothing to look
  /// at. The raw text is what makes that number answerable.
  final String? raw;

  /// Returns a copy carrying [value] as [raw] when it does not already have
  /// one. Populated by the importer loops, which are the only place that still
  /// has the source text; the per-entry parsers return issues without it.
  ImportIssue withRaw(Object? value) {
    if (raw != null && raw!.isNotEmpty) return this;
    final text = clipImportEntry(value);
    if (text.isEmpty) return this;
    return ImportIssue(
      kind: kind,
      message: message,
      line: line,
      note: note,
      raw: text,
    );
  }

  Map<String, Object?> toJson() => {
        'kind': kind.wire,
        'message': message,
        if (line != null) 'line': line,
        if (note != null) 'note': note,
        if (raw != null) 'raw': raw,
      };
}

class ImportResult {
  const ImportResult({
    this.nodes = const [],
    this.skipped = const [],
    this.failed = const [],
    this.sourceFormat = 'unknown',
  });

  final List<ProxyNode> nodes;

  /// Entries that were recognised but intentionally not imported (for
  /// example a rule-only entry in a full sing-box JSON document).
  final List<ImportIssue> skipped;

  /// Entries that could not be imported, each with a machine-readable kind.
  final List<ImportIssue> failed;
  final String sourceFormat;

  int get importedCount => nodes.length;
  int get skippedCount => skipped.length;
  int get failedCount => failed.length;
  bool get isEmpty => nodes.isEmpty;

  /// Failure counts keyed by [ImportFailureKind.wire].
  ///
  /// The window used to report one undifferentiated "N 条不支持", which is how
  /// 1462 rejected entries read as a protocol-support gap when 1300 of them
  /// were simply damaged lines. The breakdown is what lets the message say
  /// which of those two problems the user actually has.
  Map<String, int> get failureKinds {
    final counts = <String, int>{};
    for (final issue in failed) {
      counts.update(issue.kind.wire, (value) => value + 1, ifAbsent: () => 1);
    }
    return counts;
  }

  /// Skip counts keyed by [ImportFailureKind.wire].
  ///
  /// Skipped and failed are different answers to "why is this node missing":
  /// a skip means the entry was usable but not new (a duplicate inside this
  /// body), a failure means it was not usable. Reporting only the second one
  /// leaves a refresh that dropped 1580 duplicates looking like it lost 1580
  /// nodes.
  Map<String, int> get skippedKinds {
    final counts = <String, int>{};
    for (final issue in skipped) {
      counts.update(issue.kind.wire, (value) => value + 1, ifAbsent: () => 1);
    }
    return counts;
  }

  /// Entries skipped because the same node appears more than once.
  int get duplicateCount => skipped
      .where((issue) => issue.kind == ImportFailureKind.duplicate)
      .length;

  ImportResult merge(ImportResult other) => ImportResult(
        nodes: [...nodes, ...other.nodes],
        skipped: [...skipped, ...other.skipped],
        failed: [...failed, ...other.failed],
        sourceFormat: sourceFormat,
      );

  Map<String, Object?> toJson() => {
        'sourceFormat': sourceFormat,
        'imported': nodes.length,
        'skipped': skipped.map((e) => e.toJson()).toList(),
        'failed': failed.map((e) => e.toJson()).toList(),
      };
}
