import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/providers.dart';
import '../providers/environmental_provider.dart';
import '../theme/app_theme.dart';
import '../models/models.dart';
import '../widgets/reusable_widgets.dart';
import '../l10n/app_strings.dart';
import '../services/audio_model_manager.dart';

class EnvironmentalScreen extends StatelessWidget {
  const EnvironmentalScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final env = context.watch<EnvironmentalProvider>();
    final s = AppStrings.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(s.environmentalTitle),
      ),
      body: Column(
        children: [
          // Monitoring Status — truthful state display
          _buildMonitoringStatus(env, s),

          // Active Alert Overlay
          if (env.currentAlert != null)
            _ActiveAlertBanner(event: env.currentAlert!, onDismiss: () => env.dismissAlert(), s: s),

          // Alert History Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  s.alertHistory,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Theme.of(context).textTheme.bodySmall?.color,
                    letterSpacing: 1.2,
                  ),
                ),
                if (env.alertHistory.isNotEmpty)
                  TextButton(
                    onPressed: () => env.clearHistory(),
                    child: Text(s.clearAll),
                  ),
              ],
            ),
          ),

          // Alert History List
          Expanded(
            child: env.alertHistory.isEmpty
                ? EmptyState(
                    icon: Icons.notifications_none,
                    title: s.noAlertsYet,
                    subtitle: s.noAlertsDesc,
                  )
                : ListView.builder(
                    itemCount: env.alertHistory.length,
                    itemBuilder: (context, index) {
                      final event = env.alertHistory.reversed.toList()[index];
                      return AlertCard(
                        event: event,
                        onDismiss: () => env.dismissAlert(event.id),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildMonitoringStatus(EnvironmentalProvider env, AppStrings s) {
    final status = env.status;

    // Determine the visual state for the status banner.
    Color bgColor;
    Color fgColor;
    IconData icon;
    String statusText;

    switch (status) {
      case MonitoringStatus.active:
        bgColor = AppTheme.successLight.withValues(alpha: 0.1);
        fgColor = AppTheme.successLight;
        icon = Icons.volume_up;
        statusText = s.monitoringActiveTitle;
        break;
      case MonitoringStatus.starting:
        bgColor = AppTheme.warningLight.withValues(alpha: 0.1);
        fgColor = AppTheme.warningLight;
        icon = Icons.hourglass_empty;
        statusText = s.monitoringStarting;
        break;
      case MonitoringStatus.permissionDenied:
        bgColor = AppTheme.errorLight.withValues(alpha: 0.1);
        fgColor = AppTheme.errorLight;
        icon = Icons.mic_off;
        statusText = s.microphonePermissionRequired;
        break;
      case MonitoringStatus.recorderFailed:
        bgColor = AppTheme.errorLight.withValues(alpha: 0.1);
        fgColor = AppTheme.errorLight;
        icon = Icons.mic_off;
        statusText = s.microphoneRecorderFailed;
        break;
      case MonitoringStatus.modelUnavailable:
        bgColor = AppTheme.warningLight.withValues(alpha: 0.1);
        fgColor = AppTheme.warningLight;
        icon = Icons.brain_outlined;
        statusText = s.environmentalModelNotInstalled;
        break;
      case MonitoringStatus.taggerFailed:
        bgColor = AppTheme.errorLight.withValues(alpha: 0.1);
        fgColor = AppTheme.errorLight;
        icon = Icons.error_outline;
        statusText = s.audioTaggerFailed;
        break;
      case MonitoringStatus.error:
        bgColor = AppTheme.errorLight.withValues(alpha: 0.1);
        fgColor = AppTheme.errorLight;
        icon = Icons.error_outline;
        statusText = s.monitoringError;
        break;
      case MonitoringStatus.stopping:
        bgColor = Colors.grey.withValues(alpha: 0.1);
        fgColor = Colors.grey;
        icon = Icons.hourglass_bottom;
        statusText = s.monitoringStopping;
        break;
      case MonitoringStatus.off:
        bgColor = Colors.grey.withValues(alpha: 0.1);
        fgColor = Colors.grey;
        icon = Icons.volume_off;
        statusText = s.monitoringOffTitle;
        break;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      color: bgColor,
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: fgColor, size: 32),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      statusText,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: fgColor,
                      ),
                    ),
                    // Show the fine-grained status description when
                    // there's an error — so the user knows exactly what
                    // went wrong instead of a generic "Microphone unavailable".
                    if (env.hasError && status != MonitoringStatus.error) ...[
                      const SizedBox(height: 4),
                      Text(
                        env.environmentalStatus,
                        style: TextStyle(
                          fontSize: 13,
                          color: fgColor.withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => env.toggleMonitoring(),
              icon: Icon(env.monitoringEnabled ? Icons.stop : Icons.play_arrow),
              label: Text(env.monitoringEnabled ? s.stopMonitoring : s.startMonitoring),
              style: ElevatedButton.styleFrom(
                backgroundColor: env.monitoringEnabled ? AppTheme.errorLight : AppTheme.successLight,
                foregroundColor: Colors.white,
              ),
            ),
          ),
          // Show retry button for model-not-installed state.
          if (status == MonitoringStatus.modelUnavailable) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _downloadModel(context),
                icon: const Icon(Icons.download),
                label: Text(s.downloadEnvironmentalModel),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.warningLight,
                  side: BorderSide(color: AppTheme.warningLight),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _downloadModel(BuildContext context) async {
    // Trigger model download — this is a setup action, not a monitoring action.
    final audioModelManager = AudioModelManager.instance;
    await audioModelManager.downloadModel();
  }
}

class _ActiveAlertBanner extends StatelessWidget {
  final SoundEvent event;
  final VoidCallback onDismiss;
  final AppStrings s;

  const _ActiveAlertBanner({required this.event, required this.onDismiss, required this.s});

  IconData _severityIcon(String severity) => switch (severity) {
    'critical' => Icons.error,
    'warning' => Icons.warning_amber_rounded,
    _ => Icons.info_outline,
  };

  String _severityLabel(String severity) => switch (severity) {
    'critical' => s.severityCritical,
    'warning' => s.severityWarning,
    _ => s.severityInfo,
  };

  @override
  Widget build(BuildContext context) {
    final severityColor = AppTheme.alertColor(event.severity);
    final description = EnvironmentalProvider.alertDescriptions[event.type] ?? s.unknownSoundDetected;

    return Semantics(
      label: '${_severityLabel(event.severity)} alert: ${event.type}. $description',
      child: Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: severityColor.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(AppTheme.radiusMD),
          border: Border.all(color: severityColor, width: 2),
        ),
        child: Column(
          children: [
            Row(
              children: [
                Icon(_severityIcon(event.severity), color: severityColor, size: 32),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: severityColor.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              _severityLabel(event.severity).toUpperCase(),
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                color: severityColor,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${event.type} ${s.detected}',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: severityColor,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(description, style: Theme.of(context).textTheme.bodyMedium),
                      const SizedBox(height: 4),
                      Text(
                        '${(event.confidence * 100).toInt()}% match',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: onDismiss,
                style: ElevatedButton.styleFrom(
                  backgroundColor: severityColor,
                  foregroundColor: Colors.white,
                ),
                child: Text(s.dismiss),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
