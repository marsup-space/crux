import '../services/git_review_service.dart';
import '../utils/token_estimate.dart' show estimateToolRoundTripTokens;
import 'tool_def.dart';

class GitCommitReviewRequest {
  final String projectPath;
  final GitCommitDraft draft;
  final List<String> stagedPaths;

  const GitCommitReviewRequest({
    required this.projectPath,
    required this.draft,
    required this.stagedPaths,
  });
}

typedef GitCommitReviewOpener = void Function(GitCommitReviewRequest request);

/// Stages an explicit set of changed files and opens the human-owned commit
/// review surface. The tool deliberately cannot commit or push: those actions
/// remain buttons the user must click after reviewing the staged diff and
/// proposed message.
class GitPrepareCommitTool extends ToolDef {
  final GitCommitReviewOpener onPrepared;

  GitPrepareCommitTool({required this.onPrepared});

  @override
  String get name => 'prepare_commit';

  @override
  String get description =>
      'Prepare a Git commit for human approval. Stages ONLY the explicitly '
      'listed changed files, records a proposed commit title and detailed '
      'description, and opens the staged-changes review screen. The user can '
      'inspect the exact diff and then click Commit or Commit + Push. This '
      'tool NEVER creates a commit and NEVER pushes. Use it only after the '
      'requested implementation and relevant verification are complete. Do '
      'not include unrelated user changes, and do not use it for conflicted '
      'files.';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'required': ['files', 'title', 'description'],
    'properties': {
      'files': {
        'type': 'array',
        'minItems': 1,
        'items': {'type': 'string'},
        'description':
            'Repository-relative paths to stage. Include only files that '
            'belong in this commit.',
      },
      'title': {
        'type': 'string',
        'description':
            'Concise one-line commit subject, normally at most 72 characters.',
      },
      'description': {
        'type': 'string',
        'description':
            'Detailed commit body explaining the important changes and why.',
      },
    },
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final rawFiles = args['files'];
    final title = args['title'];
    final description = args['description'];
    if (rawFiles is! List || rawFiles.isEmpty) {
      return ToolResult.error('At least one changed file path is required.');
    }
    if (title is! String || title.trim().isEmpty) {
      return ToolResult.error('A non-empty commit title is required.');
    }
    if (title.contains('\n') || title.contains('\r')) {
      return ToolResult.error('The commit title must be one line.');
    }
    if (description is! String) {
      return ToolResult.error('A commit description is required.');
    }

    final requestedPaths = <String>[];
    for (final value in rawFiles) {
      if (value is! String || value.trim().isEmpty) {
        return ToolResult.error('Every file entry must be a non-empty path.');
      }
      final normalized = value.trim().replaceAll('\\', '/');
      if (!requestedPaths.contains(normalized)) requestedPaths.add(normalized);
    }

    final service = GitReviewService(projectPath: ctx.workingDirectory);
    final snapshot = await service.loadSnapshot();
    final byPath = <String, GitReviewFile>{
      for (final file in snapshot.files) file.path.replaceAll('\\', '/'): file,
    };
    final missing = [
      for (final path in requestedPaths)
        if (!byPath.containsKey(path)) path,
    ];
    if (missing.isNotEmpty) {
      return ToolResult.error(
        'These paths are not currently changed: ${missing.join(', ')}',
      );
    }
    final files = [for (final path in requestedPaths) byPath[path]!];
    final conflicted = files.where((file) => file.isConflicted).toList();
    if (conflicted.isNotEmpty) {
      return ToolResult.error(
        'Resolve conflicts before preparing a commit: '
        '${conflicted.map((file) => file.path).join(', ')}',
      );
    }

    await service.stageFiles(files);
    final draft = GitCommitDraft(
      title: title.trim(),
      description: description.trim(),
    );
    onPrepared(
      GitCommitReviewRequest(
        projectPath: ctx.workingDirectory,
        draft: draft,
        stagedPaths: List<String>.unmodifiable(requestedPaths),
      ),
    );

    return ToolResult(
      title: 'Commit ready for review',
      output:
          'Staged ${requestedPaths.length} file(s) and opened the commit '
          'review screen. No commit was created and nothing was pushed. '
          'The user must approve with Commit or Commit + Push.',
      metadata: {
        'stagedPaths': requestedPaths,
        'title': draft.title,
        'description': draft.description,
        'awaitingHumanApproval': true,
      },
    );
  }

  @override
  CollapsedSummary collapsedSummary(
    Map<String, dynamic> args,
    ToolResult result,
  ) {
    final count = (result.metadata['stagedPaths'] as List?)?.length ?? 0;
    final total = estimateToolRoundTripTokens(
      toolName: name,
      args: args,
      resultOutput: result.output,
    );
    return CollapsedSummary(
      text: '$count file${count == 1 ? '' : 's'} ready for review',
      argsTokens: total,
      totalTokens: total,
    );
  }
}
