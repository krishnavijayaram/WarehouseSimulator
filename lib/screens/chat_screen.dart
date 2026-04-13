/// chat_screen.dart — AI conversational interface to the warehouse state.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../core/auth/auth_provider.dart';
import '../core/api_client.dart';
import '../widgets/connection_banner.dart';

// ── Providers ─────────────────────────────────────────────────────────────────

final _chatSessionIdProvider = StateProvider<String?>((ref) => null);
final _messagesProvider      = StateProvider<List<_ChatMessage>>((ref) => []);

@immutable
class _ChatMessage {
  const _ChatMessage({required this.role, required this.content, required this.ts});
  final String   role;    // 'user' | 'assistant'
  final String   content;
  final DateTime ts;
}

// ── Quick-prompt chips ────────────────────────────────────────────────────────

const _kQuickPrompts = [
  'How many robots are active?',
  'What is the current efficiency?',
  'Any conflicts going on?',
  'Show me pending orders',
  'Self-healing history',
];

// ── Screen ────────────────────────────────────────────────────────────────────

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _inputCtrl   = TextEditingController();
  final _scrollCtrl  = ScrollController();
  bool  _sending     = false;
  bool  _initialised = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureSession());
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  // ── Session management ───────────────────────────────────────────────────

  Future<void> _ensureSession() async {
    final existing = ref.read(_chatSessionIdProvider);
    if (existing != null) { setState(() => _initialised = true); return; }

    final auth = ref.read(authProvider);
    if (auth is! AuthLoggedIn) return;

    try {
      final id = await ApiClient.instance.createChatSession(auth.token);
      ref.read(_chatSessionIdProvider.notifier).state = id;
      if (mounted) setState(() => _initialised = true);
    } catch (e) {
      if (mounted) _showSnack('Could not start chat session: $e');
    }
  }

  // ── Send message ──────────────────────────────────────────────────────────

  Future<void> _send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _sending) return;

    final sessionId = ref.read(_chatSessionIdProvider);
    if (sessionId == null) { await _ensureSession(); return; }

    _inputCtrl.clear();
    _addMessage('user', trimmed);
    setState(() => _sending = true);

    try {
      final reply = await ApiClient.instance.sendChatMessage(
        sessionId: sessionId,
        message:   trimmed,
      );
      _addMessage('assistant', reply);
    } catch (e) {
      _addMessage('assistant', '⚠ Error: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
    _scrollToBottom();
  }

  void _addMessage(String role, String content) {
    final msgs = List<_ChatMessage>.from(ref.read(_messagesProvider));
    msgs.add(_ChatMessage(role: role, content: content, ts: DateTime.now()));
    ref.read(_messagesProvider.notifier).state = msgs;
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: const Color(0xFF4A1515)),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(_messagesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI CHAT'),
        actions: [
          // Clear conversation
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 18),
            tooltip: 'Clear',
            onPressed: () {
              ref.read(_messagesProvider.notifier).state = [];
              ref.read(_chatSessionIdProvider.notifier).state = null;
              _initialised = false;
              _ensureSession();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          const ConnectionBanner(),

          // ── WIP notice ───────────────────────────────────────────────────
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            color: const Color(0xFF0F2010),
            child: Row(
              children: [
                const Text('🚧', style: TextStyle(fontSize: 13)),
                const SizedBox(width: 8),
                const Text(
                  'Work in Progress — AI responses may be incomplete.',
                  style: TextStyle(
                    fontSize: 11,
                    color: Color(0xFF4ADE80),
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),

          // ── Message list ─────────────────────────────────────────────────
          Expanded(
            child: !_initialised
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF00D4FF)))
                : messages.isEmpty
                    ? _EmptyState(onChipTap: _send)
                    : ListView.builder(
                        controller: _scrollCtrl,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        itemCount: messages.length,
                        itemBuilder: (_, i) => _BubbleTile(messages[i]),
                      ),
          ),

          // ── Quick-prompt chips (only when no messages) ───────────────────
          if (messages.isNotEmpty)
            _QuickChips(onTap: _send),

          // ── Input bar ────────────────────────────────────────────────────
          _InputBar(
            ctrl:     _inputCtrl,
            sending:  _sending,
            onSend:   _send,
          ),
        ],
      ),
    );
  }
}

// ── Bubble ────────────────────────────────────────────────────────────────────

class _BubbleTile extends StatelessWidget {
  const _BubbleTile(this.msg);
  final _ChatMessage msg;

  bool get _isUser => msg.role == 'user';

  @override
  Widget build(BuildContext context) {
    final timeStr = DateFormat('HH:mm').format(msg.ts);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment:
            _isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!_isUser) ...[
            const CircleAvatar(
              radius: 14,
              backgroundColor: Color(0xFF00D4FF),
              child: Text('AI', style: TextStyle(fontSize: 8, color: Color(0xFF0D1117))),
            ),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment:
                  _isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: _isUser
                        ? const Color(0xFF00D4FF).withAlpha(30)
                        : const Color(0xFF161B22),
                    borderRadius: BorderRadius.only(
                      topLeft:     Radius.circular(_isUser ? 12 : 2),
                      topRight:    Radius.circular(_isUser ? 2  : 12),
                      bottomLeft:  const Radius.circular(12),
                      bottomRight: const Radius.circular(12),
                    ),
                    border: Border.all(
                      color: _isUser
                          ? const Color(0xFF00D4FF).withAlpha(60)
                          : const Color(0xFF30363D),
                    ),
                  ),
                  child: Text(
                    msg.content,
                    style: TextStyle(
                      fontSize: 13,
                      color: _isUser
                          ? const Color(0xFFE6EDF3)
                          : const Color(0xFFC9D1D9),
                      height: 1.45,
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  timeStr,
                  style: const TextStyle(fontSize: 8, color: Color(0xFF484F58)),
                ),
              ],
            ),
          ),
          if (_isUser) ...[
            const SizedBox(width: 6),
            const CircleAvatar(
              radius: 14,
              backgroundColor: Color(0xFF21262D),
              child: Icon(Icons.person, size: 14, color: Color(0xFF8B949E)),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Quick-prompt chips ────────────────────────────────────────────────────────

class _QuickChips extends StatelessWidget {
  const _QuickChips({required this.onTap});
  final void Function(String) onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 36,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      children: _kQuickPrompts.map((p) => Padding(
        padding: const EdgeInsets.only(right: 6),
        child: ActionChip(
          label: Text(p, style: const TextStyle(fontSize: 10, fontFamily: 'ShareTechMono')),
          backgroundColor: const Color(0xFF161B22),
          side: const BorderSide(color: Color(0xFF30363D)),
          onPressed: () => onTap(p),
          padding: const EdgeInsets.all(0),
        ),
      )).toList(),
    ),
  );
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onChipTap});
  final void Function(String) onChipTap;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      const Text('🤖', style: TextStyle(fontSize: 48)),
      const SizedBox(height: 12),
      const Text(
        'Ask me about the warehouse',
        style: TextStyle(color: Color(0xFF8B949E), fontSize: 14),
      ),
      const SizedBox(height: 20),
      Wrap(
        spacing: 8, runSpacing: 8,
        alignment: WrapAlignment.center,
        children: _kQuickPrompts.map((p) => ActionChip(
          label: Text(p, style: const TextStyle(fontSize: 10, fontFamily: 'ShareTechMono')),
          backgroundColor: const Color(0xFF161B22),
          side: const BorderSide(color: Color(0xFF30363D)),
          onPressed: () => onChipTap(p),
        )).toList(),
      ),
    ],
  );
}

// ── Input bar ─────────────────────────────────────────────────────────────────

class _InputBar extends StatelessWidget {
  const _InputBar({required this.ctrl, required this.sending, required this.onSend});
  final TextEditingController ctrl;
  final bool   sending;
  final void Function(String) onSend;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        color: Color(0xFF161B22),
        border: Border(top: BorderSide(color: Color(0xFF30363D))),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: ctrl,
              enabled: !sending,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                hintText:      'Type a question…',
                hintStyle:     TextStyle(color: Color(0xFF484F58)),
                border:        OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(8)),
                  borderSide:   BorderSide(color: Color(0xFF30363D)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(8)),
                  borderSide:   BorderSide(color: Color(0xFF30363D)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(8)),
                  borderSide:   BorderSide(color: Color(0xFF00D4FF)),
                ),
                contentPadding:  EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              onSubmitted: onSend,
              maxLines: 3,
              minLines: 1,
            ),
          ),
          const SizedBox(width: 8),
          sending
              ? const SizedBox(
                  width: 40, height: 40,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFF00D4FF),
                  ),
                )
              : IconButton.filled(
                  onPressed: () => onSend(ctrl.text),
                  icon: const Icon(Icons.send, size: 18),
                  style: IconButton.styleFrom(
                    backgroundColor: const Color(0xFF00D4FF).withAlpha(200),
                    foregroundColor: const Color(0xFF0D1117),
                  ),
                ),
        ],
      ),
    ),
  );
}
