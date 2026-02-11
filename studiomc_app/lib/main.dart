// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'theme/app_theme.dart';
import 'router/app_router.dart';
import 'services/api_client.dart';
import 'services/bundled_inference_service.dart';
import 'services/database_service.dart';
import 'services/inference_service.dart';
import 'services/orchestrator_service.dart';
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

  // ── Initialize SpliceLLM (Python sidecar) ──
  final bundledInference = BundledInferenceService();
  // Start in background — don't block app launch
  bundledInference.init(preferredModel: settingsService.activeModelId);

  // ── Initialize Ollama (primary local inference for small models) ──
  final localInference = LocalInferenceService();
  await localInference.init(preferredModel: settingsService.activeModelId);

  // Sync active model to settings
  if (!settingsService.hasActiveModel &&
      localInference.available &&
      localInference.activeModel != null) {
    settingsService.activeModelId = localInference.activeModel;
  }

  // ── Create per-service API clients ──
  final supervisorApi = ApiClient(baseUrl: ServiceUrls.supervisor);
  final modelManagerApi = ApiClient(baseUrl: ServiceUrls.modelManager);

  // Start full backend (supervisor + documents, clara, etc.) in background so
  // Documents and other features can use it. Safe to call multiple times.
  ProcessLauncher.launchBackend().then((_) {
    supervisorApi.checkAvailable();
  });

  final supervisorService = SupervisorService();
  final inferenceService = InferenceService();
  final orchestratorService = OrchestratorService();
  final documentService = DocumentService();
  final hardwareService = HardwareService(supervisorApi);
  final modelManagerService = ModelManagerService(modelManagerApi);

  runApp(
    MultiProvider(
      providers: [
        Provider<DatabaseService>.value(value: databaseService),
        Provider<ApiClient>.value(value: supervisorApi),
        Provider<InferenceService>.value(value: inferenceService),
        Provider<OrchestratorService>.value(value: orchestratorService),
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
