import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'theme/app_theme.dart';
import 'router/app_router.dart';
import 'services/api_client.dart';
import 'services/bundled_inference_service.dart';
import 'services/database_service.dart';
import 'services/inference_service.dart';
import 'services/process_launcher.dart';
import 'services/supervisor_service.dart';
import 'services/hardware_service.dart';
import 'services/model_manager_service.dart';
import 'services/document_service.dart';
import 'services/settings_service.dart';
import 'services/local_inference_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── Initialize settings from SharedPreferences ──
  final settingsService = SettingsService();
  await settingsService.init();

  // ── Initialize local database ──
  final databaseService = DatabaseService();

  // ── Initialize bundled inference engine (primary — zero dependencies) ──
  final bundledInference = BundledInferenceService();
  await bundledInference.init(preferredModel: settingsService.activeModelId);

  // ── Initialize Ollama as optional secondary backend ──
  final localInference = LocalInferenceService();
  if (!bundledInference.available) {
    // Only probe Ollama if bundled engine isn't running
    await localInference.init(preferredModel: settingsService.activeModelId);
  }

  // Sync active model to settings
  if (!settingsService.hasActiveModel) {
    if (bundledInference.available && bundledInference.activeModel != null) {
      settingsService.activeModelId = bundledInference.activeModelPath;
    } else if (localInference.available && localInference.activeModel != null) {
      settingsService.activeModelId = localInference.activeModel;
    }
  }

  // ── Create per-service API clients (backend optional) ──
  final supervisorApi = ApiClient(baseUrl: ServiceUrls.supervisor);
  final modelManagerApi = ApiClient(baseUrl: ServiceUrls.modelManager);

  final supervisorService = SupervisorService();
  final inferenceService = InferenceService();
  final documentService = DocumentService();
  final hardwareService = HardwareService(supervisorApi);
  final modelManagerService = ModelManagerService(modelManagerApi);

  // Try Python backend — non-blocking, app works without it
  try {
    await ProcessLauncher.launchBackend();
    await supervisorApi.checkAvailable();
  } catch (_) {
    logService('main', 'Python backend not available — using local engines');
  }

  runApp(
    MultiProvider(
      providers: [
        Provider<DatabaseService>.value(value: databaseService),
        Provider<ApiClient>.value(value: supervisorApi),
        Provider<InferenceService>.value(value: inferenceService),
        Provider<HardwareService>.value(value: hardwareService),
        Provider<ModelManagerService>.value(value: modelManagerService),
        Provider<SupervisorService>.value(value: supervisorService),
        Provider<DocumentService>.value(value: documentService),
        ChangeNotifierProvider<SettingsService>.value(value: settingsService),
        ChangeNotifierProvider<BundledInferenceService>.value(
            value: bundledInference),
        ChangeNotifierProvider<LocalInferenceService>.value(
            value: localInference),
      ],
      child: const StudiomcApp(),
    ),
  );
}

class StudiomcApp extends StatelessWidget {
  const StudiomcApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Watch SettingsService so theme rebuilds when darkMode changes.
    final settings = context.watch<SettingsService>();

    return MaterialApp.router(
      title: 'Studiomc',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme(),
      darkTheme: AppTheme.darkTheme(),
      themeMode: settings.themeMode,
      routerConfig: appRouter,
    );
  }
}
