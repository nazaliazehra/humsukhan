import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/providers.dart';
import '../theme/app_theme.dart';
import '../models/models.dart';
import '../widgets/reusable_widgets.dart';
import '../navigation/app_router.dart';
import '../l10n/app_strings.dart';

/// Sort options for session lists.
enum _SortMode { newest, oldest, title }

/// Professional Mode with 4 tabs: Folders, Classes, Meetings, Lectures.
///
/// Sessions are records that live inside folders and/or contextual
/// categories.  There is NO separate "Sessions" tab — each type-specific
/// tab (Classes, Meetings, Lectures) shows sessions of that type.
class ProfessionalScreen extends StatefulWidget {
  const ProfessionalScreen({super.key});

  @override
  State<ProfessionalScreen> createState() => _ProfessionalScreenState();
}

class _ProfessionalScreenState extends State<ProfessionalScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _searchController = TextEditingController();
  _SortMode _sortMode = _SortMode.newest;

  /// Maps tab index to session type filter.  Index 0 = Folders (no type filter).
  static const _tabTypes = <SessionType?>[
    null, // Folders
    SessionType.class_,
    SessionType.meeting,
    SessionType.lecture,
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  /// The [SessionType] determined by the current tab, or `null` for Folders.
  SessionType? get _currentTabType => _tabTypes[_tabController.index];

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(s.professionalTitle),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: s.foldersTab, icon: const Icon(Icons.folder)),
            Tab(text: s.classesTab, icon: const Icon(Icons.class_)),
            Tab(text: s.meetingsTab, icon: const Icon(Icons.meeting_room)),
            Tab(text: s.lecturesTab, icon: const Icon(Icons.school)),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildFoldersTab(context, s),
          _buildTypeTab(context, s, SessionType.class_),
          _buildTypeTab(context, s, SessionType.meeting),
          _buildTypeTab(context, s, SessionType.lecture),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showCreateSessionDialog(
          context,
          s,
          initialType: _currentTabType,
        ),
        icon: const Icon(Icons.add),
        label: Text(s.newSession),
      ),
    );
  }

  // ── Folders tab ──────────────────────────────────────────────────────

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
                    final sessionCount =
                        pro.getSessionsForFolder(folder.id).length;
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
                              onPressed: () =>
                                  _confirmDeleteFolder(context, pro, folder, s),
                            ),
                          ),
                          const Icon(Icons.chevron_right),
                        ],
                      ),
                      onTap: () =>
                          _openFolder(context, folder.id, folder.name, s),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ── Type-specific tab (Classes / Meetings / Lectures) ────────────────

  Widget _buildTypeTab(
      BuildContext context, AppStrings s, SessionType type) {
    final pro = context.watch<ProfessionalProvider>();
    final query = _searchController.text.toLowerCase();

    var sessions = pro.sessions
        .where((sess) => sess.status == SessionStatus.completed)
        .where((sess) => sess.type == type)
        .where((sess) =>
            query.isEmpty || sess.title.toLowerCase().contains(query))
        .toList();

    switch (_sortMode) {
      case _SortMode.newest:
        sessions.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      case _SortMode.oldest:
        sessions.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      case _SortMode.title:
        sessions.sort(
            (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    }

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
                      borderRadius:
                          BorderRadius.circular(AppTokens.radiusFull),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    fillColor: Theme.of(context).cardColor,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
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
                  PopupMenuItem(
                      value: _SortMode.newest, child: Text(s.sortNewest)),
                  PopupMenuItem(
                      value: _SortMode.oldest, child: Text(s.sortOldest)),
                  PopupMenuItem(
                      value: _SortMode.title, child: Text(s.sortTitle)),
                ],
              ),
            ],
          ),
        ),

        // Session list
        Expanded(
          child: sessions.isEmpty
              ? EmptyState(
                  icon: Icons.event_note,
                  title: s.noSavedSessions,
                  subtitle: s.noSavedSessionsDesc,
                  buttonText: s.startSession,
                  onButtonPressed: () => _showCreateSessionDialog(
                    context,
                    s,
                    initialType: type,
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(top: 4, bottom: 80),
                  itemCount: sessions.length,
                  itemBuilder: (context, index) {
                    final session = sessions[index];
                    return GestureDetector(
                      onLongPress: () => _showMoveToFolderDialog(
                          context, pro, session, s),
                      child: SessionCard(
                        session: session,
                        insight: pro.getInsightForSession(session.id),
                        onTap: () => Navigator.pushNamed(
                          context,
                          AppRouter.sessionDetail,
                          arguments: session.id,
                        ),
                        onDelete: () =>
                            _confirmDelete(context, session, s),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  void _openFolder(
      BuildContext context, String? folderId, String title, AppStrings s) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FolderViewScreen(folderId: folderId, title: title),
      ),
    );
  }

  // ── Create session dialog (contextual type) ──────────────────────────

  void _showCreateSessionDialog(BuildContext context, AppStrings s,
      {SessionType? initialType}) {
    final titleController = TextEditingController();
    final settings = context.read<SettingsProvider>();
    final pro = context.read<ProfessionalProvider>();

    // When inside a type-specific tab, the type is determined by context.
    // When inside Folders, the user picks the type.
    final bool typeIsContextual = initialType != null;
    SessionType selectedType = initialType ?? SessionType.meeting;

    // Use the user's preferred default retention.
    int retentionDays = [1, 7, 15]
        .reduce((a, b) => (a - settings.defaultRetentionDays).abs() <
                (b - settings.defaultRetentionDays).abs()
            ? a
            : b);

    // When contextual, also ask which folder (optional).
    String? selectedFolderId;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => Padding(
          padding: EdgeInsets.fromLTRB(
              24, 24, 24, MediaQuery.of(ctx).viewInsets.bottom + 24),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.newSession,
                    style: Theme.of(context).textTheme.headlineMedium),
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

                // Type selector — only shown when NOT contextual
                if (!typeIsContextual) ...[
                  DropdownButtonFormField<SessionType>(
                    value: selectedType,
                    decoration: InputDecoration(labelText: s.sessionType),
                    items: [
                      DropdownMenuItem(
                          value: SessionType.meeting,
                          child: Text(s.meetingType)),
                      DropdownMenuItem(
                          value: SessionType.lecture,
                          child: Text(s.lectureType)),
                      DropdownMenuItem(
                          value: SessionType.class_,
                          child: Text(s.classType)),
                    ],
                    onChanged: (v) =>
                        setModalState(() => selectedType = v ?? selectedType),
                  ),
                  const SizedBox(height: 16),
                ],

                // Folder selector
                DropdownButtonFormField<String?>(
                  value: selectedFolderId,
                  decoration: InputDecoration(labelText: s.foldersTab),
                  items: [
                    DropdownMenuItem<String?>(
                      value: null,
                      child: Text(s.generalFolder),
                    ),
                    ...pro.folders.map((f) => DropdownMenuItem<String?>(
                          value: f.id,
                          child: Text(f.name),
                        )),
                  ],
                  onChanged: (v) =>
                      setModalState(() => selectedFolderId = v),
                ),
                const SizedBox(height: 16),

                // Retention
                DropdownButtonFormField<int>(
                  value: retentionDays,
                  decoration: InputDecoration(labelText: s.retentionPeriod),
                  items: [
                    DropdownMenuItem(
                        value: 1, child: Text(s.retention1Day)),
                    DropdownMenuItem(
                        value: 7, child: Text(s.retention7Days)),
                    DropdownMenuItem(
                        value: 15, child: Text(s.retention15Days)),
                  ],
                  onChanged: (v) =>
                      setModalState(() => retentionDays = v ?? retentionDays),
                ),
                const SizedBox(height: 24),
                PrimaryActionButton(
                  label: s.startSession,
                  icon: Icons.play_arrow,
                  onPressed: () async {
                    if (titleController.text.trim().isEmpty) return;
                    final session = await pro.createSession(
                      title: titleController.text.trim(),
                      type: selectedType,
                      folderId: selectedFolderId,
                      retentionDays: retentionDays,
                    );
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (context.mounted) {
                      Navigator.pushNamed(context, AppRouter.sessionLive,
                          arguments: session.id);
                    }
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Create folder dialog ──────────────────────────────────────────────

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
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(s.cancel)),
          TextButton(
            onPressed: () async {
              if (controller.text.trim().isNotEmpty) {
                await context
                    .read<ProfessionalProvider>()
                    .createFolder(controller.text.trim());
                if (ctx.mounted) Navigator.pop(ctx);
              }
            },
            child: Text(s.create),
          ),
        ],
      ),
    );
  }

  // ── Delete session (with undo) ───────────────────────────────────────

  void _confirmDelete(
      BuildContext context, ProfessionalSession session, AppStrings s) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.deleteSessionConfirm),
        content: Text(s.deleteSessionDesc),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(s.cancel)),
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
                        onPressed: () =>
                            pro.restoreSession(session, insight: insight),
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

  // ── Move to folder ───────────────────────────────────────────────────

  void _showMoveToFolderDialog(BuildContext context, ProfessionalProvider pro,
      ProfessionalSession session, AppStrings s) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.moveToFolder),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              // General (no folder)
              ListTile(
                leading: Icon(Icons.folder,
                    color: session.folderId == null
                        ? AppTheme.primaryLight
                        : AppTokens.mutedSageGray),
                title: Text(s.generalFolder),
                selected: session.folderId == null,
                onTap: () async {
                  await pro.moveSessionToFolder(session.id, null);
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              ),
              // Custom folders
              ...pro.folders.map((folder) => ListTile(
                    leading: Icon(Icons.folder,
                        color: session.folderId == folder.id
                            ? AppTheme.primaryLight
                            : AppTokens.mutedSageGray),
                    title: Text(folder.name),
                    selected: session.folderId == folder.id,
                    onTap: () async {
                      await pro.moveSessionToFolder(session.id, folder.id);
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
                  )),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(s.cancel)),
        ],
      ),
    );
  }

  // ── Delete folder ─────────────────────────────────────────────────────

  void _confirmDeleteFolder(BuildContext context, ProfessionalProvider pro,
      Folder folder, AppStrings s) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.deleteFolderConfirm),
        content: Text(s.deleteFolderDesc),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(s.cancel)),
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

// ── Folder view screen ───────────────────────────────────────────────────

/// Displays sessions inside a specific folder (or the General "no folder"
/// bucket).  Includes a "Move to Folder" option on each session card.
class FolderViewScreen extends StatelessWidget {
  final String? folderId;
  final String title;
  const FolderViewScreen(
      {super.key, required this.folderId, required this.title});

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
                return GestureDetector(
                  onLongPress: () => _showMoveToFolderDialog(
                      context, pro, session, s),
                  child: SessionCard(
                    session: session,
                    insight: pro.getInsightForSession(session.id),
                    onTap: () => Navigator.pushNamed(
                      context,
                      AppRouter.sessionDetail,
                      arguments: session.id,
                    ),
                  ),
                );
              },
            ),
    );
  }

  void _showMoveToFolderDialog(BuildContext context, ProfessionalProvider pro,
      ProfessionalSession session, AppStrings s) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.moveToFolder),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: Icon(Icons.folder,
                    color: session.folderId == null
                        ? AppTheme.primaryLight
                        : AppTokens.mutedSageGray),
                title: Text(s.generalFolder),
                selected: session.folderId == null,
                onTap: () async {
                  await pro.moveSessionToFolder(session.id, null);
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              ),
              ...pro.folders.map((folder) => ListTile(
                    leading: Icon(Icons.folder,
                        color: session.folderId == folder.id
                            ? AppTheme.primaryLight
                            : AppTokens.mutedSageGray),
                    title: Text(folder.name),
                    selected: session.folderId == folder.id,
                    onTap: () async {
                      await pro.moveSessionToFolder(session.id, folder.id);
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
                  )),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(s.cancel)),
        ],
      ),
    );
  }
}
