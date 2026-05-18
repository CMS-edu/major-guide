import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
        return web;
      case TargetPlatform.fuchsia:
        throw UnsupportedError('Firebase is not configured for Fuchsia.');
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyCxqhO7F_6806rtHwfgDfdkmI0KIkmZML4',
    authDomain: 'major-guide-b7e5e.firebaseapp.com',
    projectId: 'major-guide-b7e5e',
    storageBucket: 'major-guide-b7e5e.firebasestorage.app',
    messagingSenderId: '915421685647',
    appId: '1:915421685647:web:762579cd91f09464f68dfa',
  );
}
