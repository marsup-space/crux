abstract interface class SessionRuntimeSink {
  int get sessionId;

  void resetMetrics({
    int? turnBaseTokens,
    int? accumulatedToolTokens,
    int? targetTokens,
  });

  void beginResponse({DateTime? now, bool btwMode = false});

  void beginModelRound({DateTime? now});

  void recordContentStarted(DateTime now);

  void recordFirstToken(DateTime now);

  void recordRoundFirstToken(DateTime now);

  void addCompletionTokens(int estimatedTokens);

  void finishModelRound({DateTime? now, bool accumulateGeneration = false});

  void finishResponse({bool interrupted = false});

  void updateContext({
    int? turnBaseTokens,
    int? accumulatedToolTokens,
    int? targetTokens,
  });

  void recordCacheHitPct({required int hitTokens, required int missTokens});
}
