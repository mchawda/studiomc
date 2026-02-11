import 'package:go_router/go_router.dart';
import '../screens/onboarding_screen.dart';
import '../screens/chat_screen.dart';
import '../screens/models_screen.dart';
import '../screens/documents_screen.dart';
import '../screens/training_screen.dart';
import '../screens/performance_screen.dart';
import '../screens/settings_screen.dart';
import '../widgets/shell/app_shell.dart';

final appRouter = GoRouter(
  initialLocation: '/onboarding',
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
          builder: (context, state) => const ChatScreen(),
        ),
        GoRoute(
          path: '/chat/:chatId',
          builder: (context, state) => ChatScreen(
            chatId: state.pathParameters['chatId'],
          ),
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
