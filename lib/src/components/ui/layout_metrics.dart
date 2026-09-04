/// Shared layout and spacing constants for the Crux TUI.
///
/// Centralizes the responsive thresholds and inset sizes used by the
/// main chat surfaces (chat panel, message bubbles, input, toolbar,
/// tool detail pane, fullpane) so related surfaces stay visually
/// consistent and each number carries its rationale in one place.
///
/// All values are in terminal cells (columns / rows). These constants
/// describe the *current* layout behavior exactly — changing one is a
/// deliberate visual change, not a refactor.
library;

// ── Chat panel sidebar (info pane) ───────────────────────────────

/// Terminal width (columns) at or above which the chat panel shows the
/// right-hand info sidebar. Below this the sidebar is hidden entirely.
const kSidebarShowThreshold = 100;

/// Sidebar width (columns) at exactly [kSidebarShowThreshold] terminal
/// columns; the sidebar then grows 1:1 with any extra width up to
/// [kSidebarWidthMax].
const kSidebarWidthMin = 28.0;

/// Maximum sidebar width (columns). Reached when the terminal is
/// [kSidebarShowThreshold] + ([kSidebarWidthMax] - [kSidebarWidthMin])
/// columns wide; wider terminals keep the sidebar capped here.
const kSidebarWidthMax = 40.0;

// ── Fullpane ─────────────────────────────────────────────────────

/// Width threshold (columns) below which the fullpane becomes truly
/// full-screen. Matches the side-panel hide threshold so the UX is
/// consistent: when the terminal is too narrow for a side panel it's
/// also too narrow for margin insets.
const kFullpaneNarrowThreshold = 100;

/// Height threshold (rows) below which the fullpane becomes truly
/// full-screen. 24 rows is the classic minimum terminal size; below
/// that there's no room for margins around the pane.
const kFullpaneShortThreshold = 24;

/// Top/bottom margin (rows) around the fullpane, applied only when the
/// terminal is large enough to afford insets (see
/// [kFullpaneNarrowThreshold] / [kFullpaneShortThreshold]).
const kFullpaneMarginRows = 3.0;

/// Left/right margin (columns) around the fullpane under the same
/// conditions as [kFullpaneMarginRows].
const kFullpaneMarginCols = 6.0;

// ── Chat content ─────────────────────────────────────────────────

/// Width (columns) of the message prefix rail — the `' You: '` /
/// `' Crux: '` label column at the left of each bubble row. Prose
/// continuation lines align at column
/// [kContentHorizontalPadding] + [kMessageRailWidth]. Documentation
/// only: the width is implicit in the prefix string literals.
const kMessageRailWidth = 7;

/// Standard horizontal padding (columns) around chat content rows —
/// message bubbles, the toolbar row, and tool detail sections. Gives
/// text a one-cell gutter from the terminal edge / pane border.
const kContentHorizontalPadding = 1.0;

/// Uniform padding (cells) around the chat input field and its row of
/// controls (`> ` prompt, paste button).
const kInputPadding = 1.0;

/// Minimum number of text rows visible in the chat input. The input grows on
/// taller terminals, but an empty input retains the original one-row height.
const kChatInputMinVisibleLines = 1;

/// Right-edge clearance (columns) reserved for the chat scrollbar's
/// thumb + marker column so floating controls (e.g. the vibe/verbose
/// toggle) don't overlap the scrollbar or block its hit testing.
const kScrollbarClearance = 2.0;

// ── Tool detail pane ─────────────────────────────────────────────

/// Horizontal padding (columns) of the tool detail pane's tab header —
/// slightly roomier than [kContentHorizontalPadding] so adjacent tabs
/// read as separate targets.
const kTabHeaderHorizontalPadding = 2.0;

// ── Toolbar chip-drop budget ─────────────────────────────────────

/// Total horizontal inset (columns) subtracted from the toolbar width
/// budget before chips are laid out: [kContentHorizontalPadding] on
/// both sides of the toolbar row.
const kToolbarRowInset = 2;

/// Horizontal padding (columns) budgeted per toolbar button/chip when
/// computing which chips fit in the available width (one cell of
/// padding on each side of the label).
const kToolbarButtonPadding = 2;

/// Gap (columns) budgeted between regular toolbar chips/readouts.
const kToolbarChipGap = 2;

/// Tighter gap (columns) budgeted before compact readouts (e.g. the
/// time-to-first-token readout).
const kToolbarTightGap = 1;
