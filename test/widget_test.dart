import 'package:flutter_test/flutter_test.dart';
import 'package:major_guide/main.dart';

void main() {
  testWidgets('home screen shows the main navigation actions', (tester) async {
    await tester.pumpWidget(
      MajorGuideApp(
        localStudyTimeStore: LocalStudyTimeStore(),
        firebaseStatus: FirebaseConnectionStatus.localOnly(),
      ),
    );

    expect(find.text('전공길잡이'), findsOneWidget);
    expect(find.text('진로 직접 입력'), findsOneWidget);
    expect(find.text('진로 탐색 설문'), findsOneWidget);
    expect(find.text('공부 시간 측정 화면으로 이동'), findsOneWidget);
  });
}
