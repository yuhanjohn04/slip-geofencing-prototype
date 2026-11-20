import 'package:flutter_test/flutter_test.dart';
import 'package:slip_gps_test/main.dart';

void main() {
  testWidgets('Slip field test app loads', (WidgetTester tester) async {
    await tester.pumpWidget(const SlipGpsTestApp());
    expect(find.textContaining('Geofencing'), findsWidgets);
  });
}
