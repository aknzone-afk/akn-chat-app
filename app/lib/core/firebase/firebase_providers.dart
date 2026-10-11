import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Every Cloud Function in this project is deployed to Mumbai.
///
/// Getting this wrong is the single most common cause of a `not-found` on a
/// callable that clearly exists: `FirebaseFunctions.instance` silently means
/// `us-central1`, where nothing of ours is deployed.
const String kFunctionsRegion = 'asia-south1';

final firebaseAuthProvider = Provider<FirebaseAuth>(
  (ref) => FirebaseAuth.instance,
);

final firestoreProvider = Provider<FirebaseFirestore>(
  (ref) => FirebaseFirestore.instance,
);

final functionsProvider = Provider<FirebaseFunctions>(
  (ref) => FirebaseFunctions.instanceFor(region: kFunctionsRegion),
);

/// Firestore collection/field names, in one place, spelled the way the backend
/// spells them. See functions/README.md → "The data model".
abstract final class Db {
  static const chats = 'chats';
  static const messages = 'messages';
  static const staff = 'staff';
  static const settings = 'settings';
  static const settingsDocId = 'app';
}

extension FirestorePaths on FirebaseFirestore {
  DocumentReference<Map<String, dynamic>> chatDoc(String waId) =>
      collection(Db.chats).doc(waId);

  CollectionReference<Map<String, dynamic>> messagesOf(String waId) =>
      collection(Db.chats).doc(waId).collection(Db.messages);

  DocumentReference<Map<String, dynamic>> get appSettingsDoc =>
      collection(Db.settings).doc(Db.settingsDocId);

  DocumentReference<Map<String, dynamic>> staffDoc(String uid) =>
      collection(Db.staff).doc(uid);
}
