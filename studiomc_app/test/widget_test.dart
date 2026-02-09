import 'package:flutter_test/flutter_test.dart';
import 'package:studiomc_app/main.dart';

void main() {
  testWidgets('App launches', (WidgetTester tester) async {
    await tester.pumpWidget(const StudiomcApp());
    expect(find.text('Local AI. Private by default.'), findsOneWidget);
  });
}
