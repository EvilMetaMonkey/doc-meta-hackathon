/// "1 file", "2 files": a count with its noun in the right number. [many]
/// is the plural when it is not [one] + "s" ("1 entry", "2 entries").
String plural(int count, String one, [String? many]) =>
    '$count ${count == 1 ? one : many ?? '${one}s'}';
