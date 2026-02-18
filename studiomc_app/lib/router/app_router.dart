// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import '../screens/onboarding_screen.dart';
import '../screens/chat_screen.dart';
import '../screens/models_screen.dart';
import '../screens/documents_screen.dart';
import '../screens/training_screen.dart';
import '../screens/performance_screen.dart';
import '../screens/settings_screen.dart';
import '../services/settings_service.dart';
import '../widgets/shell/app_shell.dart';

GoRouter buildAppRouter(SettingsService settings) {
  return GoRouter(
    initialLocation: settings.onboardingComplete ? '/chat' : '/onboarding',
    redirect: (context, state) {
      final onboarding = state.matchedLocation == '/onboarding';

      // If onboarding is complete and user lands on /onboarding, skip to chat
      if (onboarding && settings.onboardingComplete) {
        return '/chat';
      }

      return null; // no redirect
    },
    routes: [
      GoRoute(
        path: '/onboarding',
        builder: (context, state) => const OnboardingScreen(),
      ),
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(
            path: '/chat',
            builder: (context, state) {
              final extra = state.extra as Map<String, String>?;
              return ChatScreen(
                key: extra != null ? ValueKey(extra['docId']) : null,
                docId: extra?['docId'],
                docName: extra?['docName'],
              );
            },
          ),
          GoRoute(
            path: '/chat/:chatId',
            builder: (context, state) {
              final chatId = state.pathParameters['chatId'];
              return ChatScreen(
                key: ValueKey(chatId),
                chatId: chatId,
              );
            },
          ),
          GoRoute(
            path: '/models',
            builder: (context, state) => const ModelsScreen(),
          ),
          GoRoute(
            path: '/documents',
            builder: (context, state) => const DocumentsScreen(),
          ),
          GoRoute(
            path: '/training',
            builder: (context, state) => const TrainingScreen(),
          ),
          GoRoute(
            path: '/performance',
            builder: (context, state) => const PerformanceScreen(),
          ),
          GoRoute(
            path: '/settings',
            builder: (context, state) => const SettingsScreen(),
          ),
        ],
      ),
    ],
  );
}
