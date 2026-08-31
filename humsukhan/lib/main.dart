import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'providers/providers.dart';
import 'theme/app_theme.dart';
import 'navigation/app_router.dart';
import 'screens/splash_screen.dart';
import 'l10n/app_strings.dart';
import 'services/supabase_service.dart';
import 'services/scoped_preferences.dart';
import 'services/sound_detection_service.dart';
import 'services/environmental_monitoring_bridge.dart';
import 'models/models.dart';

@pragma('vm:entry-point')
Future<void> environmentalMonitoringBackgroundMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.humsukhan/environmental_monitor');
  final detector = SoundDetectionService.instance;

  // Read the alert policy from SharedPreferences so we can filter events
  // and tell the Android service which feedback mechanisms are enabled.
  final policy = await _readAlertPolicy();

  channel.setMethodCallHandler((call) async {
    if (call.method == 'stop') {
      detector.stopMonitoring();
      await channel.invokeMethod('pipelineState', {'state': 'OFF'});
      return true;
    }
    return null;
  });

  detector.onSoundDetected = (event) {
    // Filter by allowed-alerts policy before forwarding to Android.
    if (!policy.isAllowed(event.type)) return;
    channel.invokeMethod('event', <String, dynamic>{
      'type': event.type,
      'confidence': event.confidence,
      'severity': event.severity,
      'timestamp': event.timestamp.toIso8601String(),
    });
  };

  final result = await detector.startMonitoring(permissionAlreadyGranted: true);
  // Map StartupResult to the coarse state strings the Android service expects.
  // The Flutter-side EnvironmentalProvider uses the fine-grained StartupResult
  // via the iOS path; Android receives this coarse state through the EventChannel.
  final stateString = switch (result) {
    StartupResult.success => 'ACTIVE',
    StartupResult.permissionDenied => 'ERROR',
    StartupResult.recorderFailed => 'ERROR',
    StartupResult.modelUnavailable => 'ERROR',
    StartupResult.taggerFailed => 'ERROR',
    StartupResult.unknownError => 'ERROR',
  };
  await channel.invokeMethod('pipelineState', {
    'state': stateString,
  });

  // Push the policy to the Android service so it can gate vibration.
  if (result == StartupResult.success) {
    await channel.invokeMethod('policy', policy.toJson());
  }
}

/// Read the [AlertPolicy] from SharedPreferences in the background isolate.
@pragma('vm:entry-point')
Future<AlertPolicy> _readAlertPolicy() async {
  final prefs = await SharedPreferences.getInstance();
  final haptic = prefs.getBool('hapticAlerts') ?? true;
  final visual = prefs.getBool('visualAlerts') ?? true;
  final screenFlash = prefs.getBool('screenFlashAlerts') ?? true;
  final flashlight = prefs.getBool('flashAlerts') ?? false;

  final allowed = <String>{};
  final rawAllowed = prefs.getString('allowedAlerts');
  if (rawAllowed != null) {
    try {
      final decoded = jsonDecode(rawAllowed) as Map<String, dynamic>;
      for (final entry in decoded.entries) {
        if (entry.value == true) allowed.add(entry.key);
      }
    } catch (_) {
      // Corrupt — fall through to defaults below.
    }
  }
  if (allowed.isEmpty) {
    allowed.addAll([
      'Fire Alarm', 'Siren', 'Doorbell', 'Knock', 'Phone',
      'Baby Cry', 'Alarm Clock', 'Vehicle Horn', 'Glass Break', 'Dog Bark',
    ]);
  }

  return AlertPolicy(
    haptic: haptic,
    visual: visual,
    screenFlash: screenFlash,
    flashlight: flashlight,
    allowedAlerts: allowed,
  );
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
  ));

  try {
    await SupabaseService.instance.initialize();
  } catch (e) {
    debugPrint('Supabase init failed: $e');
  }

  // Initialize user-scoped preferences (must happen after Supabase init
  // so the current user ID is available for key scoping and migration).
  try {
    await ScopedPreferences.instance.initialize();
  } catch (e) {
    debugPrint('ScopedPreferences init failed: $e');
  }

  runApp(const HumSukhanApp());
}

class HumSukhanApp extends StatefulWidget {
  const HumSukhanApp({super.key});

  @override
  State<HumSukhanApp> createState() => _HumSukhanAppState();
}

class _HumSukhanAppState extends State<HumSukhanApp> {
  bool _showSplash = true;
  String _lastLanguage = 'en';
  bool _settingsWired = false;
  String? _lastUserId;
  AlertPolicy? _lastPolicy;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ChangeNotifierProvider(create: (_) => UserProvider()),
        ChangeNotifierProvider(create: (_) => ConversationProvider()),
        ChangeNotifierProvider(create: (_) => ProfessionalProvider()),
        ChangeNotifierProvider(create: (_) => EnvironmentalProvider()),
        ChangeNotifierProvider(create: (_) => SpeechProvider()),
        ChangeNotifierProvider(create: (_) => QuickReplyProvider()),
        ChangeNotifierProvider(create: (_) => ConnectivityProvider()..initialize()),
      ],
      child: Consumer<SettingsProvider>(
        builder: (context, settings, _) {
          if (settings.appLanguage != _lastLanguage) {
            _lastLanguage = settings.appLanguage;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                context.read<QuickReplyProvider>().switchLanguage(settings.appLanguage);
              }
            });
          }

          if (!_settingsWired) {
            _settingsWired = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                final env = context.read<EnvironmentalProvider>();
                env.setSettingsProvider(settings);
                // Load alert history for the current user (or anonymous).
                final auth = context.read<AuthProvider>();
                final userId = auth.userId;
                _lastUserId = userId;
                env.setUser(userId);
              }
            });
          }

          // Re-scope alert history and reload user-owned providers when
          // the authenticated user changes (sign-in, sign-out, or account
          // switch).  Each provider reads from its own user-scoped
          // SharedPreferences key so local data from different accounts
          // never leaks into each other's scope.
          final currentUserId = context.watch<AuthProvider>().userId;
          if (_settingsWired && currentUserId != _lastUserId) {
            _lastUserId = currentUserId;
            _handleUserChange(context, currentUserId);
          }

          // Push alert policy to the Android foreground service whenever
          // any relevant setting changes.  This keeps native-side vibration
          // and notification behaviour in sync without an app restart.
          final policy = settings.alertPolicy;
          if (_lastPolicy != policy) {
            _lastPolicy = policy;
            EnvironmentalMonitoringBridge.instance.sendAlertPolicy(policy);
          }

          final appLocale = Locale(settings.appLanguage);
          const localizationDelegates = [
            AppStrings.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ];
          const supportedLocales = [Locale('en'), Locale('ur')];
          final isUrdu = settings.appLanguage == 'ur';
          final urduFont = isUrdu ? 'NotoNastaliqUrdu' : null;
          final textDirection = isUrdu ? TextDirection.rtl : TextDirection.ltr;

          // Effective theme: if user toggled high contrast, use the
          // dedicated HC theme as the dark variant.
          final effectiveDarkTheme = settings.isHighContrast
              ? AppTheme.highContrastTheme(fontFamily: urduFont)
              : AppTheme.darkTheme(fontFamily: urduFont);

          if (_showSplash) {
            return MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: AppTheme.lightTheme(fontFamily: urduFont),
              darkTheme: effectiveDarkTheme,
              themeMode: settings.themeMode,
              locale: appLocale,
              supportedLocales: supportedLocales,
              localizationsDelegates: localizationDelegates,
              home: SplashScreen(
                onComplete: () => setState(() => _showSplash = false),
                initializationReady: settings.ready,
              ),
            );
          }

          return Directionality(
            textDirection: textDirection,
            child: MaterialApp(
              title: 'HumSukhan',
              debugShowCheckedModeBanner: false,
              theme: AppTheme.lightTheme(fontFamily: urduFont),
              darkTheme: effectiveDarkTheme,
              themeMode: settings.themeMode,
              initialRoute: settings.isOnboardingComplete ? AppRouter.home : AppRouter.onboarding,
              onGenerateRoute: AppRouter.generateRoute,
              locale: appLocale,
              supportedLocales: supportedLocales,
              localizationsDelegates: localizationDelegates,
              builder: (context, child) {
                // Combine the system text scale with the user's large-text
                // preference.  Cap at 2.0 to prevent extreme layout breakage.
                final systemScale = MediaQuery.of(context).textScaleFactor;
                final userScale = settings.textScaleFactor;
                final effectiveScale = (systemScale * userScale).clamp(0.8, 2.0);
                return MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaleFactor: effectiveScale,
                  ),
                  child: child!,
                );
              },
            ),
          );
        },
      ),
    );
  }

  /// React to an auth state change by switching the active preferences
  /// scope and reloading every user-owned provider.
  ///
  /// The sequence is:
  ///  1. Update [ScopedPreferences] so subsequent scoped-key reads/writes
  ///     target the new user's namespace.
  ///  2. Re-scope [EnvironmentalProvider] (alert history).
  ///  3. Reload [UserProvider], [ProfessionalProvider],
  ///     [ConversationProvider], and [QuickReplyProvider] from the new
  ///     user's scoped keys, triggering cloud sync where applicable.
  void _handleUserChange(BuildContext context, String userId) {
    ScopedPreferences.instance.setUser(userId).then((_) {
      if (!mounted) return;
      context.read<EnvironmentalProvider>().setUser(userId);
      context.read<UserProvider>().reload();
      context.read<ProfessionalProvider>().reload();
      context.read<ConversationProvider>().reload();
      context.read<QuickReplyProvider>().reload();
    });
  }
}
