import 'package:nocterm/nocterm.dart';

import '../../i18n/strings.dart';
import '../../theme/crux_theme.dart';
import '../../utils/token_format.dart';
import '../ui/button.dart';
import '../ui/glossy_model_button.dart';
import '../ui/layout_metrics.dart';
import 'subagent_ui_models.dart';

/// Current-conversation Subagent chips for placement above the chat toolbar.
///
/// The list is already scoped by the host to this conversation. The row knows
/// nothing about the workspace-wide pool and does not remove idle entries: the
/// host does that at the next agent-turn boundary described by the product
/// contract.
class SubagentToolbarRow extends StatefulComponent {
  final List<SubagentUiEntry> entries;
  final ValueChanged<SubagentUiEntry> onOpen;
  final String prefix;
  final Strings strings;

  const SubagentToolbarRow({
    super.key,
    required this.entries,
    required this.onOpen,
    this.prefix = 'Workers:',
    this.strings = kEnglishStrings,
  });

  @override
  State<SubagentToolbarRow> createState() => _SubagentToolbarRowState();
}

class _SubagentToolbarRowState extends State<SubagentToolbarRow> {
  int _focus = 0;

  bool _handleKey(KeyboardEvent event, int actions) {
    if (actions == 0) return false;
    if (event.logicalKey == LogicalKey.arrowLeft ||
        (event.logicalKey == LogicalKey.tab && event.isShiftPressed)) {
      setState(() => _focus = (_focus - 1 + actions) % actions);
      return true;
    }
    if (event.logicalKey == LogicalKey.arrowRight ||
        event.logicalKey == LogicalKey.tab) {
      setState(() => _focus = (_focus + 1) % actions);
      return true;
    }
    if (event.logicalKey == LogicalKey.enter ||
        event.logicalKey == LogicalKey.numpadEnter) {
      component.onOpen(component.entries[_focus]);
      return true;
    }
    return false;
  }

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final actions = component.entries.length;
    if (actions == 0) {
      _focus = 0;
    } else if (_focus < 0 || _focus >= actions) {
      _focus = 0;
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: kContentHorizontalPadding,
      ),
      child: Focusable(
        disabled: actions == 0,
        onKeyEvent: (event) => _handleKey(event, actions),
        // Keep the prefix and Worker chips in one left-to-right flow. Wrap
        // starts another run only after the available toolbar width is used.
        //
        // The Builder reads the Focusable's own focus state from *inside*
        // the subtree: `_focus == index` alone marked the first idle chip
        // focused even when this row held no keyboard focus at all, which
        // painted it with the focus highlight while every other idle chip
        // stayed gray. Gating on the real focus keeps the keyboard
        // navigation design and removes the phantom idle highlight.
        child: Builder(
          builder: (context) {
            final rowHasFocus = Focus.of(context);
            return Wrap(
              spacing: 1,
              runSpacing: 0,
              children: [
                Text(
                  component.prefix,
                  style: TextStyle(color: theme.onSurfaceDim),
                ),
                for (var index = 0; index < component.entries.length; index++)
                  // A queued Worker is still in flight. With per-model
                  // concurrency, the first Worker commonly runs while the
                  // rest wait for a slot; animating only `busy` made those
                  // later chips look idle, which appeared as though only
                  // the first chip animated.
                  //
                  // The tooltip carries up to six lines (domain, intent,
                  // model, context, status) plus wrap headroom, so the
                  // intent line must not silently ellipsize away.
                  Hinted(
                    hint: _hint(component.entries[index]),
                    delay: Duration.zero,
                    maxLines: 6,
                    child: component.entries[index].status.isInFlight
                        // Keep the animation state attached to this Worker
                        // rather than its current position in the list.
                        // In-flight Workers may be inserted, removed, or
                        // reordered while the toolbar rebuilds, so a stable
                        // key prevents a ticker/state from being reused for
                        // a different Worker.
                        ? GlossyModelButton(
                            key: ValueKey(component.entries[index].id),
                            label: _label(component.entries[index]),
                            isAnimating: true,
                            compact: true,
                            onPressed: () =>
                                component.onOpen(component.entries[index]),
                          )
                        : Button(
                            key: ValueKey(component.entries[index].id),
                            label: _label(component.entries[index]),
                            onPressed: () =>
                                component.onOpen(component.entries[index]),
                            focused: rowHasFocus && _focus == index,
                            color: theme.onSurfaceVariant,
                            padding: const EdgeInsets.symmetric(horizontal: 1),
                          ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  static String _label(SubagentUiEntry entry) => entry.name;

  String _hint(SubagentUiEntry entry) {
    final strings = component.strings;
    final status = switch (entry.status) {
      SubagentUiStatus.ready => strings.t('subagent.tooltip.statusReady'),
      SubagentUiStatus.queued => strings.t('subagent.tooltip.statusQueued'),
      SubagentUiStatus.busy => strings.t('subagent.tooltip.statusBusy'),
    };
    final usage = entry.contextUsage;
    final context = usage == null
        ? strings.t('subagent.tooltip.contextUnavailable')
        : strings.t('subagent.tooltip.context', {
            'used': formatTokensCompact(usage.usedTokens),
            'capacity': formatTokensCompact(usage.capacityTokens),
            'percent': '${usage.percent}',
          });
    // The intent line names the commander's stated purpose recorded on the
    // CURRENT assignment — never the task text. An idle Worker that still
    // exposes its terminal assignment must not pass old intent off as
    // current work, so its line is explicitly labelled "(previous task)".
    // A Worker with no recorded intent (never dispatched, or a pre-v38 row)
    // hides the line entirely rather than inventing one.
    final intent = entry.assignmentIntent;
    final intentLine = intent == null || intent.isEmpty
        ? null
        : entry.status == SubagentUiStatus.ready
        ? strings.t('subagent.tooltip.statusIdleLastIntent', {'intent': intent})
        : strings.t('subagent.tooltip.intent', {'intent': intent});
    // The model line always names the entry's model: an idle Worker keeps
    // its previous assignment's active model, which the dispatcher sticks
    // to on re-dispatch (provider caches are per model). Only a Worker
    // that has never run anything shows the unassigned line.
    return [
      strings.t('subagent.tooltip.domain', {'domain': entry.domain}),
      ?intentLine,
      strings.t('subagent.tooltip.model', {'model': entry.model}),
      context,
      status,
    ].join('\n');
  }
}
