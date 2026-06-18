/// Live credit balance snapshot from a provider's balance API.
///
/// The DeepSeek `/user/balance` endpoint returns an
/// `is_available` flag and an array of per-currency balance rows.
/// Each row has `currency`, `total_balance`, `granted_balance`,
/// and `topped_up_balance` (all strings representing decimal
/// amounts).
class CreditBalance {
  /// Provider name this snapshot is for (e.g. `"deepseek"`).
  final String providerName;

  /// Whether the user's balance is sufficient for API calls.
  final bool isAvailable;

  /// Per-currency balance entries. Typically one entry (CNY or
  /// USD).
  final List<BalanceInfo> balanceInfos;

  /// When this snapshot was fetched.
  final DateTime fetchedAt;

  const CreditBalance({
    required this.providerName,
    required this.isAvailable,
    required this.balanceInfos,
    required this.fetchedAt,
  });

  /// The primary balance info to display. Prefers CNY, falls
  /// back to the first entry.
  BalanceInfo? get primaryBalance {
    if (balanceInfos.isEmpty) return null;
    for (final b in balanceInfos) {
      if (b.currency == 'CNY') return b;
    }
    return balanceInfos.first;
  }

  /// Short display string for the toolbar, e.g. `"¥110.00"`.
  String? formatPrimary() {
    final b = primaryBalance;
    if (b == null) return null;
    return '${b.symbol}${b.totalBalance}';
  }

  @override
  String toString() =>
      'CreditBalance($providerName: available=$isAvailable, '
      '${balanceInfos.map((b) => '${b.currency}=${b.totalBalance}').join(', ')})';
}

/// A single currency row from the balance response.
class BalanceInfo {
  /// Currency code: `"CNY"` or `"USD"`.
  final String currency;

  /// The total available balance, including the granted balance
  /// and the topped-up balance.
  final String totalBalance;

  /// The total not expired granted balance.
  final String grantedBalance;

  /// The total topped-up balance.
  final String toppedUpBalance;

  const BalanceInfo({
    required this.currency,
    required this.totalBalance,
    required this.grantedBalance,
    required this.toppedUpBalance,
  });

  /// Currency symbol for display: `¥` for CNY, `$` for USD,
  /// else the raw currency code.
  String get symbol {
    switch (currency) {
      case 'CNY':
        return '¥';
      case 'USD':
        return '\$';
      default:
        return currency;
    }
  }
}

/// Reason a credit balance fetch couldn't succeed.
enum CreditBalanceErrorKind {
  /// No API key is set for the provider.
  noApiKey,

  /// The HTTP call failed (timeout, connection refused,
  /// non-2xx, etc.).
  network,

  /// The response couldn't be parsed.
  parse,
}

class CreditBalanceError {
  final CreditBalanceErrorKind kind;
  final String message;

  const CreditBalanceError(this.kind, this.message);

  @override
  String toString() => 'CreditBalanceError(${kind.name}: $message)';
}
