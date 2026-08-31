import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../providers/providers.dart';
import '../widgets/reusable_widgets.dart';
import '../l10n/app_strings.dart';
import '../services/database_service.dart';
import '../services/supabase_service.dart';
import '../services/alert_service.dart';
import '../services/scoped_preferences.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final user = context.watch<UserProvider>();
    final s = AppStrings.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(s.settingsTitle)),
      body: ListView(
        children: [
          // Profile Section
          _SectionHeader(title: s.profile),
          ListTile(
            leading: _ProfileAvatar(user: user, radius: 20),
            title: Text(user.profile?.name ?? s.setupProfile),
            subtitle: Text(user.profile?.preferredLanguage ?? s.tapToEdit),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showEditProfileDialog(context, s),
          ),

          // Auth Section
          Consumer<AuthProvider>(
            builder: (_, auth, child) => Column(
              children: [
                ListTile(
                  leading: Icon(
                    auth.isAuthenticated ? Icons.cloud_done : Icons.cloud_off,
                    color: auth.isAuthenticated ? Colors.green : Colors.grey,
                  ),
                  title: Text(
                    auth.isAuthenticated
                        ? s.syncedWithCloud
                        : s.notSignedIn,
                  ),
                  subtitle: Text(
                    auth.isAuthenticated
                        ? (auth.user?.email ?? s.anonymousUser)
                        : s.signInToSync,
                  ),
                  trailing: auth.isAuthenticated
                      ? TextButton(
                          onPressed: () async {
                            await auth.signOut();
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(s.signedOut)),
                              );
                            }
                          },
                          child: Text(s.signOut),
                        )
                      : TextButton(
                          onPressed: () => Navigator.pushNamed(context, '/auth'),
                          child: Text(s.signIn),
                        ),
                ),
              ],
            ),
          ),

          // App Language
          _SectionHeader(title: s.appLanguage),
          ListTile(
            title: Text(s.appLanguage),
            subtitle: Text(settings.appLanguage == 'ur' ? s.languageUrdu : s.languageEnglish),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showAppLanguageDialog(context, settings, s),
          ),

          // Accessibility Section
          _SectionHeader(title: s.accessibility),
          SwitchListTile(
            title: Text(s.darkMode),
            subtitle: Text(settings.simplifiedLanguage
                ? s.darkModeSimple
                : s.darkModeDesc),
            value: settings.isDarkMode,
            onChanged: (_) => settings.toggleDarkMode(),
          ),
          SwitchListTile(
            title: Text(s.highContrast),
            subtitle: Text(settings.simplifiedLanguage
                ? s.highContrastSimple
                : s.highContrastDesc),
            value: settings.isHighContrast,
            onChanged: (_) => settings.toggleHighContrast(),
          ),
          SwitchListTile(
            title: Text(s.largeText),
            subtitle: Text(settings.simplifiedLanguage
                ? s.largeTextSimple
                : s.largeTextDesc),
            value: settings.isLargeText,
            onChanged: (_) => settings.toggleLargeText(),
          ),
          SwitchListTile(
            title: Text(s.simplifiedLanguage),
            subtitle: Text(settings.simplifiedLanguage
                ? s.simplifiedOnDesc
                : s.simplifiedLanguageDesc),
            value: settings.simplifiedLanguage,
            onChanged: (_) => settings.toggleSimplifiedLanguage(),
          ),
          ListTile(
            title: Text(s.captionTextSize),
            subtitle: Text('${settings.captionTextSize.toInt()} sp'),
            trailing: SizedBox(
              width: 200,
              child: Slider(
                value: settings.captionTextSize,
                min: 16,
                max: 48,
                divisions: 16,
                label: '${settings.captionTextSize.toInt()}',
                onChanged: (v) => settings.setCaptionTextSize(v),
              ),
            ),
          ),

          // Alert Preferences
          _SectionHeader(title: s.alertPreferences),
          SwitchListTile(
            title: Text(s.hapticAlerts),
            subtitle: Text(settings.simplifiedLanguage
                ? s.hapticSimple
                : s.hapticAlertsDesc),
            value: settings.hapticAlerts,
            onChanged: (_) => settings.toggleHapticAlerts(),
          ),
          SwitchListTile(
            title: Text(s.visualAlerts),
            subtitle: Text(settings.simplifiedLanguage
                ? s.visualSimple
                : s.visualAlertsDesc),
            value: settings.visualAlerts,
            onChanged: (_) => settings.toggleVisualAlerts(),
          ),
          SwitchListTile(
            title: Text(s.screenFlashAlerts),
            subtitle: Text(settings.simplifiedLanguage
                ? s.screenFlashSimple
                : s.screenFlashAlertsDesc),
            value: settings.screenFlashAlerts,
            onChanged: (_) => settings.toggleScreenFlashAlerts(),
          ),
          SwitchListTile(
            title: Text(s.flashlightAlerts),
            subtitle: Text(settings.simplifiedLanguage
                ? s.flashlightSimple
                : s.flashlightAlertsDesc),
            value: settings.flashAlerts,
            onChanged: settings.flashlightAvailable
                ? (_) => settings.toggleFlashAlerts()
                : null,
          ),
          if (settings.flashlightAvailable)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.notifications_active),
                label: Text(s.testAlerts),
                onPressed: () {
                  AlertService.instance.triggerTestAlert();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(s.testAlertTriggered),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                s.flashlightUnavailable,
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ),

          // Caption Language
          _SectionHeader(title: s.languageSection),
          ListTile(
            title: Text(s.captionLanguage),
            subtitle: Text(settings.captionLanguage),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showLanguageDialog(context, settings, s),
          ),

          // Speech Recognition
          _SectionHeader(title: s.speechRecognition),
          const _SpeechModelsSection(),

          // Environmental Alerts
          _SectionHeader(title: s.environmentalAlerts),
          ...settings.allowedAlerts.entries.map((entry) =>
            SwitchListTile(
              title: Text(entry.key),
              value: entry.value,
              onChanged: (_) => settings.toggleAllowedAlert(entry.key),
            ),
          ),

          // Privacy & Retention
          _SectionHeader(title: s.privacyRetentionSection),
          ListTile(
            title: Text(s.defaultRetentionPeriod),
            subtitle: Text('${settings.defaultRetentionDays} ${s.sessionsCount}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showRetentionDialog(context, settings, s),
          ),
          ListTile(
            title: Text(s.deleteAllData),
            subtitle: Text(s.deleteAllDataDesc),
            leading: const Icon(Icons.delete_forever, color: Colors.red),
            onTap: () => _confirmDeleteAllData(context, s),
          ),

          // Privacy Info
          _SectionHeader(title: s.privacySection),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: PrivacyNotice(
              text: s.privacyNoticeText,
            ),
          ),

          // About
          _SectionHeader(title: s.aboutSection),
          _AboutSection(),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  void _showEditProfileDialog(BuildContext context, AppStrings s) {
    final user = context.read<UserProvider>();
    final nameController = TextEditingController(text: user.profile?.name ?? '');
    XFile? _pendingImage;

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
              Text(s.editProfile, style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 24),

              // Profile picture section
              Center(
                child: Column(
                  children: [
                    // Avatar preview
                    _ProfileAvatar(
                      user: user,
                      pendingImage: _pendingImage,
                      radius: 40,
                    ),
                    const SizedBox(height: 12),
                    // Image picker buttons
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        TextButton.icon(
                          onPressed: user.isUploadingImage
                              ? null
                              : () async {
                                  final image = await user.pickImage(source: ImageSource.gallery);
                                  if (image != null) {
                                    setModalState(() => _pendingImage = image);
                                  }
                                },
                          icon: const Icon(Icons.photo_library),
                          label: Text(s.gallery),
                        ),
                        const SizedBox(width: 16),
                        TextButton.icon(
                          onPressed: user.isUploadingImage
                              ? null
                              : () async {
                                  final image = await user.pickImage(source: ImageSource.camera);
                                  if (image != null) {
                                    setModalState(() => _pendingImage = image);
                                  }
                                },
                          icon: const Icon(Icons.camera_alt),
                          label: Text(s.camera),
                        ),
                      ],
                    ),
                    // Remove picture button (only if user has a picture)
                    if (user.profile?.hasAvatarImage == true && _pendingImage == null)
                      TextButton(
                        onPressed: user.isUploadingImage
                            ? null
                            : () async {
                                await user.removeProfileImage();
                                if (ctx.mounted) Navigator.pop(ctx);
                              },
                        child: Text(
                          s.removePicture,
                          style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                        ),
                      ),
                    if (user.isUploadingImage)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Name field
              TextField(
                controller: nameController,
                decoration: InputDecoration(labelText: s.nameLabel),
              ),
              const SizedBox(height: 24),

              // Save button
              PrimaryActionButton(
                label: user.isUploadingImage ? s.saving : s.save,
                icon: Icons.save,
                onPressed: user.isUploadingImage
                    ? null
                    : () async {
                        if (nameController.text.trim().isNotEmpty) {
                          // Save name
                          if (user.hasProfile) {
                            await user.saveProfile(
                              user.profile!.copyWith(name: nameController.text.trim()),
                            );
                          } else {
                            await user.createProfile(name: nameController.text.trim());
                          }
                          // Save image if one was picked
                          if (_pendingImage != null) {
                            await user.saveProfileImage(_pendingImage!);
                          }
                          if (ctx.mounted) Navigator.pop(ctx);
                        }
                      },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showAppLanguageDialog(BuildContext context, SettingsProvider settings, AppStrings s) {
    String selected = settings.appLanguage;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: Text(s.appLanguage),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<String>(
                title: Text(s.languageEnglish),
                value: 'en',
                // ignore: deprecated_member_use
                groupValue: selected,
                // ignore: deprecated_member_use
                onChanged: (v) {
                  setModalState(() => selected = v ?? 'en');
                  settings.setAppLanguage('en');
                  Navigator.pop(ctx);
                },
              ),
              RadioListTile<String>(
                title: Text(s.languageUrdu),
                value: 'ur',
                // ignore: deprecated_member_use
                groupValue: selected,
                // ignore: deprecated_member_use
                onChanged: (v) {
                  setModalState(() => selected = v ?? 'ur');
                  settings.setAppLanguage('ur');
                  Navigator.pop(ctx);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showLanguageDialog(BuildContext context, SettingsProvider settings, AppStrings s) {
    String selected = settings.captionLanguage;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: Text(s.captionLanguage),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [s.languageEnglish, s.captionRomanUrdu, s.urduLabel].map((lang) =>
              RadioListTile<String>(
                title: Text(lang),
                value: lang,
                // ignore: deprecated_member_use
                groupValue: selected,
                // ignore: deprecated_member_use
                onChanged: (v) {
                  setModalState(() => selected = v ?? 'English');
                  settings.setCaptionLanguage(v ?? 'English');
                  Navigator.pop(ctx);
                },
              ),
            ).toList(),
          ),
        ),
      ),
    );
  }

  void _showRetentionDialog(BuildContext context, SettingsProvider settings, AppStrings s) {
    int selected = settings.defaultRetentionDays;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: Text(s.defaultRetention),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<int>(
                title: Text(s.retention1Day), value: 1,
                // ignore: deprecated_member_use
                groupValue: selected,
                // ignore: deprecated_member_use
                onChanged: (v) { setModalState(() => selected = v ?? 1); settings.setDefaultRetentionDays(1); Navigator.pop(ctx); }),
              RadioListTile<int>(
                title: Text(s.retention7Days), value: 7,
                // ignore: deprecated_member_use
                groupValue: selected,
                // ignore: deprecated_member_use
                onChanged: (v) { setModalState(() => selected = v ?? 7); settings.setDefaultRetentionDays(7); Navigator.pop(ctx); }),
              RadioListTile<int>(
                title: Text(s.retention15Days), value: 15,
                // ignore: deprecated_member_use
                groupValue: selected,
                // ignore: deprecated_member_use
                onChanged: (v) { setModalState(() => selected = v ?? 15); settings.setDefaultRetentionDays(15); Navigator.pop(ctx); }),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmDeleteAllData(BuildContext context, AppStrings s) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.deleteAllConfirm),
        content: Text(s.deleteAllConfirmDesc),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.cancel)),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              // Delete from Supabase if authenticated
              if (SupabaseService.instance.isAuthenticated) {
                await DatabaseService.instance.deleteAllUserData();
              }
              // Delete local data (only the current user's scoped keys;
              // global app preferences are preserved).
              await ScopedPreferences.instance.clearCurrentUserData();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(s.allDataDeletedMsg)),
                );
              }
            },
            child: Text(s.deleteEverything, style: const TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}

/// Production-ready About section with product description.
///
/// Shows what HumSukhan is, who it helps, key features,
/// privacy information, and current capabilities — without
/// exposing internal model names or debug information.
class _AboutSection extends StatelessWidget {
  const _AboutSection();

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // App identity
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'HumSukhan',
                style: textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                s.appTagline,
                style: textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),

        // What is HumSukhan
        _AboutTile(
          icon: Icons.info_outline,
          title: s.aboutWhatIs,
          description: s.aboutWhatIsDesc,
        ),

        // Who it is for
        _AboutTile(
          icon: Icons.people_outline,
          title: s.aboutWhoFor,
          description: s.aboutWhoForDesc,
        ),

        // Everyday Communication
        _AboutTile(
          icon: Icons.chat_bubble_outline,
          title: s.aboutEveryday,
          description: s.aboutEverydayDesc,
        ),

        // Professional Listening
        _AboutTile(
          icon: Icons.work_outline,
          title: s.aboutProfessional,
          description: s.aboutProfessionalDesc,
        ),

        // Accessibility-first Design
        _AboutTile(
          icon: Icons.accessibility_new,
          title: s.aboutAccessibility,
          description: s.aboutAccessibilityDesc,
        ),

        // Privacy & Local Processing
        _AboutTile(
          icon: Icons.shield_outlined,
          title: s.aboutPrivacy,
          description: s.aboutPrivacyDesc,
        ),

        // Current Capabilities
        _AboutTile(
          icon: Icons.check_circle_outline,
          title: s.aboutCapabilities,
          description: s.aboutCapabilitiesDesc,
        ),

        // Font
        _AboutTile(
          icon: Icons.font_download_outlined,
          title: s.fontLabel,
          description: s.fontDesc,
        ),

        // Version — minimal, not prominent
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Text(
            '${s.aboutVersion} ${s.versionLabel.split('—').first.trim()}',
            style: textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// A single About tile with icon, title, and description.
class _AboutTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;

  const _AboutTile({
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: cs.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _SpeechModelsSection extends StatelessWidget {
  const _SpeechModelsSection();

  @override
  Widget build(BuildContext context) {
    final speech = context.watch<SpeechProvider>();
    final s = AppStrings.of(context);

    return Column(
      children: [
        ListTile(
          leading: Icon(
            speech.isOfflineMode ? Icons.wifi_off : Icons.wifi,
            color: speech.isOfflineMode ? Colors.green : Colors.blue,
          ),
          title: Text(s.currentMode),
          subtitle: Text(speech.sttModeLabel),
          trailing: Text(
            speech.currentLanguage,
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const Divider(height: 1),

        _ModelTile(
          language: s.englishLabel,
          title: s.englishOfflineSpeechTitle,
          description: s.englishOfflineSpeechDesc,
          sizeMB: 80,
          isStreaming: true,
          isReady: speech.isModelReady('English'),
          onDownload: () => speech.downloadOfflineModel('English'),
          onDelete: () => speech.deleteModel('English'),
          s: s,
        ),

        _ModelTile(
          language: s.urduLabel,
          title: s.urduOfflineSpeechTitle,
          description: s.urduOfflineSpeechDesc,
          sizeMB: 239,
          isStreaming: false,
          isReady: speech.isModelReady('Urdu'),
          onDownload: () => speech.downloadOfflineModel('Urdu'),
          onDelete: () => speech.deleteModel('Urdu'),
          s: s,
        ),

        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            s.offlineSttDesc,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).textTheme.bodySmall?.color,
            ),
          ),
        ),
      ],
    );
  }
}

/// Displays the user's profile picture with a graceful fallback to the
/// emoji avatar.  Handles loading errors by showing the emoji instead.
class _ProfileAvatar extends StatelessWidget {
  final UserProvider user;
  final XFile? pendingImage;
  final double radius;

  const _ProfileAvatar({
    required this.user,
    this.pendingImage,
    required this.radius,
  });

  @override
  Widget build(BuildContext context) {
    final avatarUrl = user.avatarImageUrl;

    // If there's a pending image from the picker, show it as a preview.
    if (pendingImage != null) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
        child: ClipOval(
          child: Image.file(
            File(pendingImage!.path),
            width: radius * 2,
            height: radius * 2,
            fit: BoxFit.cover,
            errorBuilder: (ctx, error, stackTrace) {
              // Image loading failure — show emoji fallback.
              return _emojiFallback(context);
            },
          ),
        ),
      );
    }

    // If the user has a saved avatar URL, try to load it.
    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      // Local file path
      if (!avatarUrl.startsWith('http')) {
        return CircleAvatar(
          radius: radius,
          backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
          child: ClipOval(
            child: Image.file(
              File(avatarUrl),
              width: radius * 2,
              height: radius * 2,
              fit: BoxFit.cover,
              errorBuilder: (ctx, error, stackTrace) {
                // File not found or corrupted — show emoji fallback.
                return _emojiFallback(context);
              },
            ),
          ),
        );
      }
      // Network URL (Supabase Storage)
      return CircleAvatar(
        radius: radius,
        backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
        child: ClipOval(
          child: Image.network(
            avatarUrl,
            width: radius * 2,
            height: radius * 2,
            fit: BoxFit.cover,
            errorBuilder: (ctx, error, stackTrace) {
              // Network failure — show emoji fallback.
              return _emojiFallback(context);
            },
          ),
        ),
      );
    }

    // No image — show emoji fallback.
    return _emojiFallback(context);
  }

  Widget _emojiFallback(BuildContext context) {
    return CircleAvatar(
      radius: radius,
      backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
      child: Text(
        user.profile?.avatarEmoji ?? '👤',
        style: TextStyle(fontSize: radius),
      ),
    );
  }
}

class _ModelTile extends StatelessWidget {
  final String language;
  final String title;
  final String description;
  final int sizeMB;
  final bool isStreaming;
  final bool isReady;
  final VoidCallback onDownload;
  final VoidCallback onDelete;
  final AppStrings s;

  const _ModelTile({
    required this.language,
    required this.title,
    required this.description,
    required this.sizeMB,
    required this.isStreaming,
    required this.isReady,
    required this.onDownload,
    required this.onDelete,
    required this.s,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: isReady
            ? Colors.green.withValues(alpha: 0.1)
            : Colors.grey.withValues(alpha: 0.1),
        child: Icon(
          isReady ? Icons.check_circle : Icons.download,
          color: isReady ? Colors.green : Colors.grey,
          size: 20,
        ),
      ),
      title: Text(title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          Text(
            description,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).textTheme.bodySmall?.color,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            isReady ? '${s.readyLabel} · ${sizeMB}MB' : '${s.notDownloaded} · ${sizeMB}MB',
            style: TextStyle(
              color: isReady ? Colors.green : Colors.grey,
              fontSize: 12,
            ),
          ),
        ],
      ),
      trailing: isReady
          ? Semantics(
              label: s.deleteModelLabel(language),
              button: true,
              child: IconButton(
                tooltip: s.deleteModelLabel(language),
                icon: const Icon(Icons.delete_outline, size: 20),
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: Text('${s.delete} $language Model?'),
                      content: Text(s.deleteModelDesc(sizeMB)),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: Text(s.cancel),
                        ),
                        TextButton(
                          onPressed: () {
                            onDelete();
                            Navigator.pop(ctx);
                          },
                          child: Text(s.delete, style: const TextStyle(color: Colors.red)),
                        ),
                      ],
                    ),
                  );
                },
              ),
            )
          : TextButton(
              onPressed: onDownload,
              child: Text(s.downloadLabel),
            ),
    );
  }
}
