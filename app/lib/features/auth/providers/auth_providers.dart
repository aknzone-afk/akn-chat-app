import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/failure.dart';
import '../../../core/firebase/firebase_providers.dart';
import '../../push/push_providers.dart';

/// What a `staff/{uid}` document holds. The app can `get` only its own row —
/// `list` is denied — so this is the only staff data the app ever sees.
class StaffProfile {
  const StaffProfile({
    required this.uid,
    required this.name,
    required this.email,
    this.owner = false,
  });

  final String uid;
  final String name;
  final String? email;

  /// Phase 5. `staff/{uid}.owner == true` is what `updateSettings` checks
  /// before it lets somebody rewrite the bot's persona or arm it for every
  /// customer at once. The app uses it only to hide controls that would be
  /// refused anyway — the real gate is server-side, in the callable.
  final bool owner;

  factory StaffProfile.fromDoc(DocumentSnapshot<Map<String, dynamic>> snap) {
    final d = snap.data() ?? const <String, dynamic>{};
    return StaffProfile(
      uid: snap.id,
      name: (d['name'] as String?)?.trim().isNotEmpty == true
          ? d['name'] as String
          : (d['email'] as String?) ?? 'Staff',
      email: d['email'] as String?,
      owner: d['owner'] == true,
    );
  }
}

enum SessionStatus {
  /// Firebase has not told us yet whether anyone is signed in.
  loading,
  signedOut,

  /// Signed in, but there is no `staff/{uid}` document — which the security
  /// rules require for literally every read. Without this state the app looks
  /// completely broken: it logs in fine and then every screen is empty.
  notStaff,
  ready,
}

class Session {
  const Session(this.status, {this.user, this.staff});

  final SessionStatus status;
  final User? user;
  final StaffProfile? staff;

  bool get isReady => status == SessionStatus.ready;
}

final authStateProvider = StreamProvider<User?>(
  (ref) => ref.watch(firebaseAuthProvider).authStateChanges(),
);

/// The caller's own staff row. `null` inside the AsyncValue means "signed in,
/// but not on the staff roster".
final staffProfileProvider = StreamProvider<StaffProfile?>((ref) {
  final user = ref.watch(authStateProvider).value;
  if (user == null) return Stream<StaffProfile?>.value(null);

  final db = ref.watch(firestoreProvider);
  return db
      .staffDoc(user.uid)
      .snapshots()
      .map((snap) => snap.exists ? StaffProfile.fromDoc(snap) : null);
}, retry: (_, _) => null);

/// The single source of truth the router guards on.
final sessionProvider = Provider<Session>((ref) {
  final auth = ref.watch(authStateProvider);

  if (auth.isLoading && !auth.hasValue) {
    return const Session(SessionStatus.loading);
  }
  final user = auth.value;
  if (user == null) return const Session(SessionStatus.signedOut);

  final staff = ref.watch(staffProfileProvider);
  if (staff.isLoading && !staff.hasValue) {
    return Session(SessionStatus.loading, user: user);
  }
  // A failed staff read (offline on a cold start) must not lock staff out of a
  // cache they can legitimately read. Treat it as "keep going" and let the
  // individual screens surface their own errors.
  if (staff.hasError) return Session(SessionStatus.ready, user: user);

  final profile = staff.value;
  if (profile == null) return Session(SessionStatus.notStaff, user: user);
  return Session(SessionStatus.ready, user: user, staff: profile);
});

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

class AuthActions {
  AuthActions(this._ref);

  final Ref _ref;

  Future<void> signIn({required String email, required String password}) async {
    final auth = _ref.read(firebaseAuthProvider);
    try {
      await auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
    } on FirebaseAuthException catch (e, st) {
      throw AppFailure(authMessage(e.code), code: e.code, cause: e, stackTrace: st);
    } catch (e, st) {
      throw AppFailure(
        'Sign in nahi ho paaya. Internet check karein.',
        code: 'unknown',
        cause: e,
        stackTrace: st,
      );
    }
  }

  /// Sign out — and take this phone off the push roster on the way.
  ///
  /// The order is not cosmetic. Removing the device's entry from
  /// `staff/{uid}.fcmTokens` needs the uid, and `firestore.rules` only lets a
  /// staff member write their OWN row — so it has to happen while they are
  /// still signed in. Skip it and the handset keeps receiving the previous
  /// user's customer messages, which on a shared warehouse phone is a real
  /// confidentiality problem.
  ///
  /// Best effort: a failed deregistration must never trap somebody in a session
  /// they are trying to leave.
  Future<void> signOut() async {
    try {
      await _ref.read(pushServiceProvider).deregister();
    } catch (_) {
      // Deliberately swallowed — see above.
    }
    await _ref.read(firebaseAuthProvider).signOut();
  }

  Future<void> sendPasswordReset(String email) async {
    try {
      await _ref
          .read(firebaseAuthProvider)
          .sendPasswordResetEmail(email: email.trim());
    } on FirebaseAuthException catch (e, st) {
      throw AppFailure(authMessage(e.code), code: e.code, cause: e, stackTrace: st);
    }
  }

  /// "This phone was alive at …". One of exactly two fields the rules let a
  /// staff member write on their own row.
  Future<void> touchLastSeen() async {
    final user = _ref.read(firebaseAuthProvider).currentUser;
    if (user == null) return;
    await _ref
        .read(firestoreProvider)
        .staffDoc(user.uid)
        .update({'lastSeenAt': FieldValue.serverTimestamp()})
        .catchError((_) {});
  }
}

final authActionsProvider = Provider<AuthActions>(AuthActions.new);
