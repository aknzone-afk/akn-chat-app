import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/errors/failure.dart';
import '../../../../core/format/formatters.dart';
import '../../../../core/widgets/states.dart';
import '../../../chats/domain/chat.dart';
import '../../data/chat_actions.dart';

/// `updateChat.js` caps the name at 80 characters and strips control chars.
const int kMaxContactNameLength = 80;

/// Rename a contact. `chats/{waId}` is `allow write: if false`, so this goes
/// through the `updateChat` callable.
Future<void> showRenameSheet(
  BuildContext context,
  WidgetRef ref,
  Chat chat,
) async {
  final controller = TextEditingController(
    text: chat.hasCustomName ? chat.name : (chat.profileName ?? ''),
  );

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 4,
        bottom: MediaQuery.viewInsetsOf(sheetContext).bottom + 20,
      ),
      child: _RenameForm(chat: chat, controller: controller),
    ),
  );

  controller.dispose();
}

class _RenameForm extends ConsumerStatefulWidget {
  const _RenameForm({required this.chat, required this.controller});

  final Chat chat;
  final TextEditingController controller;

  @override
  ConsumerState<_RenameForm> createState() => _RenameFormState();
}

class _RenameFormState extends ConsumerState<_RenameForm> {
  bool _busy = false;
  String? _error;

  Future<void> _save() async {
    final name = widget.controller.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Naam khaali nahi ho sakta.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(chatActionsProvider).rename(widget.chat.waId, name);
      if (!mounted) return;
      Navigator.of(context).pop();
      showAknSnack(context, 'Naam badal diya');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = describeError(e).message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Contact ka naam',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          prettyPhone(widget.chat.customerWaId),
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: widget.controller,
          autofocus: true,
          enabled: !_busy,
          maxLength: kMaxContactNameLength,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            hintText: 'Jaise: Rakesh Bhai — Rajkot',
          ),
          onSubmitted: (_) => _save(),
        ),
        if (_error != null) ...[
          const SizedBox(height: 4),
          Text(
            _error!,
            style: TextStyle(fontSize: 13, color: scheme.error),
          ),
        ],
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: Colors.white,
                  ),
                )
              : const Text('Save karein'),
        ),
      ],
    );
  }
}
