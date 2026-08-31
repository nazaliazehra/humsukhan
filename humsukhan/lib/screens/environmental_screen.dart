import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/providers.dart';
import '../theme/app_theme.dart';
import '../models/models.dart';
import '../widgets/reusable_widgets.dart';
import '../l10n/app_strings.dart';

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
          // Monitoring Status
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            color: env.monitoringEnabled
                ? AppTheme.successLight.withValues(alpha: 0.1)
                : Colors.grey.withValues(alpha: 0.1),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      env.monitoringEnabled ? Icons.volume_up : Icons.volume_off,
                      color: env.monitoringEnabled ? AppTheme.successLight : Colors.grey,
                      size: 32,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      env.monitoringEnabled ? s.monitoringActiveTitle : s.monitoringOffTitle,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: env.monitoringEnabled ? AppTheme.successLight : Colors.grey,
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
              ],
            ),
          ),

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
                      // Severity label — not color-only
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
