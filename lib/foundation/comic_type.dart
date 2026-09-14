import 'package:venera_netmatic/foundation/comic_source/comic_source.dart';

class ComicType {
  final int value;

  const ComicType(this.value);

  @override
  bool operator ==(Object other) => other is ComicType && other.value == value;

  @override
  int get hashCode => value.hashCode;

  String get sourceKey {
    if (this == local) {
      return "local";
    } else {
      // A comic can be restored from a NAS (or an older backup) before its
      // source script has been installed on this device.  Keep the type
      // addressable instead of throwing from the non-null assertion; callers
      // that need source functionality can still check [comicSource].
      return comicSource?.key ?? "Unknown:$value";
    }
  }

  ComicSource? get comicSource {
    if (this == local) {
      return null;
    } else {
      return ComicSource.fromIntKey(value);
    }
  }

  static const local = ComicType(0);

  factory ComicType.fromKey(String key) {
    if (key == "local") {
      return local;
    } else {
      return ComicType(key.hashCode);
    }
  }
}
