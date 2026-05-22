// Platform-agnostic re-export. The actual implementation is picked at
// compile time via conditional imports below.
export 'unsupported.dart'
    if (dart.library.io) 'native.dart'
    if (dart.library.js_interop) 'web.dart';
