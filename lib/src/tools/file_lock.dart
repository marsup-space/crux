// Per-file mutex that serializes critical sections (read-modify-write
// cycles) on a given path. Different paths are independent, so this
// does NOT serialize the whole process — concurrent edits to
// different files still run in parallel.
//
// Why this exists
// ---------------
//
// `EditTool` and `WriteTool` do a non-atomic read → mutate → write on
// the file's bytes. If two edits to the same file run concurrently,
// both read the original content, both compute their respective
// replacements on the original, and both write — only the last
// write survives. The earlier edits are silently lost, and partial
// writes can corrupt the file. Verified empirically by
// `test/edit_parallel_safety_test.dart`.
//
// The previous mitigation was that `chat_service.dart`'s tool-call
// dispatch loop is a sequential `for` + `await`, so production
// never hit the race. That coupling is load-bearing and fragile —
// if anyone "optimizes" the loop to `Future.wait`, user files
// start silently corrupting. Putting the lock at the tool layer
// closes the race at the source and lets the dispatch loop be
// safely parallelized in the future.
//
// Why a per-file lock (not a global lock)
// ----------------------------------------
//
// A single global mutex would serialize all file writes and defeat
// the purpose of running independent tool calls in parallel.
// Per-file locks keep the throughput of "edit A on foo.dart" and
// "edit B on bar.dart" running concurrently while making
// "edit A1 on foo.dart" and "edit A2 on foo.dart" see each other's
// writes in order.
//
// Implementation note
// -------------------
//
// Each lock is a Future chain: every call to `run` chains onto the
// tail of the chain and awaits the previous call. This is FIFO and
// gives N concurrent callers exactly N sequential executions in
// arrival order. No `package:synchronized` dep is needed — the
// pattern is small enough to inline.

import 'dart:async';

/// A per-path mutex. Acquire by calling [run]; the closure runs
/// only after any previously-submitted closure on the same path
/// has completed.
class FileLock {
  Future<void> _tail = Future.value();

  /// Run [criticalSection] under this lock. Returns whatever the
  /// section returns (or propagates its error). Concurrent calls on
  /// the same lock are serialized in FIFO order.
  Future<T> run<T>(Future<T> Function() criticalSection) {
    final completer = Completer<T>();
    final previous = _tail;
    _tail = previous.then((_) async {
      try {
        final result = await criticalSection();
        completer.complete(result);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }
}

/// Global registry of per-path locks. The same `FileLock` instance
/// is returned for a given path on every call, so successive
/// operations on that path chain onto the same tail.
final Map<String, FileLock> _locks = {};

/// Return the [FileLock] associated with [path], creating it on
/// first use. Path comparison is byte-exact; callers should resolve
/// to an absolute, normalized path before calling to avoid
/// `foo/bar` and `/cwd/foo/bar` getting different locks for the
/// same file.
FileLock fileLock(String path) => _locks.putIfAbsent(path, FileLock.new);
