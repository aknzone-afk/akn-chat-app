import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/failure.dart';
import '../../../core/firebase/firebase_providers.dart';

/// The only write path into any Phase 6 collection.
///
/// `firestore.rules` keeps the whole Tally block `allow write: if false` for
/// every client, and every one of these goes through the `tallyAdmin`
/// callable, which re-validates against a whitelist and refuses anything not
/// on it.
///
/// ⚠️ The money actions — approve, cancel, kill switch, mode — additionally
/// require `staff/{uid}.owner == true`, checked on the SERVER. The app only
/// hides the controls so nobody taps something that would be refused.
class TallyActions {
  TallyActions(this._ref);

  final Ref _ref;

  FirebaseFunctions get _functions => _ref.read(functionsProvider);

  Future<Map<String, dynamic>> _call(String action, [Map<String, Object?> args = const {}]) async {
    final result = await callGuarded(
      () => _functions
          .httpsCallable(
            'tallyAdmin',
            options: HttpsCallableOptions(timeout: const Duration(seconds: 60)),
          )
          .call<Map<String, dynamic>?>({'action': action, ...args}),
    );
    return result.data ?? const {};
  }

  // --- the approval ------------------------------------------------------

  /// One tap for the whole batch, not one per customer.
  ///
  /// `acknowledgedWarnings` is not decoration: the server refuses the approval
  /// unless it is true when there are warnings. A warning nobody read is not a
  /// warning.
  Future<Map<String, dynamic>> approveRun({
    required String runId,
    required List<String> excludedPartyGuids,
    required bool acknowledgedWarnings,
  }) => _call('approveRun', {
    'runId': runId,
    'excludedPartyGuids': excludedPartyGuids,
    'acknowledgedWarnings': acknowledgedWarnings,
  });

  Future<void> cancelRun(String runId, {String? reason}) =>
      _call('cancelRun', {'runId': runId, 'reason': reason});

  /// Taking one party OFF a batch is deliberately NOT owner-only. Removing a
  /// message is always the safe direction.
  Future<void> excludeParty({
    required String runId,
    required String partyGuid,
    bool exclude = true,
  }) => _call('excludeParty', {'runId': runId, 'partyGuid': partyGuid, 'exclude': exclude});

  // --- the mobile mapping ------------------------------------------------

  /// Fixes AMBIGUOUS_MULTIPLE, MALFORMED and MISSING.
  ///
  /// Keyed on the ledger GUID, never the name — names get edited in Tally and
  /// a rename would silently orphan the override, putting the party back on the
  /// ledger's own wrong number with nobody noticing.
  ///
  /// The server refuses a number that is already on another ledger.
  Future<void> setPartyMobile({
    required String ledgerGuid,
    required String mobile,
    String? reason,
  }) => _call('setPartyMobile', {'ledgerGuid': ledgerGuid, 'mobile': mobile, 'reason': reason});

  Future<void> setDoNotSend({
    required String ledgerGuid,
    required bool doNotSend,
    String? reason,
  }) => _call('setDoNotSend', {'ledgerGuid': ledgerGuid, 'doNotSend': doNotSend, 'reason': reason});

  /// The one-tap fix for NO_CHAT_YET.
  Future<void> whitelistParty(String waId) => _call('whitelistParty', {'waId': waId});

  // --- the switches ------------------------------------------------------

  /// Immediate, needs no deploy, needs no bridge, and works even if the shop PC
  /// has been unplugged mid-batch. An approved run stops where it is;
  /// already-sent parties stay sent; the rest resume when it is cleared.
  Future<void> setKillSwitch(bool on) => _call('killSwitch', {'on': on});

  /// Any field left null is left alone on the server — only what is passed is
  /// written. Passing an EMPTY STRING for [rehearsalTo] clears it, which is how
  /// "Band kijiye" turns rehearsal off.
  Future<void> setMode({String? billMode, String? biltyMode, bool? dryRun, String? rehearsalTo}) {
    final args = <String, Object?>{};
    if (billMode != null) args['billMode'] = billMode;
    if (biltyMode != null) args['biltyMode'] = biltyMode;
    if (dryRun != null) args['dryRun'] = dryRun;
    if (rehearsalTo != null) args['rehearsalTo'] = rehearsalTo.isEmpty ? null : rehearsalTo;
    return _call('setMode', args);
  }

  Future<void> runNow() => _call('runNow');
  Future<void> refreshLedgers() => _call('refreshLedgers');
}

final tallyActionsProvider = Provider<TallyActions>(TallyActions.new);
