import 'package:nocterm/nocterm.dart';

import '../i18n/strings.dart';
import 'command_overlay.dart';
import 'file_browser_overlay.dart';
import 'overlay_controller.dart';
import 'session_mention_overlay.dart';
import 'skill_picker_overlay.dart';
import 'suggestion_overlay.dart';

/// Builds the overlay popover for the chat input's current
/// [OverlayController] state, or `null` when no popover should show.
///
/// Shared by the chat panel (which pins it absolutely above the
/// toolbar) and the home screen (which renders it inline above the
/// quick-chat input), so the command palette / file browser / skill
/// picker / session mention picker can never drift apart.
///
/// [refresh] is called after every mutation so the caller rebuilds.
/// Mutations that have side effects (e.g. [OverlayController.onTapCommand]
/// executing a command) run *before* [refresh], matching the chat
/// panel's original ordering.
Component? buildOverlayPopover({
  required OverlayController overlay,
  required int maxVisible,
  required Strings strings,
  required VoidCallback refresh,
}) {
  if (overlay.overlayMode == OverlayMode.command &&
      overlay.filteredCommands.isNotEmpty) {
    return MouseRegion(
      onHover: (e) {
        overlay.onScrollCommand(e);
        refresh();
      },
      opaque: false,
      child: CommandOverlay(
        commands: overlay.filteredCommands,
        selectedIndex: overlay.selectedCommandIndex,
        scrollOffset: overlay.commandScrollOffset,
        maxVisible: maxVisible,
        strings: strings,
        onHover: (i) {
          overlay.onHoverCommand(i);
          refresh();
        },
        onTap: (i) {
          overlay.onTapCommand(i);
          refresh();
        },
      ),
    );
  }

  if (overlay.overlayMode == OverlayMode.parameter &&
      overlay.filteredSuggestions.isNotEmpty) {
    final paramLabel = overlay.currentParamIndex <
            overlay.activeCommand!.params.length
        ? overlay.activeCommand!.params[overlay.currentParamIndex]
        : 'value';
    return MouseRegion(
      onHover: (e) {
        overlay.onScrollSuggestion(e);
        refresh();
      },
      opaque: false,
      child: SuggestionOverlay(
        suggestions: overlay.filteredSuggestions,
        selectedIndex: overlay.selectedSuggestionIndex,
        scrollOffset: overlay.suggestionScrollOffset,
        maxVisible: maxVisible,
        headerLabel: paramLabel,
        strings: strings,
        onHover: (i) {
          overlay.onHoverSuggestion(i);
          refresh();
        },
        onTap: (i) {
          overlay.onTapSuggestion(i);
          refresh();
        },
      ),
    );
  }

  if (overlay.overlayMode == OverlayMode.atMention) {
    return MouseRegion(
      onHover: (e) {
        overlay.onScrollFile(e);
        refresh();
      },
      opaque: false,
      child: FileBrowserOverlay(
        files: overlay.filteredFiles,
        selectedIndex: overlay.selectedFileIndex,
        scrollOffset: overlay.fileScrollOffset,
        maxVisible: maxVisible,
        query: overlay.atMentionQuery,
        isSearching: overlay.isSearching,
        onHover: (i) {
          overlay.onHoverFile(i);
          refresh();
        },
        onTap: (i) {
          overlay.selectedFileIndex = i;
          overlay.insertAtMention(null);
          refresh();
        },
      ),
    );
  }

  if (overlay.overlayMode == OverlayMode.skillPicker) {
    return MouseRegion(
      onHover: (e) {
        overlay.onScrollSkill(e);
        refresh();
      },
      opaque: false,
      child: SkillPickerOverlay(
        skills: overlay.filteredSkills,
        selectedIndex: overlay.selectedSkillIndex,
        scrollOffset: overlay.skillScrollOffset,
        maxVisible: maxVisible,
        query: overlay.skillChipQuery,
        onHover: (i) {
          overlay.onHoverSkill(i);
          refresh();
        },
        onTap: (i) {
          overlay.selectedSkillIndex = i;
          overlay.insertSkillChip(null);
          refresh();
        },
      ),
    );
  }

  if (overlay.overlayMode == OverlayMode.sessionMention) {
    return MouseRegion(
      onHover: (e) {
        overlay.onScrollSessionMention(e);
        refresh();
      },
      opaque: false,
      child: SessionMentionOverlay(
        mentions: overlay.filteredSessionMentions,
        selectedIndex: overlay.selectedSessionMentionIndex,
        scrollOffset: overlay.sessionMentionScrollOffset,
        maxVisible: maxVisible,
        strings: strings,
        query: overlay.sessionMentionQuery,
        onHover: (i) {
          overlay.onHoverSessionMention(i);
          refresh();
        },
        onTap: (i) {
          overlay.selectedSessionMentionIndex = i;
          overlay.insertSessionMention(null);
          refresh();
        },
      ),
    );
  }

  return null;
}
