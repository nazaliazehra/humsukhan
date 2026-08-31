import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/providers.dart';
import '../theme/app_theme.dart';
import '../models/models.dart';
import '../widgets/reusable_widgets.dart';
import '../navigation/app_router.dart';
import '../l10n/app_strings.dart';

/// Sort options for the sessions list.
enum _SortMode { newest, oldest, title }

class ProfessionalScreen extends StatefulWidget {
  const ProfessionalScreen({super.key});

  @override
  State<ProfessionalScreen> createState() => _ProfessionalScreenState();
}

class _ProfessionalScreenState extends State<ProfessionalScreen> {
  // ── Search & filter state ──
  final TextEditingController _searchController = TextEditingController();
  SessionType? _typeFilter;
  _SortMode _sortMode = _SortMode.newest;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(s.professionalTitle),
          bottom: TabBar(
            tabs: [
              Tab(text: s.sessionsTab, icon: const Icon(Icons.event_note)),
              Tab(text: s.foldersTab, icon: const Icon(Icons.folder)),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildSessionsTab(context, s),
            _buildFoldersTab(context, s),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _showCreateSessionDialog(context, s),
          icon: const Icon(Icons.add),
          label: Text(s.newSession),
        ),
      ),
    );
  }

  // ── Sessions tab ────────────────────────────────────────────────────────

  Widget _buildSessionsTab(BuildContext context, AppStrings s) {
    final pro = context.watch<ProfessionalProvider>();

    return Column(
      children: [
        // Search bar + sort
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: s.searchSessions,
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _searchController.clear();
                              setState(() {});
                            },
                          )
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppTokens.radiusFull),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    fillColor: Theme.of(context).cardColor,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    isDense: true,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              PopupMenuButton<_SortMode>(
                icon: const Icon(Icons.sort, size: 22),
                tooltip: s.sortLabel,
                onSelected: (mode) => setState(() => _sortMode = mode),
                itemBuilder: (_) => [
                  PopupMenuItem(value: _SortMode.newest, child: Text(s.sortNewest)),
                  PopupMenuItem(value: _SortMode.oldest, child: Text(s.sortOldest)),
                  PopupMenuItem(value: _SortMode.title, child: Text(s.sortTitle)),
                ],
              ),
            ],
          ),
        ),

        // Type filter chips
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _FilterChip(
                  label: s.filterAll,
                  selected: _typeFilter == null,
                  onSelected: () => setState(() => _typeFilter = null),
                ),
                _FilterChip(
                  label: s.filterMeetings,
                  selected: _typeFilter == SessionType.meeting,
                  onSelected: () => setState(() => _typeFilter = SessionType.meeting),
                ),
                _FilterChip(
                  label: s.filterLectures,
                  selected: _typeFilter == SessionType.lecture,
                  onSelected: () => setState(() => _typeFilter = SessionType.lecture),
                ),
                _FilterChip(
                  label: s.filterClasses,
                  selected: _typeFilter == SessionType.class_,
                  onSelected: () => setState(() => _typeFilter = SessionType.class_),
                ),
              ],
            ),
          ),
        ),

        // Session list
        Expanded(child: _buildSessionList(context, pro, s)),
      ],
    );
  }

  Widget _buildSessionList(BuildContext context, ProfessionalProvider pro, AppStrings s) {
    final query = _searchController.text.toLowerCase();
    var filtered = pro.sessions
        .where((sess) => sess.status == SessionStatus.completed)
        .where((sess) => _typeFilter == null || sess.type == _typeFilter)
        .where((sess) => query.isEmpty || sess.title.toLowerCase().contains(query))
        .toList();

    switch (_sortMode) {
      case _SortMode.newest:
        filtered.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      case _SortMode.oldest:
        filtered.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      case _SortMode.title:
        filtered.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    }

    if (pro.sessions.where((sess) => sess.status == SessionStatus.completed).isEmpty) {
      return EmptyState(
        icon: Icons.event_note,
        title: s.noSavedSessions,
        subtitle: s.noSavedSessionsDesc,
        buttonText: s.startSession,
        onButtonPressed: () => _showCreateSessionDialog(context, s),
      );
    }

    if (filtered.isEmpty) {
      return EmptyState(
        icon: Icons.search_off,
        title: s.noSearchResults,
        subtitle: s.noSearchResultsDesc,
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(top: 4, bottom: 80),
      itemCount: filtered.length,
      itemBuilder: (context, index) {
        final session = filtered[index];
        return SessionCard(
          session: session,
          insight: pro.getInsightForSession(session.id),
          onTap: () => Navigator.pushNamed(context, AppRouter.sessionDetail, arguments: session.id),
          onDelete: () => _confirmDelete(context, session, s),
        );
      },
    );
  }

  // ── Folders tab ─────────────────────────────────────────────────────────

  Widget _buildFoldersTab(BuildContext context, AppStrings s) {
    final pro = context.watch<ProfessionalProvider>();
    final generalCount = pro.getSessionsForFolder(null).length;

    return Column(
      children: [
        // General folder — always present
        ListTile(
          leading: Icon(Icons.folder, color: AppTheme.primaryLight),
          title: Text(s.generalFolder),
          subtitle: Text('$generalCount ${s.sessionsCount}'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _openFolder(context, null, s.generalFolder, s),
        ),
        const Divider(height: 1),

        Expanded(
          child: pro.folders.isEmpty
              ? EmptyState(
                  icon: Icons.folder_open,
                  title: s.noFoldersYet,
                  subtitle: s.noFoldersDesc,
                  buttonText: s.createFolder,
                  onButtonPressed: () => _showCreateFolderDialog(context, s),
                )
              : ListView.builder(
                  itemCount: pro.folders.length,
                  itemBuilder: (context, index) {
                    final folder = pro.folders[index];
                    final sessionCount = pro.getSessionsForFolder(folder.id).length;
                    return ListTile(
                      leading: Icon(Icons.folder, color: AppTheme.primaryLight),
                      title: Text(folder.name),
                      subtitle: Text('$sessionCount ${s.sessionsCount}'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Semantics(
                            label: s.deleteFolderLabel(folder.name),
                            button: true,
                            child: IconButton(
                              tooltip: s.deleteFolderAction,
                              icon: const Icon(Icons.delete_outline, size: 20),
                              onPressed: () => _confirmDeleteFolder(context, pro, folder, s),
                            ),
                          ),
                          const Icon(Icons.chevron_right),
                        ],
                      ),
                      onTap: () => _openFolder(context, folder.id, folder.name, s),
                    );
                  },
                ),
        ),
      ],
    );
  }

  void _openFolder(BuildContext context, String? folderId, String title, AppStrings s) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FolderViewScreen(folderId: folderId, title: title),
      ),
    );
  }

  // ── Create session dialog ───────────────────────────────────────────────

  void _showCreateSessionDialog(BuildContext context, AppStrings s) {
    final titleController = TextEditingController();
    final settings = context.read<SettingsProvider>();
    SessionType selectedType = SessionType.meeting;
    // Use the user's preferred default retention, snapped to a valid option.
    int retentionDays = [1, 7, 15]
        .reduce((a, b) => (a - settings.defaultRetentionDays).abs() < (b - settings.defaultRetentionDays).abs() ? a : b);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => Padding(
          padding: EdgeInsets.fromLTRB(24, 24, 24, MediaQuery.of(ctx).viewInsets.bottom + 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s.newSession, style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 24),
              TextField(
                controller: titleController,
                decoration: InputDecoration(
                  labelText: s.sessionTitle,
                  hintText: s.sessionTitleHint,
                ),
                autofocus: true,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<SessionType>(
                initialValue: selectedType,
                decoration: InputDecoration(labelText: s.sessionType),
                items: [
                  DropdownMenuItem(value: SessionType.meeting, child: Text(s.meetingType)),
                  DropdownMenuItem(value: SessionType.lecture, child: Text(s.lectureType)),
                  DropdownMenuItem(value: SessionType.class_, child: Text(s.classType)),
                ],
                onChanged: (v) => setModalState(() => selectedType = v ?? selectedType),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<int>(
                initialValue: retentionDays,
                decoration: InputDecoration(labelText: s.retentionPeriod),
                items: [
                  DropdownMenuItem(value: 1, child: Text(s.retention1Day)),
                  DropdownMenuItem(value: 7, child: Text(s.retention7Days)),
                  DropdownMenuItem(value: 15, child: Text(s.retention15Days)),
                ],
                onChanged: (v) => setModalState(() => retentionDays = v ?? retentionDays),
              ),
              const SizedBox(height: 24),
              PrimaryActionButton(
                label: s.startSession,
                icon: Icons.play_arrow,
                onPressed: () async {
                  if (titleController.text.trim().isEmpty) return;
                  final pro = context.read<ProfessionalProvider>();
                  final session = await pro.createSession(
                    title: titleController.text.trim(),
                    type: selectedType,
                    retentionDays: retentionDays,
                  );
                  if (ctx.mounted) Navigator.pop(ctx);
                  if (context.mounted) {
                    Navigator.pushNamed(context, AppRouter.sessionLive, arguments: session.id);
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Create folder dialog ────────────────────────────────────────────────

  void _showCreateFolderDialog(BuildContext context, AppStrings s) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.createFolder),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(hintText: s.folderName),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.cancel)),
          TextButton(
            onPressed: () async {
              if (controller.text.trim().isNotEmpty) {
                await context.read<ProfessionalProvider>().createFolder(controller.text.trim());
                if (ctx.mounted) Navigator.pop(ctx);
              }
            },
            child: Text(s.create),
          ),
        ],
      ),
    );
  }

  // ── Delete session (with undo) ─────────────────────────────────────────

  void _confirmDelete(BuildContext context, ProfessionalSession session, AppStrings s) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.deleteSessionConfirm),
        content: Text(s.deleteSessionDesc),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.cancel)),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final pro = context.read<ProfessionalProvider>();
              final insight = pro.getInsightForSession(session.id);
              await pro.deleteSession(session.id);
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(
                    SnackBar(
                      content: Text(s.sessionDeleted),
                      action: SnackBarAction(
                        label: s.undo,
                        onPressed: () => pro.restoreSession(session, insight: insight),
                      ),
                    ),
                  );
              }
            },
            child: Text(s.delete, style: const TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  // ── Delete folder ───────────────────────────────────────────────────────

  void _confirmDeleteFolder(BuildContext context, ProfessionalProvider pro, Folder folder, AppStrings s) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.deleteFolderConfirm),
        content: Text(s.deleteFolderDesc),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.cancel)),
          TextButton(
            onPressed: () {
              pro.deleteFolder(folder.id);
              Navigator.pop(ctx);
            },
            child: Text(s.delete, style: const TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}

// ── Filter chip ──────────────────────────────────────────────────────────

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onSelected;
  const _FilterChip({required this.label, required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onSelected(),
        selectedColor: AppTokens.deepSage.withValues(alpha: 0.18),
        labelStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: selected ? AppTokens.deepSage : AppTokens.textMuted,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4),
      ),
    );
  }
}

// ── Folder view screen ───────────────────────────────────────────────────

class FolderViewScreen extends StatelessWidget {
  final String? folderId;
  final String title;
  const FolderViewScreen({super.key, required this.folderId, required this.title});

  @override
  Widget build(BuildContext context) {
    final pro = context.watch<ProfessionalProvider>();
    final sessions = pro.getSessionsForFolder(folderId)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final s = AppStrings.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: sessions.isEmpty
          ? EmptyState(
              icon: Icons.folder_open,
              title: s.sessionsInFolder,
              subtitle: s.sessionsInFolderDesc,
            )
          : ListView.builder(
              padding: const EdgeInsets.only(top: 8, bottom: 16),
              itemCount: sessions.length,
              itemBuilder: (context, index) {
                final session = sessions[index];
                return SessionCard(
                  session: session,
                  insight: pro.getInsightForSession(session.id),
                  onTap: () => Navigator.pushNamed(
                    context,
                    AppRouter.sessionDetail,
                    arguments: session.id,
                  ),
                );
              },
            ),
    );
  }
}
