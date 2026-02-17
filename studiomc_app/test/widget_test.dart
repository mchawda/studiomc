import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:studiomc_app/main.dart';
import 'package:studiomc_app/services/settings_service.dart';

void main() {
  testWidgets('App launches', (WidgetTester tester) async {
    final testRouter = GoRouter(
      initialLocation: '/test',
      routes: [
        GoRoute(
          path: '/test',
          builder: (context, state) => const Scaffold(
            body: Center(child: Text('Studiomc')),
          ),
        ),
      ],
    );

    final settings = SettingsService();

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsService>.value(
        value: settings,
        child: StudiomcApp(router: testRouter),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Studiomc'), findsOneWidget);
  });
}
