/// `dart:io`-backed extras for cachemesh (Dart VM, Flutter mobile/desktop).
///
/// Import this **in addition to** `package:cachemesh/cachemesh.dart` when you
/// need file-based persistence. Kept separate so the core library never pulls
/// in `dart:io` and stays web-compatible.
library;

export 'src/json_file_store.dart';
