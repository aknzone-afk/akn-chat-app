import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
// `ProviderException` is exported from `misc.dart`, not from the main barrel.
import 'package:flutter_riverpod/misc.dart';

/// One error type for the whole app, carrying a message that is already fit to
/// put in front of staff — in Hinglish, and never a raw Firebase string.
class AppFailure implements Exception {
  const AppFailure(this.message, {this.code, this.cause, this.stackTrace});

  /// Ready to display. Hinglish.
  final String message;

  /// The machine code, for logs and for `switch`ing on at the call site.
  final String? code;

  final Object? cause;
  final StackTrace? stackTrace;

  /// True when tapping "try again" is a sensible thing to offer.
  bool get isRetryable => const {
    'unavailable',
    'deadline-exceeded',
    'internal',
    'aborted',
    'cancelled',
    'resource-exhausted',
  }.contains(code);

  @override
  String toString() => 'AppFailure(${code ?? '-'}): $message';
}

/// Riverpod 3 rethrows **every** provider failure wrapped in a
/// [ProviderException], with the original at `.exception`. Code written against
/// Riverpod 2 — `.when(error: (e, _) { if (e is FirebaseException) ... })` —
/// now sees the wrapper, falls through to the generic arm, and every specific
/// message in the app quietly stops working. Nothing warns you. Unwrap first.
Object unwrapError(Object error) {
  var e = error;
  var guard = 0;
  while (e is ProviderException && guard++ < 8) {
    e = e.exception;
  }
  return e;
}

/// Normalises the three layers (callable / Firebase plugin / anything else)
/// into one [AppFailure].
Future<T> callGuarded<T>(Future<T> Function() op) async {
  try {
    return await op();
  } on FirebaseFunctionsException catch (e, st) {
    throw AppFailure(_fromCallable(e), code: e.code, cause: e, stackTrace: st);
  } on FirebaseAuthException catch (e, st) {
    throw AppFailure(authMessage(e.code), code: e.code, cause: e, stackTrace: st);
  } on FirebaseException catch (e, st) {
    throw AppFailure(
      _fromFirebase(e),
      code: e.code,
      cause: e,
      stackTrace: st,
    );
  } catch (e, st) {
    throw AppFailure(
      'Kuch gadbad ho gayi. Dobara koshish karein.',
      code: 'unknown',
      cause: e,
      stackTrace: st,
    );
  }
}

/// Turn any thrown object into an [AppFailure] for display, unwrapping
/// Riverpod's [ProviderException] on the way.
AppFailure describeError(Object error) {
  final e = unwrapError(error);
  if (e is AppFailure) return e;
  if (e is FirebaseFunctionsException) {
    return AppFailure(_fromCallable(e), code: e.code, cause: e);
  }
  if (e is FirebaseAuthException) {
    return AppFailure(authMessage(e.code), code: e.code, cause: e);
  }
  if (e is FirebaseException) {
    return AppFailure(_fromFirebase(e), code: e.code, cause: e);
  }
  return AppFailure('Kuch gadbad ho gayi.', code: 'unknown', cause: e);
}

// ---------------------------------------------------------------------------
// Callable errors
// ---------------------------------------------------------------------------

String _fromCallable(FirebaseFunctionsException e) {
  // The backend may hand us a ready-made user string in `details`.
  final detail = e.details;
  if (detail is Map && detail['userMessage'] is String) {
    return detail['userMessage'] as String;
  }

  // Backend-specific conditions. sendMessage.js encodes these in the message
  // body of the HttpsError, so we match on the body — never on `internal`,
  // whose message is scrubbed by the Functions runtime before it reaches us.
  final body = e.message ?? '';
  if (e.code == 'failed-precondition') {
    if (body.contains('WINDOW_CLOSED')) {
      return '24 ghante ka free window band ho gaya. '
          'Customer ke message ka intezaar karein.';
    }
    if (body.contains('access token')) {
      return 'WhatsApp ka token expire ho gaya. Owner ko turant batayein.';
    }
    if (body.contains('business number')) {
      return 'Is chat ka business number pata nahi chal raha. Owner ko batayein.';
    }
    if (body.contains('attachment') || body.contains('mediaPath')) {
      return 'File attach karne me dikkat aayi.';
    }
    return 'Ye abhi nahi ho sakta.';
  }

  // `permission-denied` reaches us from two completely different places.
  // assertStaff() means "you have no staff/{uid} document"; sendMessage.js's
  // claim transaction means "doc.senderStaffId !== staff.uid", i.e. one of the
  // other three phones wrote this draft. Telling a working staff member their
  // account has been deactivated because they tapped retry on a colleague's
  // stuck message is how a shop floor stops for an afternoon.
  if (e.code == 'permission-denied' && body.contains('Somebody else')) {
    return 'Ye draft doosre phone se likha gaya tha. Usi phone se dobara bhejein.';
  }

  // sendMessage.js returns not-found ("That message is gone") when the DRAFT
  // DOCUMENT is not on the server — a flaky link, not a bad number. Saying "this
  // number is not on WhatsApp" about a customer who wrote ten minutes ago sends
  // staff chasing the wrong problem.
  if (e.code == 'not-found' && body.contains('message')) {
    return 'Message abhi server tak nahi pahuncha. Network aane par dobara bhejein.';
  }

  return switch (e.code) {
    'unauthenticated' => 'Dobara sign in karein.',
    'permission-denied' =>
      'Aapka account AKN Chat ke liye set nahi hai. Owner se poochhein.',
    'not-found' => 'Ye number WhatsApp par nahi hai, ya chat mit gayi hai.',
    'resource-exhausted' => 'Bahut saare message. Thoda ruk kar bhejein.',
    'deadline-exceeded' ||
    'unavailable' => 'WhatsApp busy hai. Thodi der me dobara bhejein.',
    'invalid-argument' => 'Is message me kuch galat hai. Dobara type karein.',
    'cancelled' => 'Cancel ho gaya.',
    'already-exists' => 'Ye pehle hi ho chuka hai.',
    _ => 'Kuch gadbad ho gayi. (${e.code})',
  };
}

// ---------------------------------------------------------------------------
// Firestore / plugin errors
// ---------------------------------------------------------------------------

String _fromFirebase(FirebaseException e) => switch (e.code) {
  'permission-denied' =>
    'Aapko is chat ki permission nahi hai. Owner se poochhein.',
  'unavailable' => 'Internet nahi mil raha. Connection check karein.',
  'not-found' => 'Ye ab maujood nahi hai.',
  'unauthenticated' => 'Dobara sign in karein.',
  'deadline-exceeded' => 'Server der kar raha hai. Dobara koshish karein.',
  _ => 'Kuch gadbad ho gayi. (${e.code})',
};

// ---------------------------------------------------------------------------
// Auth errors — the login screen's whole vocabulary
// ---------------------------------------------------------------------------

String authMessage(String code) => switch (code) {
  'invalid-email' => 'Email galat likha hai.',
  'user-disabled' => 'Ye account band kar diya gaya hai. Owner se baat karein.',
  'user-not-found' ||
  'wrong-password' ||
  'invalid-credential' => 'Email ya password galat hai.',
  'too-many-requests' =>
    'Bahut baar galat koshish. 5 minute ruk kar dobara karein.',
  'network-request-failed' => 'Internet nahi mil raha. Connection check karein.',
  'operation-not-allowed' =>
    'Email login band hai. Owner ko Firebase console check karne ko kahein.',
  'missing-password' => 'Password likhein.',
  _ => 'Sign in nahi ho paaya. ($code)',
};
