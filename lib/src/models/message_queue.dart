/// A single message waiting in the per-session message queue.
///
/// When the agent is streaming (running an agentic loop with tool calls),
/// the user can still type new messages. These messages are queued and
/// inserted at the next safe boundary — after the agent finishes a
/// streaming content block (a final response or a tool-call round).
/// Each queued message can be individually discarded before it is
/// inserted.
class QueuedMessage {
  /// Unique identifier for this queued message, used for discard.
  final int id;

  /// The user's raw text.
  final String content;

  /// When this message was enqueued (for display ordering).
  final DateTime enqueuedAt;

  QueuedMessage({required this.id, required this.content, DateTime? enqueuedAt})
    : enqueuedAt = enqueuedAt ?? DateTime.now();
}

/// Per-session message queue. When the agent is streaming, new user
/// messages are enqueued here instead of being sent immediately. The
/// queue is drained at the next safe insertion point (after a tool
/// round completes, or after the final response). Multiple queued
/// messages are merged into a single user turn joined by blank
/// lines.
class MessageQueue {
  final int sessionId;
  final List<QueuedMessage> _messages = [];
  int _nextId = 0;

  MessageQueue({required this.sessionId});

  /// Enqueue a new user message and return its queue id.
  int enqueue(String content) {
    final id = _nextId++;
    _messages.add(QueuedMessage(id: id, content: content));
    return id;
  }

  /// Discard a queued message by its queue id. Returns true if found.
  bool discard(int id) {
    final idx = _messages.indexWhere((m) => m.id == id);
    if (idx < 0) return false;
    _messages.removeAt(idx);
    return true;
  }

  /// Read-only view of the current queue.
  List<QueuedMessage> get messages => List.unmodifiable(_messages);

  /// Whether there are any queued messages.
  bool get isNotEmpty => _messages.isNotEmpty;

  /// Whether there are no queued messages.
  bool get isEmpty => _messages.isEmpty;

  /// Number of queued messages.
  int get length => _messages.length;

  /// Drain the queue: merge all queued messages into a single user
  /// turn string. Multiple messages are joined with a blank line
  /// between them; a single message is returned verbatim. No
  /// synthetic prefix is added — the merged text is persisted as a
  /// user message and shown in the chat log, so it should read as
  /// exactly what the user typed. After draining, the queue is
  /// cleared.
  String drain() {
    if (_messages.isEmpty) return '';
    final contents = _messages.map((m) => m.content).toList();
    _messages.clear();
    return contents.join('\n\n');
  }

  /// Clear the entire queue without draining.
  void clear() {
    _messages.clear();
  }
}
