# 전공길잡이

진로 기반 과목 추천 및 학습 관리 Flutter 앱입니다.

## 주요 기능

- 진로 키워드 직접 입력
- 5문항 진로 탐색 설문
- 계열별 관련 학과군, 추천 선택과목, 준비 활동, 학습 조언 제공
- 과목별 공부 타이머
- 과목별 누적 공부 시간 저장
- Firebase 연결 시 Firestore 저장, 미연결 시 SharedPreferences 로컬 저장

## 실행

```bash
flutter pub get
flutter run
```

## Firebase 연결

앱은 시작 시 Firebase 초기화를 시도합니다. Firebase 설정이 없거나 Anonymous Auth가 꺼져 있으면 자동으로 로컬 저장 모드로 실행됩니다.

Firebase를 연결하려면 Firebase 프로젝트에서 다음을 활성화하세요.

- Authentication: Anonymous 로그인
- Cloud Firestore

그 다음 Android/iOS/Web 프로젝트 설정을 추가하거나, 실행 시 Dart define으로 Firebase 옵션을 넘기면 됩니다.

```bash
flutter run \
  --dart-define=FIREBASE_API_KEY=your_api_key \
  --dart-define=FIREBASE_APP_ID=your_app_id \
  --dart-define=FIREBASE_MESSAGING_SENDER_ID=your_sender_id \
  --dart-define=FIREBASE_PROJECT_ID=your_project_id \
  --dart-define=FIREBASE_AUTH_DOMAIN=your_project.firebaseapp.com \
  --dart-define=FIREBASE_STORAGE_BUCKET=your_project.appspot.com
```

Firestore 저장 경로:

```text
majorGuideUsers/{anonymousUid}/learning/studyTotals
```
