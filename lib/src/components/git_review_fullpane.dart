import 'dart:async';
import 'dart:isolate';

import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;

import '../i18n/strings.dart';
import '../services/git_review_service.dart';
import '../theme/crux_theme.dart';
import '../utils/fuzzy_match.dart';
import 'tool_detail_utils.dart' show languageFromPath;
import 'ui/button.dart';
import 'ui/fullpane.dart';
import 'ui/highlight_service.dart';
import 'ui/hoverable.dart';

enum GitReviewScope { all, staged, unstaged }

enum _GitReviewPaneMode { diff, commit }

/// Below this usable diff width a side-by-side view leaves too little room
/// for readable code, so the pane falls back to unified rendering.
const double kGitReviewMinSplitWidth = 80;

typedef CommitMessageGenerator = Future<String?> Function(
  String stagedDiff,
  List<String> recentSubjects,
);

GitCommitDraft _parseGeneratedCommitMessage(String value) {
  final lines = value.replaceAll('\r\n', '\n').split('\n');
  while (lines.isNotEmpty && lines.first.trim().isEmpty) {
    lines.removeAt(0);
  }
  while (lines.isNotEmpty && lines.last.trim().isEmpty) {
    lines.removeLast();
  }
  if (lines.isEmpty) {
    return const GitCommitDraft(title: '', description: '');
  }
  final title = lines.removeAt(0).trim();
  while (lines.isNotEmpty && lines.first.trim().isEmpty) {
    lines.removeAt(0);
  }
  return GitCommitDraft(title: title, description: lines.join('\n').trim());
}

/// A live, index-aware Git review surface.
///
/// The left side answers "which files changed?"; the right side answers
/// "what changed?". File and hunk actions only mutate Git's index. Conflict
/// resolution deliberately stays in the human/agent conversation.
class GitReviewFullpane extends StatefulComponent {
  final GitReviewBackend backend;
  final VoidCallback onClose;
  final VoidCallback? onIndexChanged;
  final VoidCallback? onCommitted;
  final CommitMessageGenerator? generateCommitMessage;
  final GitCommitDraft? initialDraft;
  final Strings strings;

  const GitReviewFullpane({
    super.key,
    required this.backend,
    required this.onClose,
    this.onIndexChanged,
    this.onCommitted,
    this.generateCommitMessage,
    this.initialDraft,
    this.strings = kEnglishStrings,
  });

  @override
  State<GitReviewFullpane> createState() => _GitReviewFullpaneState();
}

class _GitReviewFullpaneState extends State<GitReviewFullpane> {
  GitReviewSnapshot? _snapshot;
  GitReviewScope _scope = GitReviewScope.all;
  int _fileIndex = 0;
  String? _selectedPath;
  int _hunkIndex = 0;
  bool _loading = true;
  bool _busy = false;
  bool _generating = false;
  bool _committing = false;
  String? _error;
  String _commitTitle = '';
  String _commitDescription = '';
  _GitReviewPaneMode _paneMode = _GitReviewPaneMode.diff;
  List<GitReviewPatch> _patches = const [];
  final ScrollController _filesScroll = ScrollController();
  final ScrollController _diffScroll = ScrollController();
  final ScrollController _descriptionScroll = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _collapsedDirectories = <String>{};
  Timer? _searchDebouncer;
  int _searchSequence = 0;
  List<String>? _searchResultPaths;
  bool _searchActive = false;

  @override
  void initState() {
    super.initState();
    final draft = component.initialDraft;
    if (draft != null) {
      _scope = GitReviewScope.staged;
      _paneMode = _GitReviewPaneMode.commit;
      _commitTitle = draft.title;
      _commitDescription = draft.description;
    }
    unawaited(_refresh(invalidateMessage: draft == null));
  }

  @override
  void dispose() {
    _searchDebouncer?.cancel();
    _searchController.dispose();
    _filesScroll.dispose();
    _diffScroll.dispose();
    _descriptionScroll.dispose();
    super.dispose();
  }

  List<GitReviewFile> get _scopedFiles {
    final files = _snapshot?.files ?? const <GitReviewFile>[];
    return switch (_scope) {
      GitReviewScope.all => files,
      GitReviewScope.staged => files.where((file) => file.hasStaged).toList(),
      GitReviewScope.unstaged =>
        files.where((file) => file.hasUnstaged).toList(),
    };
  }

  List<GitReviewFile> get _scopeFiles {
    final files = _scopedFiles;
    if (_searchController.text.trim().isEmpty) return files;
    final resultPaths = _searchResultPaths;
    if (resultPaths == null) return files;
    final byPath = <String, GitReviewFile>{
      for (final file in files) file.path: file,
    };
    return resultPaths
        .map((path) => byPath[path])
        .whereType<GitReviewFile>()
        .toList();
  }

  List<_GitTreeRow> get _treeRows => _buildGitTreeRows(
    _scopeFiles,
    collapsedDirectories: _collapsedDirectories,
  );

  List<GitReviewFile> get _visibleFiles => [
    for (final row in _treeRows)
      if (row.file != null) row.file!,
  ];

  GitReviewFile? get _selectedFile {
    final files = _scopedFiles;
    if (files.isEmpty) return null;
    final selected = _selectedPath;
    if (selected != null) {
      for (final file in files) {
        if (file.path == selected) return file;
      }
    }
    final visible = _visibleFiles;
    if (visible.isNotEmpty) {
      return visible[_fileIndex.clamp(0, visible.length - 1)];
    }
    return files.first;
  }

  List<({GitReviewPatch patch, GitReviewHunk hunk})> get _visibleHunks {
    final result = <({GitReviewPatch patch, GitReviewHunk hunk})>[];
    for (final patch in _patchesForScope) {
      for (final hunk in patch.hunks) {
        result.add((patch: patch, hunk: hunk));
      }
    }
    return result;
  }

  List<GitReviewPatch> get _patchesForScope => switch (_scope) {
    GitReviewScope.all => _patches,
    GitReviewScope.staged =>
      _patches
          .where((patch) => patch.kind == GitReviewPatchKind.staged)
          .toList(),
    GitReviewScope.unstaged =>
      _patches
          .where((patch) => patch.kind == GitReviewPatchKind.unstaged)
          .toList(),
  };

  Future<void> _refresh({
    String? keepPath,
    bool invalidateMessage = true,
  }) async {
    if (_busy) return;
    setState(() {
      _loading = true;
      _error = null;
      if (invalidateMessage) {
        _commitTitle = '';
        _commitDescription = '';
        _paneMode = _GitReviewPaneMode.diff;
      }
    });
    try {
      final snapshot = await component.backend.loadSnapshot();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        final files = _visibleFiles;
        final wanted = keepPath == null
            ? -1
            : files.indexWhere((file) => file.path == keepPath);
        _fileIndex = wanted >= 0
            ? wanted
            : _fileIndex.clamp(0, files.isEmpty ? 0 : files.length - 1);
        _selectedPath =
            keepPath != null && _scopeFiles.any((file) => file.path == keepPath)
            ? keepPath
            : files.isEmpty
            ? (_scopeFiles.isEmpty ? null : _scopeFiles.first.path)
            : files[_fileIndex].path;
        _hunkIndex = 0;
        _loading = false;
      });
      if (_searchController.text.trim().isNotEmpty) {
        _updateSearchInput(_searchController.text);
      }
      await _loadSelectedPatches();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$error';
        _patches = const [];
      });
    }
  }

  Future<void> _loadSelectedPatches() async {
    final file = _selectedFile;
    if (file == null) {
      setState(() => _patches = const []);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final patches = await component.backend.loadPatches(file);
      if (!mounted || _selectedFile?.path != file.path) return;
      setState(() {
        _patches = patches;
        _hunkIndex = 0;
        _loading = false;
        _diffScroll.jumpTo(0);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _patches = const [];
        _loading = false;
        _error = '$error';
      });
    }
  }

  void _selectFile(int index) {
    final files = _visibleFiles;
    if (files.isEmpty) return;
    final next = index.clamp(0, files.length - 1);
    final path = files[next].path;
    final switchToDiff = _paneMode == _GitReviewPaneMode.commit;
    final selectionChanged = next != _fileIndex || path != _selectedPath;
    if (!selectionChanged && !switchToDiff) return;
    final rowIndex = _treeRows.indexWhere((row) => row.file?.path == path);
    setState(() {
      _paneMode = _GitReviewPaneMode.diff;
      _fileIndex = next;
      _selectedPath = path;
      _hunkIndex = 0;
      _filesScroll.ensureVisible(
        itemOffset: (rowIndex < 0 ? next : rowIndex).toDouble(),
        itemExtent: 1,
      );
    });
    if (selectionChanged || _patches.isEmpty) {
      unawaited(_loadSelectedPatches());
    }
  }

  void _setScope(GitReviewScope scope) {
    if (scope == _scope) return;
    final path = _selectedFile?.path;
    setState(() {
      _scope = scope;
      if (scope != GitReviewScope.staged) {
        _paneMode = _GitReviewPaneMode.diff;
      }
      final files = _visibleFiles;
      final matching = path == null
          ? -1
          : files.indexWhere((file) => file.path == path);
      _fileIndex = matching >= 0 ? matching : 0;
      _selectedPath =
          path != null && _scopeFiles.any((file) => file.path == path)
          ? path
          : files.isEmpty
          ? (_scopeFiles.isEmpty ? null : _scopeFiles.first.path)
          : files.first.path;
      _hunkIndex = 0;
    });
    unawaited(_loadSelectedPatches());
  }

  void _toggleDirectory(String path) {
    setState(() {
      if (!_collapsedDirectories.remove(path)) {
        _collapsedDirectories.add(path);
      }
      final files = _visibleFiles;
      final matching = _selectedPath == null
          ? -1
          : files.indexWhere((file) => file.path == _selectedPath);
      _fileIndex = matching >= 0
          ? matching
          : _fileIndex.clamp(0, files.isEmpty ? 0 : files.length - 1);
    });
  }

  void _collapseAll() {
    final directories = _buildGitTreeRows(
      _scopeFiles,
      collapsedDirectories: const <String>{},
    ).where((row) => row.file == null);
    setState(() {
      _collapsedDirectories.addAll(directories.map((row) => row.path));
      _fileIndex = 0;
    });
  }

  void _expandAll() {
    setState(() {
      _collapsedDirectories.clear();
      final files = _visibleFiles;
      final selected = _selectedPath;
      final matching = selected == null
          ? -1
          : files.indexWhere((file) => file.path == selected);
      _fileIndex = matching < 0 ? 0 : matching;
    });
  }

  void _appendSearchCharacter(String character) {
    _updateSearchInput('${_searchController.text}$character');
  }

  void _removeSearchCharacter() {
    final runes = _searchController.text.runes.toList();
    if (runes.isEmpty) return;
    runes.removeLast();
    _updateSearchInput(String.fromCharCodes(runes));
  }

  void _updateSearchInput(String value) {
    _searchController.text = value;
    _searchController.selection = TextSelection.collapsed(offset: value.length);
    _searchDebouncer?.cancel();
    final sequence = ++_searchSequence;
    if (value.trim().isEmpty) {
      setState(() {
        _searchResultPaths = null;
        final files = _visibleFiles;
        final selected = _selectedPath;
        final matching = selected == null
            ? -1
            : files.indexWhere((file) => file.path == selected);
        _fileIndex = matching < 0 ? 0 : matching;
      });
      return;
    }

    _searchDebouncer = Timer(const Duration(milliseconds: 60), () {
      final paths = [
        for (final file in _snapshot?.files ?? const <GitReviewFile>[])
          file.path,
      ];
      unawaited(_runFileSearch(value, paths, sequence));
    });
  }

  Future<void> _runFileSearch(
    String query,
    List<String> paths,
    int sequence,
  ) async {
    final results = await _rankGitReviewPathsAsync(query, paths);
    if (!mounted || sequence != _searchSequence) return;
    if (_searchController.text != query) return;
    setState(() {
      _searchResultPaths = results;
      final files = _visibleFiles;
      final selected = _selectedPath;
      final matching = selected == null
          ? -1
          : files.indexWhere((file) => file.path == selected);
      _fileIndex = matching < 0 ? 0 : matching;
    });
  }

  Future<void> _mutate(Future<void> Function() action) async {
    if (_busy) return;
    final path = _selectedFile?.path;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      component.onIndexChanged?.call();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _commitTitle = '';
        _commitDescription = '';
        _paneMode = _GitReviewPaneMode.diff;
      });
      await _refresh(keepPath: path, invalidateMessage: false);
    } catch (error) {
      if (!mounted) return;
      final message = '$error';
      setState(() => _busy = false);
      await _refresh(keepPath: path, invalidateMessage: false);
      if (mounted) setState(() => _error = message);
    }
  }

  void _stageFile() {
    final file = _selectedFile;
    if (file == null || !file.hasUnstaged || file.isConflicted) return;
    unawaited(_mutate(() => component.backend.stageFile(file)));
  }

  void _unstageFile() {
    final file = _selectedFile;
    if (file == null || !file.hasStaged || file.isConflicted) return;
    unawaited(_mutate(() => component.backend.unstageFile(file)));
  }

  void _stageHunk() {
    final file = _selectedFile;
    final hunks = _visibleHunks;
    if (file == null || file.isConflicted || hunks.isEmpty) return;
    final selected = hunks[_hunkIndex.clamp(0, hunks.length - 1)];
    if (selected.patch.kind != GitReviewPatchKind.unstaged) return;
    unawaited(_mutate(() => component.backend.stageHunk(selected.hunk)));
  }

  void _unstageHunk() {
    final file = _selectedFile;
    final hunks = _visibleHunks;
    if (file == null || file.isConflicted || hunks.isEmpty) return;
    final selected = hunks[_hunkIndex.clamp(0, hunks.length - 1)];
    if (selected.patch.kind != GitReviewPatchKind.staged) return;
    unawaited(_mutate(() => component.backend.unstageHunk(selected.hunk)));
  }

  void _moveHunk(int delta) {
    final hunks = _visibleHunks;
    if (hunks.isEmpty) return;
    setState(() {
      _hunkIndex = (_hunkIndex + delta).clamp(0, hunks.length - 1);
    });
  }

  Future<void> _generateMessage() async {
    if (_generating || component.generateCommitMessage == null) return;
    setState(() {
      _generating = true;
      _error = null;
    });
    try {
      final context = await component.backend.loadCommitContext();
      if (context.stagedDiff.trim().isEmpty) {
        throw const GitReviewException('Stage at least one change first');
      }
      final generated = await component.generateCommitMessage!(
        context.stagedDiff,
        context.recentSubjects,
      );
      if (!mounted) return;
      if (generated == null || generated.trim().isEmpty) {
        throw const GitReviewException('Auxiliary model is unavailable');
      }
      // Guard against an index change while the auxiliary request was in
      // flight. A stale commit message is worse than no message.
      final latest = await component.backend.loadCommitContext();
      if (!mounted) return;
      if (latest.stagedDiff != context.stagedDiff) {
        throw const GitReviewException(
          'Staged changes changed; generate the message again',
        );
      }
      final draft = _parseGeneratedCommitMessage(generated);
      final scopeChanged = _scope != GitReviewScope.staged;
      setState(() {
        _commitTitle = draft.title;
        _commitDescription = draft.description;
        _scope = GitReviewScope.staged;
        _paneMode = _GitReviewPaneMode.commit;
        if (scopeChanged) {
          final files = _scopeFiles;
          _fileIndex = 0;
          _selectedPath = files.isEmpty ? null : files.first.path;
          _hunkIndex = 0;
        }
      });
      if (scopeChanged) unawaited(_loadSelectedPatches());
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _commit({required bool push}) async {
    if (_committing || _commitTitle.trim().isEmpty) return;
    final stagedCount = _snapshot?.stagedCount ?? 0;
    if (stagedCount == 0) return;
    setState(() {
      _committing = true;
      _error = null;
    });
    try {
      await component.backend.commit(
        GitCommitDraft(title: _commitTitle, description: _commitDescription),
        push: push,
      );
      component.onCommitted?.call();
      if (mounted) component.onClose();
    } catch (error) {
      if (!mounted) return;
      final message = '$error';
      setState(() => _committing = false);
      await _refresh(invalidateMessage: false);
      if (mounted) setState(() => _error = message);
    }
  }

  bool _handleKey(KeyboardEvent event) {
    final key = event.logicalKey;
    if (_searchActive) {
      if (key == LogicalKey.escape) {
        if (_searchController.text.isNotEmpty) {
          _updateSearchInput('');
        } else {
          setState(() => _searchActive = false);
        }
        return true;
      }
      if (key == LogicalKey.enter) {
        setState(() => _searchActive = false);
        return true;
      }
      if (key == LogicalKey.arrowDown) {
        _selectFile(_fileIndex + 1);
        return true;
      }
      if (key == LogicalKey.arrowUp) {
        _selectFile(_fileIndex - 1);
        return true;
      }
      if (key == LogicalKey.backspace &&
          !event.isControlPressed &&
          !event.isAltPressed &&
          !event.isMetaPressed) {
        _removeSearchCharacter();
        return true;
      }
      final character = event.character;
      final printable =
          character != null &&
          character.isNotEmpty &&
          character.runes.every((rune) => rune >= 0x20) &&
          character != '\x7f';
      if (!event.isControlPressed &&
          !event.isAltPressed &&
          !event.isMetaPressed &&
          printable) {
        _appendSearchCharacter(character);
      }
      return true;
    }
    if ((event.isControlPressed && key == LogicalKey.keyF) ||
        event.character == '/') {
      setState(() => _searchActive = true);
      return true;
    }
    if (key == LogicalKey.arrowDown) {
      _selectFile(_fileIndex + 1);
      return true;
    }
    if (key == LogicalKey.arrowUp) {
      _selectFile(_fileIndex - 1);
      return true;
    }
    if (key == LogicalKey.bracketRight) {
      _moveHunk(1);
      return true;
    }
    if (key == LogicalKey.bracketLeft) {
      _moveHunk(-1);
      return true;
    }
    if (key == LogicalKey.digit1) {
      _setScope(GitReviewScope.all);
      return true;
    }
    if (key == LogicalKey.digit2) {
      _setScope(GitReviewScope.staged);
      return true;
    }
    if (key == LogicalKey.digit3) {
      _setScope(GitReviewScope.unstaged);
      return true;
    }
    if (key == LogicalKey.keyS) {
      event.isShiftPressed ? _stageFile() : _stageHunk();
      return true;
    }
    if (key == LogicalKey.keyU) {
      event.isShiftPressed ? _unstageFile() : _unstageHunk();
      return true;
    }
    if (key == LogicalKey.keyR) {
      unawaited(_refresh(keepPath: _selectedFile?.path));
      return true;
    }
    if (key == LogicalKey.keyG) {
      unawaited(_generateMessage());
      return true;
    }
    if (key == LogicalKey.keyC && _commitTitle.isNotEmpty) {
      ClipboardManager.copy(
        GitCommitDraft(
          title: _commitTitle,
          description: _commitDescription,
        ).message,
      );
      return true;
    }
    if (key == LogicalKey.keyJ) {
      _diffScroll.scrollDown();
      return true;
    }
    if (key == LogicalKey.keyK) {
      _diffScroll.scrollUp();
      return true;
    }
    return false;
  }

  @override
  Component build(BuildContext context) {
    final snapshot = _snapshot;
    final branch = snapshot?.branch ?? '…';
    final theme = CruxTheme.of(context);
    return Fullpane(
      title: component.strings.t('chat.gitReview.title', {'branch': branch}),
      onClose: component.onClose,
      strings: component.strings,
      onKeyEvent: _handleKey,
      footerActions: [
        Button(
          label: '⊟ ${component.strings.t('chat.gitReview.collapseAll')}',
          onPressed: _collapseAll,
          color: theme.onSurfaceVariant,
          bgColor: theme.surface,
        ),
        Button(
          label: '⊞ ${component.strings.t('chat.gitReview.expandAll')}',
          onPressed: _expandAll,
          color: theme.onSurfaceVariant,
          bgColor: theme.surface,
        ),
      ],
      footerTrailing: RichText(
        softWrap: false,
        text: TextSpan(
          children: [
            TextSpan(
              text: component.strings.t('chat.gitReview.legendModified'),
              style: TextStyle(color: theme.warningColor),
            ),
            const TextSpan(text: '  '),
            TextSpan(
              text: component.strings.t('chat.gitReview.legendAdded'),
              style: TextStyle(color: theme.successColor),
            ),
            const TextSpan(text: '  '),
            TextSpan(
              text: component.strings.t('chat.gitReview.legendDeleted'),
              style: TextStyle(color: theme.errorColor),
            ),
            const TextSpan(text: '  '),
            TextSpan(
              text: component.strings.t('chat.gitReview.legendRenamed'),
              style: TextStyle(color: theme.info),
            ),
            const TextSpan(text: '  '),
            TextSpan(
              text: component.strings.t('chat.gitReview.legendConflict'),
              style: TextStyle(color: theme.errorColor),
            ),
          ],
        ),
      ),
      shortcuts: [
        FullpaneShortcut(
          label: component.strings.t('chat.gitReview.file'),
          keyHint: '↑↓',
          matches: (_) => false,
          onActivate: () {},
        ),
        FullpaneShortcut(
          label: component.strings.t('chat.gitReview.chunk'),
          keyHint: '[]',
          matches: (_) => false,
          onActivate: () {},
        ),
      ],
      contentBuilder: (context) => LayoutBuilder(
        builder: (context, constraints) =>
            _buildBody(CruxTheme.of(context), constraints),
      ),
    );
  }

  Component _buildBody(CruxThemeData theme, BoxConstraints constraints) {
    final snapshot = _snapshot;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _toolbar(theme, snapshot, constraints.maxWidth),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: Text(_error!, style: TextStyle(color: theme.errorColor)),
          ),
        Divider(color: theme.outline, height: 1),
        Expanded(
          child: constraints.maxWidth >= 80
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: (constraints.maxWidth * 0.28).clamp(24, 36),
                      child: _fileList(theme),
                    ),
                    VerticalDivider(
                      width: 1,
                      thickness: 1,
                      color: theme.outline,
                    ),
                    Expanded(child: _reviewPane(theme)),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _compactFilePicker(theme),
                    Divider(color: theme.outline, height: 1),
                    Expanded(child: _reviewPane(theme)),
                  ],
                ),
        ),
      ],
    );
  }

  Component _toolbar(
    CruxThemeData theme,
    GitReviewSnapshot? snapshot,
    double width,
  ) {
    final all = snapshot?.files.length ?? 0;
    final staged = snapshot?.stagedCount ?? 0;
    final unstaged = snapshot?.unstagedCount ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: Row(
        children: [
          _scopeTab(
            theme,
            GitReviewScope.all,
            component.strings.t('chat.gitReview.all'),
            all,
          ),
          const SizedBox(width: 1),
          _scopeTab(
            theme,
            GitReviewScope.staged,
            component.strings.t('home.git.staged'),
            staged,
          ),
          const SizedBox(width: 1),
          _scopeTab(
            theme,
            GitReviewScope.unstaged,
            component.strings.t('chat.gitReview.unstaged'),
            unstaged,
          ),
          const SizedBox(width: 1),
          SizedBox(width: width >= 100 ? 28 : 16, child: _searchBox(theme)),
          const Spacer(),
          Button(
            label: _generating
                ? component.strings.t('chat.gitReview.generating')
                : component.strings.t('chat.gitReview.generateMessage'),
            onPressed: staged > 0 && !_generating
                ? () => unawaited(_generateMessage())
                : null,
            color: staged > 0 ? theme.accent : theme.onSurfaceDim,
          ),
        ],
      ),
    );
  }

  Component _scopeTab(
    CruxThemeData theme,
    GitReviewScope scope,
    String label,
    int count,
  ) {
    final selected = scope == _scope;
    return Hoverable(
      onTap: () => _setScope(scope),
      builder: (context, hovered) => Container(
        decoration: BoxDecoration(
          color: selected
              ? theme.selectionColor
              : hovered
              ? theme.wizardRowBgHover
              : null,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Text(
          '$label  $count',
          style: TextStyle(
            color: selected ? theme.selectedText : theme.onSurfaceDim,
            fontWeight: selected || hovered ? FontWeight.bold : null,
          ),
        ),
      ),
    );
  }

  Component _searchBox(CruxThemeData theme) => Hoverable(
    onTap: () => setState(() => _searchActive = true),
    builder: (context, hovered) => Container(
      decoration: BoxDecoration(
        color: _searchActive
            ? theme.selectionColor
            : hovered
            ? theme.wizardRowBgHover
            : theme.surfaceVariant,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: Row(
        children: [
          Text(
            '⌕ ',
            style: TextStyle(
              color: _searchActive ? theme.selectedText : theme.onSurfaceDim,
            ),
          ),
          Expanded(
            child: TextField(
              controller: _searchController,
              focused: false,
              maxLines: 1,
              placeholder: component.strings.t('chat.gitReview.searchFiles'),
              placeholderStyle: TextStyle(
                color: _searchActive ? theme.selectedText : theme.onSurfaceDim,
                fontStyle: FontStyle.italic,
              ),
              style: TextStyle(
                color: _searchActive ? theme.selectedText : theme.foreground,
              ),
            ),
          ),
          if (_searchActive)
            Text('│', style: TextStyle(color: theme.selectedText)),
        ],
      ),
    ),
  );

  Component _reviewPane(CruxThemeData theme) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1),
        child: Row(
          children: [
            _paneTab(
              theme,
              _GitReviewPaneMode.diff,
              component.strings.t('chat.gitReview.diffTab'),
            ),
            const SizedBox(width: 1),
            _paneTab(
              theme,
              _GitReviewPaneMode.commit,
              component.strings.t('chat.gitReview.commitTab'),
            ),
          ],
        ),
      ),
      Divider(color: theme.outline, height: 1),
      Expanded(
        child: _paneMode == _GitReviewPaneMode.commit
            ? _commitReview(theme)
            : _diffView(theme),
      ),
    ],
  );

  Component _paneTab(
    CruxThemeData theme,
    _GitReviewPaneMode mode,
    String label,
  ) {
    final selected = mode == _paneMode;
    return Hoverable(
      onTap: () => _setPaneMode(mode),
      builder: (context, hovered) => Container(
        decoration: BoxDecoration(
          color: selected
              ? theme.selectionColor
              : hovered
              ? theme.wizardRowBgHover
              : null,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? theme.selectedText : theme.onSurfaceDim,
            fontWeight: selected || hovered ? FontWeight.bold : null,
          ),
        ),
      ),
    );
  }

  void _setPaneMode(_GitReviewPaneMode mode) {
    if (mode == _paneMode) return;
    if (mode == _GitReviewPaneMode.commit && _scope != GitReviewScope.staged) {
      setState(() {
        _scope = GitReviewScope.staged;
        _paneMode = mode;
        final files = _scopeFiles;
        _fileIndex = 0;
        _selectedPath = files.isEmpty ? null : files.first.path;
        _hunkIndex = 0;
      });
      unawaited(_loadSelectedPatches());
      return;
    }
    setState(() => _paneMode = mode);
  }

  Component _commitReview(CruxThemeData theme) {
    final stagedCount = _snapshot?.stagedCount ?? 0;
    final canCommit =
        stagedCount > 0 && _commitTitle.trim().isNotEmpty && !_committing;
    final draft = GitCommitDraft(
      title: _commitTitle,
      description: _commitDescription,
    );
    return Padding(
      padding: const EdgeInsets.all(1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                component.strings.t('chat.gitReview.stagedReady', {
                  'count': '$stagedCount',
                }),
                style: TextStyle(
                  color: stagedCount > 0
                      ? theme.successColor
                      : theme.onSurfaceDim,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              Button(
                label: component.strings.t('chat.gitReview.copy'),
                onPressed: _commitTitle.trim().isEmpty
                    ? null
                    : () => ClipboardManager.copy(draft.message),
                bgColor: theme.surface,
              ),
            ],
          ),
          const SizedBox(height: 1),
          Text(
            component.strings.t('chat.gitReview.commitTitle'),
            style: TextStyle(
              color: theme.onSurfaceDim,
              fontWeight: FontWeight.bold,
            ),
          ),
          Container(
            width: double.infinity,
            decoration: BoxDecoration(color: theme.surfaceVariant),
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: Text(
              _commitTitle.trim().isEmpty
                  ? component.strings.t('chat.gitReview.noCommitTitle')
                  : _commitTitle.trim(),
              style: TextStyle(
                color: _commitTitle.trim().isEmpty
                    ? theme.warningColor
                    : theme.foreground,
                fontWeight: _commitTitle.trim().isEmpty
                    ? null
                    : FontWeight.bold,
                fontStyle: _commitTitle.trim().isEmpty
                    ? FontStyle.italic
                    : null,
              ),
            ),
          ),
          const SizedBox(height: 1),
          Text(
            component.strings.t('chat.gitReview.commitDescription'),
            style: TextStyle(
              color: theme.onSurfaceDim,
              fontWeight: FontWeight.bold,
            ),
          ),
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(color: theme.surfaceVariant),
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: Scrollbar(
                controller: _descriptionScroll,
                thumbVisibility: true,
                thumbColor: theme.onSurfaceDim,
                child: SingleChildScrollView(
                  controller: _descriptionScroll,
                  keyboardScrollable: true,
                  child: Text(
                    _commitDescription.trim().isEmpty
                        ? component.strings.t(
                            'chat.gitReview.noCommitDescription',
                          )
                        : _commitDescription.trim(),
                    style: TextStyle(
                      color: _commitDescription.trim().isEmpty
                          ? theme.onSurfaceDim
                          : theme.foreground,
                      fontStyle: _commitDescription.trim().isEmpty
                          ? FontStyle.italic
                          : null,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 1),
          Row(
            children: [
              Expanded(
                child: Text(
                  component.strings.t('chat.gitReview.reviewHint'),
                  style: TextStyle(color: theme.onSurfaceDim),
                ),
              ),
              Button(
                label: _committing
                    ? component.strings.t('chat.gitReview.committing')
                    : component.strings.t('chat.gitReview.commit'),
                onPressed: canCommit
                    ? () => unawaited(_commit(push: false))
                    : null,
                color: canCommit ? theme.foreground : theme.onSurfaceDim,
              ),
              const SizedBox(width: 1),
              Button(
                label: _committing
                    ? component.strings.t('chat.gitReview.committing')
                    : component.strings.t('chat.gitReview.commitAndPush'),
                onPressed: canCommit
                    ? () => unawaited(_commit(push: true))
                    : null,
                color: canCommit ? theme.selectedText : theme.onSurfaceDim,
                bgColor: canCommit ? theme.accent : theme.surfaceVariant,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Component _fileList(CruxThemeData theme) {
    final rows = _treeRows;
    final files = _visibleFiles;
    if (rows.isEmpty) return _fileListEmpty(theme);
    final indexes = <String, int>{
      for (var i = 0; i < files.length; i++) files[i].path: i,
    };
    return Scrollbar(
      controller: _filesScroll,
      thumbVisibility: true,
      thumbColor: theme.onSurfaceDim,
      child: ListView.builder(
        controller: _filesScroll,
        itemCount: rows.length,
        itemBuilder: (context, index) {
          final row = rows[index];
          if (row.file == null) return _directoryRow(row, theme);
          return _fileRow(
            row.file!,
            indexes[row.file!.path]!,
            theme,
            depth: row.depth,
          );
        },
      ),
    );
  }

  Component _compactFilePicker(CruxThemeData theme) {
    final files = _visibleFiles;
    if (files.isEmpty) return _fileListEmpty(theme);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < files.length; i++) ...[
            if (i > 0) const SizedBox(width: 1),
            _fileRow(files[i], i, theme, compact: true),
          ],
        ],
      ),
    );
  }

  Component _fileRow(
    GitReviewFile file,
    int index,
    CruxThemeData theme, {
    bool compact = false,
    int depth = 0,
  }) {
    final selected = file.path == _selectedPath;
    final name = p.basename(file.path);
    return Hoverable(
      onTap: () => _selectFile(index),
      builder: (context, hovered) => Container(
        decoration: BoxDecoration(
          color: selected
              ? theme.selectionColor
              : hovered
              ? theme.wizardRowBgHover
              : null,
        ),
        padding: EdgeInsets.only(left: compact ? 1 : depth * 2 + 1, right: 1),
        child: Row(
          mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
          children: [
            if (!compact)
              Text(
                selected ? '▌' : ' ',
                style: TextStyle(
                  color: selected ? theme.accent : theme.onSurfaceDim,
                ),
              ),
            Text(
              '${file.displayStatus} ',
              style: TextStyle(
                color: selected
                    ? theme.selectedText
                    : file.isConflicted
                    ? theme.errorColor
                    : file.isAdded
                    ? theme.successColor
                    : file.isDeleted
                    ? theme.errorColor
                    : file.isRenamed
                    ? theme.info
                    : theme.warningColor,
              ),
            ),
            if (compact)
              Text(
                name,
                style: TextStyle(
                  color: selected ? theme.selectedText : theme.foreground,
                  fontWeight: selected ? FontWeight.bold : null,
                ),
              )
            else
              Expanded(
                child: Text(
                  name,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected ? theme.selectedText : theme.foreground,
                    fontWeight: selected ? FontWeight.bold : null,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Component _directoryRow(_GitTreeRow row, CruxThemeData theme) => Hoverable(
    onTap: () => _toggleDirectory(row.path),
    builder: (context, hovered) => Container(
      decoration: BoxDecoration(color: hovered ? theme.wizardRowBgHover : null),
      padding: EdgeInsets.only(left: row.depth * 2 + 1, right: 1),
      child: Row(
        children: [
          Text(
            row.collapsed ? '▸ ' : '▾ ',
            style: TextStyle(color: theme.accent),
          ),
          Expanded(
            child: Text(
              row.label,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: theme.foreground,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Text('${row.fileCount}', style: TextStyle(color: theme.onSurfaceDim)),
        ],
      ),
    ),
  );

  Component _empty(CruxThemeData theme) => Padding(
    padding: const EdgeInsets.all(1),
    child: Text(
      component.strings.t('chat.gitReview.noChanges'),
      style: TextStyle(color: theme.onSurfaceDim, fontStyle: FontStyle.italic),
    ),
  );

  Component _fileListEmpty(CruxThemeData theme) => Padding(
    padding: const EdgeInsets.all(1),
    child: Text(
      _searchController.text.isEmpty
          ? component.strings.t('chat.gitReview.noChanges')
          : component.strings.t('chat.gitReview.noFilesMatch'),
      style: TextStyle(color: theme.onSurfaceDim, fontStyle: FontStyle.italic),
    ),
  );

  Component _diffView(CruxThemeData theme) {
    final file = _selectedFile;
    if (_loading) {
      return Center(
        child: Text(
          component.strings.t('chat.gitReview.loading'),
          style: TextStyle(color: theme.onSurfaceDim),
        ),
      );
    }
    if (file == null) return _empty(theme);
    final patches = _patchesForScope;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _fileActions(file, theme),
        Divider(color: theme.outline, height: 1),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => Scrollbar(
              controller: _diffScroll,
              thumbVisibility: true,
              thumbColor: theme.onSurfaceDim,
              child: SingleChildScrollView(
                controller: _diffScroll,
                keyboardScrollable: true,
                child: patches.isEmpty
                    ? _empty(theme)
                    : _patchList(
                        patches,
                        file,
                        theme,
                        constraints.maxWidth - 1,
                      ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Component _fileActions(GitReviewFile file, CruxThemeData theme) {
    final stats = _diffStats(_patchesForScope);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: Row(
        children: [
          Expanded(
            child: Text(
              file.oldPath == null
                  ? file.path
                  : '${file.oldPath} → ${file.path}',
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: theme.foreground,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          if (stats.added > 0)
            Text(
              ' +${stats.added}',
              style: TextStyle(color: theme.successColor),
            ),
          if (stats.removed > 0)
            Text(
              ' −${stats.removed}',
              style: TextStyle(color: theme.errorColor),
            ),
          const SizedBox(width: 1),
          if (file.isConflicted)
            Text(
              component.strings.t('chat.gitReview.resolveInChat'),
              style: TextStyle(color: theme.errorColor),
            )
          else ...[
            if (file.hasUnstaged)
              Button(
                label: component.strings.t('chat.gitReview.stageFile'),
                onPressed: _busy ? null : _stageFile,
              ),
            if (file.hasStaged) ...[
              const SizedBox(width: 1),
              Button(
                label: component.strings.t('chat.gitReview.unstageFile'),
                onPressed: _busy ? null : _unstageFile,
              ),
            ],
          ],
        ],
      ),
    );
  }

  Component _patchList(
    List<GitReviewPatch> patches,
    GitReviewFile file,
    CruxThemeData theme,
    double width,
  ) {
    var globalHunk = 0;
    final children = <Component>[];
    final language = languageFromPath(file.path);
    final split = width >= kGitReviewMinSplitWidth;
    final totalHunks = patches.fold<int>(
      0,
      (count, patch) => count + patch.hunks.length,
    );
    for (final patch in patches) {
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1),
          child: Text(
            patch.kind == GitReviewPatchKind.staged
                ? component.strings.t('chat.gitReview.stagedChanges')
                : component.strings.t('chat.gitReview.unstagedChanges'),
            style: TextStyle(color: theme.accent, fontWeight: FontWeight.bold),
          ),
        ),
      );
      if (split && patch.hunks.isNotEmpty) {
        children.add(_splitColumnLabels(theme, width));
      }
      for (final hunk in patch.hunks) {
        final hunkNumber = globalHunk++;
        children.add(
          _hunkHeader(patch, hunk, hunkNumber, totalHunks, file, theme),
        );
        if (split) {
          children.add(_splitHunk(hunk, theme, language, width));
        } else {
          for (final line in hunk.lines) {
            children.add(_diffLine(line, theme, language: language));
          }
        }
      }
      if (patch.hunks.isEmpty) {
        children.add(
          Padding(
            padding: const EdgeInsets.all(1),
            child: Text(
              component.strings.t('chat.gitReview.previewUnavailable'),
              style: TextStyle(
                color: theme.onSurfaceDim,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Component _hunkHeader(
    GitReviewPatch patch,
    GitReviewHunk hunk,
    int index,
    int total,
    GitReviewFile file,
    CruxThemeData theme,
  ) {
    final selected = index == _hunkIndex;
    final canMutate = !_busy && !file.isConflicted;
    final action = patch.kind == GitReviewPatchKind.staged
        ? component.strings.t('chat.gitReview.unstageChunk')
        : component.strings.t('chat.gitReview.stageChunk');
    return Hoverable(
      onTap: () => setState(() => _hunkIndex = index),
      builder: (context, hovered) => Container(
        decoration: BoxDecoration(
          color: selected
              ? theme.wizardRowBgSelected
              : hovered
              ? theme.wizardRowBgHover
              : theme.surfaceVariant,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 1),
        child: Row(
          children: [
            Expanded(
              child: Text(
                component.strings.t('chat.gitReview.changeNumber', {
                  'current': '${index + 1}',
                  'total': '$total',
                }),
                style: TextStyle(
                  color: selected ? theme.selectedText : theme.accent,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Button(
              label: action,
              onPressed: canMutate
                  ? () {
                      setState(() => _hunkIndex = index);
                      unawaited(
                        _mutate(
                          () => patch.kind == GitReviewPatchKind.staged
                              ? component.backend.unstageHunk(hunk)
                              : component.backend.stageHunk(hunk),
                        ),
                      );
                    }
                  : null,
              bgColor: selected
                  ? theme.wizardRowBgSelected
                  : theme.surfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  Component _splitColumnLabels(CruxThemeData theme, double width) {
    final columnWidth = ((width - 1) / 2).floorToDouble();
    return Row(
      children: [
        SizedBox(
          width: columnWidth,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: Text(
              component.strings.t('chat.gitReview.before'),
              style: TextStyle(
                color: theme.onSurfaceDim,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
        SizedBox(
          width: 1,
          child: Text('│', style: TextStyle(color: theme.outline)),
        ),
        SizedBox(
          width: columnWidth,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: Text(
              component.strings.t('chat.gitReview.after'),
              style: TextStyle(
                color: theme.onSurfaceDim,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Component _splitHunk(
    GitReviewHunk hunk,
    CruxThemeData theme,
    String language,
    double width,
  ) {
    final columnWidth = ((width - 1) / 2).floorToDouble();
    final rows = _pairHunkLines(hunk);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final row in rows)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: columnWidth,
                child: _splitCell(row.left, theme, language),
              ),
              SizedBox(
                width: 1,
                child: Text('│', style: TextStyle(color: theme.outline)),
              ),
              SizedBox(
                width: columnWidth,
                child: _splitCell(row.right, theme, language),
              ),
            ],
          ),
      ],
    );
  }

  Component _splitCell(
    _GitPatchSide? side,
    CruxThemeData theme,
    String language,
  ) {
    if (side == null) return const SizedBox();
    final (fallback, background) = switch (side.kind) {
      _GitPatchLineKind.added => (theme.diffAdded, theme.diffAddedBackground),
      _GitPatchLineKind.removed => (
        theme.diffRemoved,
        theme.diffRemovedBackground,
      ),
      _GitPatchLineKind.context => (theme.onSurfaceDim, null),
    };
    final spans = _highlightWithBackground(
      side.text,
      language,
      theme,
      fallback,
      background,
    );
    return Container(
      decoration: background == null ? null : BoxDecoration(color: background),
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: RichText(
        softWrap: true,
        overflow: TextOverflow.clip,
        text: TextSpan(
          children: [
            TextSpan(
              text: '${side.lineNumber.toString().padLeft(4)} ',
              style: TextStyle(color: theme.codeBlockGutter),
            ),
            ...spans,
          ],
        ),
      ),
    );
  }

  List<InlineSpan> _highlightWithBackground(
    String content,
    String language,
    CruxThemeData theme,
    Color fallback,
    Color? background,
  ) {
    final highlighted = language.isEmpty
        ? <InlineSpan>[TextSpan(text: content)]
        : highlightCode(content, language, theme);
    return [
      for (final span in highlighted)
        if (span is TextSpan)
          TextSpan(
            text: span.text,
            style: (span.style ?? const TextStyle()).copyWith(
              color: span.style?.color ?? fallback,
              backgroundColor: background,
            ),
          ),
    ];
  }

  Component _diffLine(
    String line,
    CruxThemeData theme, {
    required String language,
  }) {
    Color color = theme.onSurfaceDim;
    Color? background;
    if (line.startsWith('+') && !line.startsWith('+++')) {
      color = theme.diffAdded;
      background = theme.diffAddedBackground;
    } else if (line.startsWith('-') && !line.startsWith('---')) {
      color = theme.diffRemoved;
      background = theme.diffRemovedBackground;
    } else if (line.startsWith('diff --git') ||
        line.startsWith('---') ||
        line.startsWith('+++')) {
      color = theme.onSurfaceVariant;
    }
    final isCode =
        line.startsWith('+') || line.startsWith('-') || line.startsWith(' ');
    final prefix = isCode && line.isNotEmpty ? line.substring(0, 1) : '';
    final content = isCode && line.isNotEmpty ? line.substring(1) : line;
    final spans = language.isEmpty || !isCode
        ? <InlineSpan>[
            TextSpan(
              text: content,
              style: TextStyle(color: color),
            ),
          ]
        : _highlightWithBackground(content, language, theme, color, background);
    return Container(
      decoration: background == null ? null : BoxDecoration(color: background),
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: RichText(
        softWrap: true,
        overflow: TextOverflow.clip,
        text: TextSpan(
          children: [
            if (prefix.isNotEmpty)
              TextSpan(
                text: prefix,
                style: TextStyle(color: color, backgroundColor: background),
              ),
            ...spans,
          ],
        ),
      ),
    );
  }
}

List<String> _rankGitReviewPaths({
  required String query,
  required List<String> paths,
}) {
  final ranked = <({String path, int score})>[];
  for (final path in paths) {
    final basenameScore = scoreStringMatch(query, p.basename(path));
    final pathScore = scoreStringMatch(query, path);
    final score = basenameScore > 0 ? 10000 + basenameScore : pathScore;
    if (score > 0) ranked.add((path: path, score: score));
  }
  ranked.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    return byScore != 0 ? byScore : a.path.compareTo(b.path);
  });
  return [for (final item in ranked) item.path];
}

Future<List<String>> _rankGitReviewPathsAsync(
  String query,
  List<String> paths,
) => Isolate.run(() => _rankGitReviewPaths(query: query, paths: paths));

class _GitTreeRow {
  final String path;
  final String label;
  final int depth;
  final int fileCount;
  final bool collapsed;
  final GitReviewFile? file;

  const _GitTreeRow.directory({
    required this.path,
    required this.label,
    required this.depth,
    required this.fileCount,
    required this.collapsed,
  }) : file = null;

  const _GitTreeRow.file({
    required this.path,
    required this.label,
    required this.depth,
    required this.file,
  }) : fileCount = 1,
       collapsed = false;
}

class _GitTreeNode {
  final String name;
  final String path;
  final Map<String, _GitTreeNode> directories = <String, _GitTreeNode>{};
  final List<GitReviewFile> files = <GitReviewFile>[];

  _GitTreeNode(this.name, this.path);

  int get fileCount =>
      files.length +
      directories.values.fold<int>(
        0,
        (count, child) => count + child.fileCount,
      );
}

List<_GitTreeRow> _buildGitTreeRows(
  List<GitReviewFile> files, {
  required Set<String> collapsedDirectories,
}) {
  final root = _GitTreeNode('', '');
  for (final file in files) {
    final parts = file.path.replaceAll('\\', '/').split('/');
    var node = root;
    var directoryPath = '';
    for (final part in parts.take(parts.length - 1)) {
      directoryPath = directoryPath.isEmpty ? part : '$directoryPath/$part';
      node = node.directories.putIfAbsent(
        part,
        () => _GitTreeNode(part, directoryPath),
      );
    }
    node.files.add(file);
  }

  final rows = <_GitTreeRow>[];
  void appendContents(_GitTreeNode node, int depth) {
    final directories = node.directories.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    for (final directory in directories) {
      final collapsed = collapsedDirectories.contains(directory.path);
      rows.add(
        _GitTreeRow.directory(
          path: directory.path,
          label: directory.name,
          depth: depth,
          fileCount: directory.fileCount,
          collapsed: collapsed,
        ),
      );
      if (!collapsed) appendContents(directory, depth + 1);
    }
    final sortedFiles = node.files.toList()
      ..sort(
        (a, b) => p
            .basename(a.path)
            .toLowerCase()
            .compareTo(p.basename(b.path).toLowerCase()),
      );
    for (final file in sortedFiles) {
      rows.add(
        _GitTreeRow.file(
          path: file.path,
          label: p.basename(file.path),
          depth: depth,
          file: file,
        ),
      );
    }
  }

  appendContents(root, 0);
  return rows;
}

({int added, int removed}) _diffStats(List<GitReviewPatch> patches) {
  var added = 0;
  var removed = 0;
  for (final patch in patches) {
    for (final hunk in patch.hunks) {
      for (final line in hunk.lines) {
        if (line.startsWith('+')) {
          added++;
        } else if (line.startsWith('-')) {
          removed++;
        }
      }
    }
  }
  return (added: added, removed: removed);
}

enum _GitPatchLineKind { context, removed, added }

class _GitPatchSide {
  final _GitPatchLineKind kind;
  final String text;
  final int lineNumber;

  const _GitPatchSide(this.kind, this.text, this.lineNumber);
}

class _GitPatchPair {
  final _GitPatchSide? left;
  final _GitPatchSide? right;

  const _GitPatchPair({this.left, this.right});
}

/// Pair one unified hunk into before/after rows while retaining the line
/// numbers encoded in its hunk header.
List<_GitPatchPair> _pairHunkLines(GitReviewHunk hunk) {
  final match = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@')
      .firstMatch(hunk.header);
  var oldLine = int.tryParse(match?.group(1) ?? '') ?? 1;
  var newLine = int.tryParse(match?.group(2) ?? '') ?? 1;
  final rows = <_GitPatchPair>[];
  var i = 0;
  while (i < hunk.lines.length) {
    final line = hunk.lines[i];
    if (line.startsWith(r'\')) {
      i++;
      continue;
    }
    if (line.startsWith(' ')) {
      final text = line.substring(1);
      rows.add(
        _GitPatchPair(
          left: _GitPatchSide(_GitPatchLineKind.context, text, oldLine++),
          right: _GitPatchSide(_GitPatchLineKind.context, text, newLine++),
        ),
      );
      i++;
      continue;
    }

    final removed = <_GitPatchSide>[];
    while (i < hunk.lines.length && hunk.lines[i].startsWith('-')) {
      removed.add(
        _GitPatchSide(
          _GitPatchLineKind.removed,
          hunk.lines[i].substring(1),
          oldLine++,
        ),
      );
      i++;
    }
    final added = <_GitPatchSide>[];
    while (i < hunk.lines.length && hunk.lines[i].startsWith('+')) {
      added.add(
        _GitPatchSide(
          _GitPatchLineKind.added,
          hunk.lines[i].substring(1),
          newLine++,
        ),
      );
      i++;
    }
    if (removed.isEmpty && added.isEmpty) {
      // Defensive fallback for a malformed/non-standard patch line.
      rows.add(
        _GitPatchPair(
          left: _GitPatchSide(_GitPatchLineKind.context, line, oldLine++),
          right: _GitPatchSide(_GitPatchLineKind.context, line, newLine++),
        ),
      );
      i++;
      continue;
    }
    final count = removed.length > added.length ? removed.length : added.length;
    for (var j = 0; j < count; j++) {
      rows.add(
        _GitPatchPair(
          left: j < removed.length ? removed[j] : null,
          right: j < added.length ? added[j] : null,
        ),
      );
    }
  }
  return rows;
}
