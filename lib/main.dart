import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final appStart = await AppStart.bootstrap();
  runApp(
    MajorGuideApp(
      localStudyTimeStore: appStart.localStudyTimeStore,
      firebaseStatus: appStart.firebaseStatus,
    ),
  );
}

class AppStart {
  const AppStart({
    required this.localStudyTimeStore,
    required this.firebaseStatus,
  });

  final LocalStudyTimeStore localStudyTimeStore;
  final FirebaseConnectionStatus firebaseStatus;

  static Future<AppStart> bootstrap() async {
    final localStore = LocalStudyTimeStore();

    try {
      if (Firebase.apps.isEmpty) {
        final options = firebaseOptionsFromDartDefines();
        if (options == null) {
          await Firebase.initializeApp(
            options: DefaultFirebaseOptions.currentPlatform,
          );
        } else {
          await Firebase.initializeApp(options: options);
        }
      }

      return AppStart(
        localStudyTimeStore: localStore,
        firebaseStatus: FirebaseConnectionStatus.connected(),
      );
    } catch (error) {
      debugPrint(
        'Firebase is not ready. Falling back to local storage: $error',
      );
      return AppStart(
        localStudyTimeStore: localStore,
        firebaseStatus: FirebaseConnectionStatus.localOnly(),
      );
    }
  }
}

FirebaseOptions? firebaseOptionsFromDartDefines() {
  const apiKey = String.fromEnvironment('FIREBASE_API_KEY');
  const appId = String.fromEnvironment('FIREBASE_APP_ID');
  const messagingSenderId = String.fromEnvironment(
    'FIREBASE_MESSAGING_SENDER_ID',
  );
  const projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  const authDomain = String.fromEnvironment('FIREBASE_AUTH_DOMAIN');
  const storageBucket = String.fromEnvironment('FIREBASE_STORAGE_BUCKET');

  if (apiKey.isEmpty ||
      appId.isEmpty ||
      messagingSenderId.isEmpty ||
      projectId.isEmpty) {
    return null;
  }

  return FirebaseOptions(
    apiKey: apiKey,
    appId: appId,
    messagingSenderId: messagingSenderId,
    projectId: projectId,
    authDomain: authDomain.isEmpty ? null : authDomain,
    storageBucket: storageBucket.isEmpty ? null : storageBucket,
  );
}

class FirebaseConnectionStatus {
  const FirebaseConnectionStatus({
    required this.connected,
    required this.title,
    required this.message,
    this.uid,
  });

  final bool connected;
  final String title;
  final String message;
  final String? uid;

  factory FirebaseConnectionStatus.connected({String? uid, String? email}) {
    return FirebaseConnectionStatus(
      connected: true,
      uid: uid,
      title: 'Firebase 연결됨',
      message: email == null
          ? '로그인 후 공부 시간 기록이 Firestore에 저장됩니다.'
          : '$email 계정으로 Firestore에 저장됩니다.',
    );
  }

  factory FirebaseConnectionStatus.localOnly() {
    return const FirebaseConnectionStatus(
      connected: false,
      title: '로컬 저장 모드',
      message: 'Firebase 설정 전이라 이 기기의 SharedPreferences에 저장됩니다.',
    );
  }
}

abstract class StudyTimeStore {
  String get label;
  bool get usesFirebase;

  Future<Map<String, int>> loadTotals();

  Future<void> saveTotals(Map<String, int> totals);
}

class LocalStudyTimeStore implements StudyTimeStore {
  static const storageKey = 'study_seconds_by_subject_v1';

  @override
  String get label => 'SharedPreferences';

  @override
  bool get usesFirebase => false;

  @override
  Future<Map<String, int>> loadTotals() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(storageKey);
    if (raw == null) return emptyStudyTotals();

    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return emptyStudyTotals();
    return decodeStudyTotals(decoded);
  }

  @override
  Future<void> saveTotals(Map<String, int> totals) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(storageKey, jsonEncode(totals));
  }
}

class FirestoreStudyTimeStore implements StudyTimeStore {
  FirestoreStudyTimeStore({required this.uid, required this.localFallback});

  final String uid;
  final LocalStudyTimeStore localFallback;

  @override
  String get label => 'Cloud Firestore';

  @override
  bool get usesFirebase => true;

  DocumentReference<Map<String, dynamic>> get _document {
    return FirebaseFirestore.instance
        .collection('majorGuideUsers')
        .doc(uid)
        .collection('learning')
        .doc('studyTotals');
  }

  @override
  Future<Map<String, int>> loadTotals() async {
    try {
      final snapshot = await _document.get();
      if (!snapshot.exists) {
        final localTotals = await localFallback.loadTotals();
        if (localTotals.values.any((seconds) => seconds > 0)) {
          await saveTotals(localTotals);
        }
        return localTotals;
      }

      final data = snapshot.data();
      final totals = data?['totals'];
      if (totals is Map<String, dynamic>) {
        return decodeStudyTotals(totals);
      }
    } catch (error) {
      debugPrint('Firestore load failed. Using local cache: $error');
    }

    return localFallback.loadTotals();
  }

  @override
  Future<void> saveTotals(Map<String, int> totals) async {
    await localFallback.saveTotals(totals);

    try {
      await _document.set({
        'totals': totals,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (error) {
      debugPrint('Firestore save failed. Local cache is preserved: $error');
    }
  }
}

Map<String, int> emptyStudyTotals() {
  return {for (final subject in studySubjects) subject: 0};
}

Map<String, int> decodeStudyTotals(Map<String, dynamic> raw) {
  final totals = emptyStudyTotals();
  for (final subject in studySubjects) {
    final value = raw[subject];
    if (value is int) {
      totals[subject] = value;
    } else if (value is num) {
      totals[subject] = value.toInt();
    }
  }
  return totals;
}

class MajorGuideApp extends StatefulWidget {
  const MajorGuideApp({
    super.key,
    required this.localStudyTimeStore,
    required this.firebaseStatus,
  });

  final LocalStudyTimeStore localStudyTimeStore;
  final FirebaseConnectionStatus firebaseStatus;

  @override
  State<MajorGuideApp> createState() => _MajorGuideAppState();
}

class _MajorGuideAppState extends State<MajorGuideApp> {
  List<String> _careerSubjects = [];
  List<String> _careerCategories = [];

  StudyTimeStore get _studyTimeStore {
    final user = FirebaseAuth.instance.currentUser;
    if (widget.firebaseStatus.connected && user != null && !user.isAnonymous) {
      return FirestoreStudyTimeStore(
        uid: user.uid,
        localFallback: widget.localStudyTimeStore,
      );
    }
    return widget.localStudyTimeStore;
  }

  FirebaseConnectionStatus get _currentFirebaseStatus {
    final user = FirebaseAuth.instance.currentUser;
    if (widget.firebaseStatus.connected && user != null && !user.isAnonymous) {
      return FirebaseConnectionStatus.connected(
        uid: user.uid,
        email: user.email ?? '로그인 사용자',
      );
    }
    return widget.firebaseStatus;
  }

  void _rememberRecommendation(
    List<CareerPath> paths,
    List<String> categories,
  ) {
    final subjects = <String>{};
    for (final path in paths) {
      subjects.addAll(path.subjects);
    }

    setState(() {
      _careerSubjects = subjects.toList();
      _careerCategories = categories;
    });
  }

  void _openResult(
    BuildContext context,
    List<CareerPath> paths, {
    required String sourceTitle,
    List<String>? categories,
  }) {
    final resultCategories =
        categories ?? paths.map((path) => path.category).toList();
    _rememberRecommendation(paths, resultCategories);

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RecommendationResultScreen(
          sourceTitle: sourceTitle,
          categories: resultCategories,
          paths: paths,
          onOpenTimer: () => _openStudyTimer(context),
        ),
      ),
    );
  }

  void _openStudyTimer(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => StudyTimerScreen(
          careerCategories: _careerCategories,
          careerSubjects: _careerSubjects,
          studyTimeStore: _studyTimeStore,
          firebaseStatus: _currentFirebaseStatus,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '전공길잡이',
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: AppColors.background,
        fontFamily: 'Roboto',
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.navy,
          primary: AppColors.navy,
          secondary: AppColors.blue,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.background,
          foregroundColor: AppColors.navy,
          centerTitle: false,
          elevation: 0,
        ),
      ),
      home: widget.firebaseStatus.connected
          ? StreamBuilder<User?>(
              stream: FirebaseAuth.instance.authStateChanges(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Scaffold(
                    body: Center(child: CircularProgressIndicator()),
                  );
                }

                final user = snapshot.data;
                if (user != null && user.isAnonymous) {
                  FirebaseAuth.instance.signOut();
                  return const Scaffold(
                    body: Center(child: CircularProgressIndicator()),
                  );
                }

                if (user == null) {
                  return AuthScreen(firebaseStatus: widget.firebaseStatus);
                }

                return _buildHome(
                  FirebaseConnectionStatus.connected(
                    uid: user.uid,
                    email: user.email ?? '로그인 사용자',
                  ),
                  user,
                );
              },
            )
          : _buildHome(widget.firebaseStatus, null),
    );
  }

  Widget _buildHome(FirebaseConnectionStatus status, User? user) {
    return HomeScreen(
      firebaseStatus: status,
      userEmail: user?.email,
      onSignOut: user == null ? null : () => FirebaseAuth.instance.signOut(),
      onOpenDirectInput: (context) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => DirectInputScreen(
              onShowResult: (paths, sourceTitle) =>
                  _openResult(context, paths, sourceTitle: sourceTitle),
            ),
          ),
        );
      },
      onOpenSurvey: (context) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SurveyScreen(
              onShowResult: (paths, sourceTitle, categories) => _openResult(
                context,
                paths,
                sourceTitle: sourceTitle,
                categories: categories,
              ),
            ),
          ),
        );
      },
      onOpenStudyTimer: _openStudyTimer,
    );
  }
}

class AppColors {
  static const navy = Color(0xFF173B73);
  static const blue = Color(0xFF2F80ED);
  static const lightBlue = Color(0xFFEAF3FF);
  static const sky = Color(0xFFD7E9FF);
  static const background = Color(0xFFF6F9FE);
  static const text = Color(0xFF172033);
  static const muted = Color(0xFF6B7485);
  static const border = Color(0xFFD9E4F2);
  static const success = Color(0xFF1C8A5A);
  static const warning = Color(0xFFE08A1E);
}

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.firebaseStatus});

  final FirebaseConnectionStatus firebaseStatus;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  bool _isSignUp = false;
  bool _loading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      setState(() => _errorMessage = '이메일과 비밀번호를 모두 입력해주세요.');
      return;
    }

    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      if (_isSignUp) {
        await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: email,
          password: password,
        );
      } else {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: email,
          password: password,
        );
      }
    } on FirebaseAuthException catch (error) {
      setState(() => _errorMessage = authErrorMessage(error));
    } catch (_) {
      setState(() => _errorMessage = '로그인 처리 중 문제가 생겼습니다. 잠시 후 다시 시도해주세요.');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(
                    Icons.school_rounded,
                    size: 56,
                    color: AppColors.navy,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '전공길잡이',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.text,
                      fontSize: 34,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '계정으로 로그인하면 공부 시간이 Firestore에 저장됩니다.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.muted,
                      fontSize: 15,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 24),
                  SectionCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          _isSignUp ? '회원가입' : '로그인',
                          style: const TextStyle(
                            color: AppColors.text,
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _emailController,
                          keyboardType: TextInputType.emailAddress,
                          decoration: authInputDecoration(
                            label: '이메일',
                            icon: Icons.mail_outline_rounded,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _passwordController,
                          obscureText: true,
                          decoration: authInputDecoration(
                            label: '비밀번호',
                            icon: Icons.lock_outline_rounded,
                          ),
                          onSubmitted: (_) => _loading ? null : _submit(),
                        ),
                        if (_errorMessage != null) ...[
                          const SizedBox(height: 14),
                          FeedbackBox(
                            icon: Icons.error_outline_rounded,
                            color: AppColors.warning,
                            text: _errorMessage!,
                          ),
                        ],
                        const SizedBox(height: 18),
                        ElevatedButton.icon(
                          icon: Icon(
                            _isSignUp
                                ? Icons.person_add_alt_1_rounded
                                : Icons.login_rounded,
                          ),
                          label: Text(_isSignUp ? '회원가입하기' : '로그인하기'),
                          onPressed: _loading ? null : _submit,
                          style: actionButtonStyle(AppColors.navy),
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: _loading
                              ? null
                              : () {
                                  setState(() {
                                    _isSignUp = !_isSignUp;
                                    _errorMessage = null;
                                  });
                                },
                          child: Text(
                            _isSignUp ? '이미 계정이 있어요' : '계정이 없나요? 회원가입',
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  StorageStatusStrip(status: widget.firebaseStatus),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

InputDecoration authInputDecoration({
  required String label,
  required IconData icon,
}) {
  return InputDecoration(
    labelText: label,
    prefixIcon: Icon(icon),
    filled: true,
    fillColor: Colors.white,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: const BorderSide(color: AppColors.border),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: const BorderSide(color: AppColors.border),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: const BorderSide(color: AppColors.blue, width: 1.6),
    ),
  );
}

String authErrorMessage(FirebaseAuthException error) {
  switch (error.code) {
    case 'email-already-in-use':
      return '이미 가입된 이메일입니다. 로그인으로 진행해주세요.';
    case 'invalid-email':
      return '이메일 형식을 확인해주세요.';
    case 'weak-password':
      return '비밀번호는 6자 이상으로 입력해주세요.';
    case 'user-not-found':
    case 'wrong-password':
    case 'invalid-credential':
      return '이메일 또는 비밀번호가 올바르지 않습니다.';
    case 'operation-not-allowed':
      return 'Firebase 콘솔에서 이메일/비밀번호 로그인을 먼저 켜주세요.';
    case 'network-request-failed':
      return '네트워크 연결을 확인해주세요.';
    default:
      return '인증 오류가 발생했습니다. ${error.message ?? error.code}';
  }
}

class CareerPath {
  const CareerPath({
    required this.id,
    required this.category,
    required this.keywords,
    required this.majors,
    required this.subjects,
    required this.activities,
    required this.advice,
  });

  final String id;
  final String category;
  final List<String> keywords;
  final List<String> majors;
  final List<String> subjects;
  final List<String> activities;
  final String advice;
}

const List<CareerPath> careerPaths = [
  CareerPath(
    id: 'life_bio',
    category: '생명과학/바이오 계열',
    keywords: ['생명과학', '생명', '바이오', '생명공학', '유전', '세포', '의생명'],
    majors: ['생명과학과', '생명공학과', '바이오학과', '의생명과학과'],
    subjects: ['생명과학', '화학', '미적분', '확률과 통계'],
    activities: ['생명과학 실험 보고서 작성', '생물 데이터 분석', '유전 및 세포 관련 탐구', '관련 도서 독서'],
    advice: '생명과학 개념을 화학, 수학 자료 해석과 함께 연결해 두면 실험 보고서와 탐구 발표의 깊이가 좋아집니다.',
  ),
  CareerPath(
    id: 'computer_ai',
    category: '컴퓨터공학/인공지능 계열',
    keywords: [
      '컴퓨터공학',
      '컴퓨터',
      '소프트웨어',
      '인공지능',
      'AI',
      '데이터',
      '앱',
      '코딩',
      '프로그래밍',
    ],
    majors: ['컴퓨터공학과', '소프트웨어학과', '인공지능학과', '데이터사이언스학과'],
    subjects: ['정보', '인공지능 수학', '미적분', '확률과 통계', '물리학'],
    activities: ['앱 개발', '알고리즘 문제 풀이', '데이터 분석 프로젝트', '인공지능 모델 실습'],
    advice:
        '작은 프로그램을 직접 만들고 기록하세요. 수학과 정보 과목의 개념을 프로젝트에 적용한 흔적이 강한 포트폴리오가 됩니다.',
  ),
  CareerPath(
    id: 'medical',
    category: '의약 계열',
    keywords: ['의학', '의예', '간호', '약학', '보건', '치의학', '수의학', '의약'],
    majors: ['의예과', '간호학과', '약학과', '보건학과', '치의예과'],
    subjects: ['생명과학', '화학', '확률과 통계', '윤리와 사상'],
    activities: ['보건 이슈 탐구 보고서', '의학 윤리 토론', '질병 예방 캠페인 기획', '생명과학 심화 독서'],
    advice: '생명과학과 화학의 기본기를 탄탄히 하면서, 의료 윤리와 사회적 책임을 함께 다루는 활동을 쌓아 보세요.',
  ),
  CareerPath(
    id: 'chemistry',
    category: '화학/화학공학 계열',
    keywords: ['화학', '화학공학', '신소재', '에너지', '환경공학', '분자', '실험'],
    majors: ['화학과', '화학공학과', '신소재공학과', '환경공학과'],
    subjects: ['화학', '물리학', '미적분', '확률과 통계'],
    activities: ['화학 실험 설계', '친환경 소재 탐구', '반응 속도 분석', '에너지 전환 기술 조사'],
    advice: '실험 과정, 변수 통제, 수치 해석을 꼼꼼히 기록하면 공학적 문제 해결 능력을 보여주기 좋습니다.',
  ),
  CareerPath(
    id: 'education',
    category: '교육 계열',
    keywords: ['교육', '교사', '사범대', '초등교육', '유아교육', '교육학', '수업'],
    majors: ['교육학과', '초등교육과', '유아교육과', '국어교육과', '수학교육과'],
    subjects: ['국어', '영어', '수학', '사회', '교육학'],
    activities: ['멘토링 활동', '수업 지도안 작성', '교육 문제 탐구', '학습 자료 제작'],
    advice: '교과 실력과 함께 설명력, 관찰력, 피드백 역량을 보여주는 활동을 꾸준히 남기는 것이 좋습니다.',
  ),
  CareerPath(
    id: 'psych_social',
    category: '심리/사회 계열',
    keywords: ['심리학', '심리', '사회', '사회복지', '상담', '정치', '언론', '행정', '사회문제'],
    majors: ['심리학과', '사회학과', '사회복지학과', '정치외교학과', '언론정보학과'],
    subjects: ['사회', '확률과 통계', '윤리와 사상', '국어'],
    activities: ['사회 문제 조사 보고서', '설문 분석 프로젝트', '상담 사례 탐구', '토론 및 발표 활동'],
    advice: '사람과 사회를 관찰한 내용을 자료로 정리하고, 통계적 해석과 글쓰기 역량을 함께 키우면 좋습니다.',
  ),
];

final Map<String, CareerPath> careerPathById = {
  for (final path in careerPaths) path.id: path,
};

String normalizeKeyword(String value) {
  return value.toLowerCase().replaceAll(RegExp(r'\s+'), '');
}

List<CareerPath> findCareerPaths(String input) {
  final query = normalizeKeyword(input);
  if (query.isEmpty) return [];

  final matches = <CareerPath>[];
  for (final path in careerPaths) {
    final matched = path.keywords.any((keyword) {
      final normalizedKeyword = normalizeKeyword(keyword);
      return normalizedKeyword.contains(query) ||
          query.contains(normalizedKeyword);
    });
    if (matched) matches.add(path);
  }
  return matches;
}

List<String> mapCareerSubjectsToStudySubjects(List<String> careerSubjects) {
  final mapped = <String>{};
  for (final subject in careerSubjects) {
    if (studySubjects.contains(subject)) {
      mapped.add(subject);
    } else if (subject.contains('수학') ||
        subject.contains('미적분') ||
        subject.contains('확률')) {
      mapped.add('수학');
    } else if (subject.contains('윤리') || subject.contains('사회')) {
      mapped.add('사회');
    } else if (subject.contains('교육')) {
      mapped.add('사회');
    }
  }
  return mapped.toList();
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.firebaseStatus,
    required this.userEmail,
    required this.onSignOut,
    required this.onOpenDirectInput,
    required this.onOpenSurvey,
    required this.onOpenStudyTimer,
  });

  final FirebaseConnectionStatus firebaseStatus;
  final String? userEmail;
  final VoidCallback? onSignOut;
  final void Function(BuildContext context) onOpenDirectInput;
  final void Function(BuildContext context) onOpenSurvey;
  final void Function(BuildContext context) onOpenStudyTimer;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 28),
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: AppColors.navy,
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.navy.withValues(alpha: 0.18),
                      blurRadius: 22,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.school_rounded, color: Colors.white, size: 44),
                    SizedBox(height: 22),
                    Text(
                      '전공길잡이',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 34,
                        fontWeight: FontWeight.w800,
                        height: 1.15,
                      ),
                    ),
                    SizedBox(height: 12),
                    Text(
                      '진로를 입력하거나 설문을 통해 나에게 맞는 과목과 학습 방향을 찾아보세요.',
                      style: TextStyle(
                        color: Color(0xFFE6F0FF),
                        fontSize: 16,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 26),
              StorageStatusStrip(status: firebaseStatus),
              if (userEmail != null) ...[
                const SizedBox(height: 12),
                UserAccountStrip(email: userEmail!, onSignOut: onSignOut),
              ],
              const SizedBox(height: 16),
              PrimaryActionButton(
                icon: Icons.edit_note_rounded,
                label: '진로 직접 입력',
                onPressed: () => onOpenDirectInput(context),
              ),
              const SizedBox(height: 12),
              SecondaryActionButton(
                icon: Icons.fact_check_rounded,
                label: '진로 탐색 설문',
                onPressed: () => onOpenSurvey(context),
              ),
              const SizedBox(height: 24),
              SectionCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.timer_rounded, color: AppColors.blue),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '공부 시간 관리',
                            style: TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w800,
                              color: AppColors.text,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      '과목별 누적 시간을 기록하고 추천 진로와 관련된 과목의 학습 균형을 확인해보세요.',
                      style: TextStyle(
                        color: AppColors.muted,
                        fontSize: 14,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.arrow_forward_rounded),
                        label: const Text('공부 시간 측정 화면으로 이동'),
                        onPressed: () => onOpenStudyTimer(context),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.navy,
                          side: const BorderSide(color: AppColors.border),
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class DirectInputScreen extends StatefulWidget {
  const DirectInputScreen({super.key, required this.onShowResult});

  final void Function(List<CareerPath> paths, String sourceTitle) onShowResult;

  @override
  State<DirectInputScreen> createState() => _DirectInputScreenState();
}

class _DirectInputScreenState extends State<DirectInputScreen> {
  final TextEditingController _controller = TextEditingController();
  bool _showEmptyMessage = false;

  static const examples = ['생명과학', '컴퓨터공학', '의학', '화학공학', '교육', '심리학', '인공지능'];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _search() {
    final input = _controller.text.trim();
    final matches = findCareerPaths(input);
    if (matches.isEmpty) {
      setState(() => _showEmptyMessage = true);
      return;
    }

    setState(() => _showEmptyMessage = false);
    widget.onShowResult(matches, '입력 키워드: $input');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('진로 직접 입력')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SectionCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '관심 진로 또는 학과 키워드',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: AppColors.text,
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _controller,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _search(),
                      decoration: InputDecoration(
                        hintText: '예: 생명과학, 컴퓨터공학, 인공지능',
                        prefixIcon: const Icon(Icons.search_rounded),
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(18),
                          borderSide: const BorderSide(color: AppColors.border),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(18),
                          borderSide: const BorderSide(color: AppColors.border),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(18),
                          borderSide: const BorderSide(
                            color: AppColors.blue,
                            width: 1.6,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: examples.map((keyword) {
                        return ActionChip(
                          label: Text(keyword),
                          avatar: const Icon(Icons.add_rounded, size: 18),
                          onPressed: () {
                            _controller.text = keyword;
                            _search();
                          },
                          backgroundColor: AppColors.lightBlue,
                          side: BorderSide.none,
                          labelStyle: const TextStyle(color: AppColors.navy),
                        );
                      }).toList(),
                    ),
                    if (_showEmptyMessage) ...[
                      const SizedBox(height: 16),
                      const FeedbackBox(
                        icon: Icons.info_outline_rounded,
                        color: AppColors.warning,
                        text: '아직 등록되지 않은 키워드입니다. 예시 키워드나 비슷한 학과명을 입력해보세요.',
                      ),
                    ],
                    const SizedBox(height: 18),
                    PrimaryActionButton(
                      icon: Icons.auto_awesome_rounded,
                      label: '추천 결과 보기',
                      onPressed: _search,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              SectionCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '등록된 계열 데이터',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: AppColors.text,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ...careerPaths.map(
                      (path) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Padding(
                              padding: EdgeInsets.only(top: 2),
                              child: Icon(
                                Icons.circle,
                                size: 8,
                                color: AppColors.blue,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                '${path.category}: ${path.keywords.take(4).join(', ')}',
                                style: const TextStyle(
                                  color: AppColors.muted,
                                  height: 1.4,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SurveyScreen extends StatefulWidget {
  const SurveyScreen({super.key, required this.onShowResult});

  final void Function(
    List<CareerPath> paths,
    String sourceTitle,
    List<String> categories,
  ) onShowResult;

  @override
  State<SurveyScreen> createState() => _SurveyScreenState();
}

class _SurveyScreenState extends State<SurveyScreen> {
  final List<int> _scores = List.filled(surveyQuestions.length, 3);

  void _submit() {
    final recommendations = calculateSurveyRecommendations(_scores);
    final paths =
        recommendations.expand((item) => item.paths).toSet().take(2).toList();
    final categories = recommendations.map((item) => item.category).toList();

    widget.onShowResult(paths, '설문 추천 결과', categories);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('진로 탐색 설문')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SectionHeader(
                title: '관심 정도를 선택해주세요',
                subtitle: '각 문항에 1점부터 5점까지 답하면 어울리는 계열을 추천합니다.',
              ),
              const SizedBox(height: 12),
              ...List.generate(surveyQuestions.length, (index) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: SectionCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${index + 1}. ${surveyQuestions[index]}',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: AppColors.text,
                            height: 1.45,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: List.generate(5, (scoreIndex) {
                            final score = scoreIndex + 1;
                            final selected = _scores[index] == score;
                            return ChoiceChip(
                              label: Text('$score점'),
                              selected: selected,
                              onSelected: (_) {
                                setState(() => _scores[index] = score);
                              },
                              selectedColor: AppColors.navy,
                              backgroundColor: AppColors.lightBlue,
                              labelStyle: TextStyle(
                                color: selected ? Colors.white : AppColors.navy,
                                fontWeight: FontWeight.w700,
                              ),
                              side: BorderSide.none,
                            );
                          }),
                        ),
                      ],
                    ),
                  ),
                );
              }),
              const SizedBox(height: 6),
              PrimaryActionButton(
                icon: Icons.insights_rounded,
                label: '설문 결과 확인',
                onPressed: _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

const List<String> surveyQuestions = [
  '생명 현상이나 인체 구조에 관심이 많다.',
  '컴퓨터, 앱, 인공지능, 데이터 분석에 관심이 많다.',
  '기계, 전자기기, 물리적 원리를 이해하는 것을 좋아한다.',
  '사람의 심리, 사회 문제, 교육 문제에 관심이 많다.',
  '실험, 탐구, 문제 해결 활동을 좋아한다.',
];

class SurveyRecommendation {
  const SurveyRecommendation({
    required this.category,
    required this.score,
    required this.paths,
  });

  final String category;
  final int score;
  final List<CareerPath> paths;
}

List<SurveyRecommendation> calculateSurveyRecommendations(List<int> scores) {
  final bio = scores[0];
  final computer = scores[1];
  final engineering = scores[2];
  final social = scores[3];
  final inquiry = scores[4];

  final rawScores = <SurveyRecommendation>[
    SurveyRecommendation(
      category: '자연과학계열',
      score: bio * 2 + inquiry * 2,
      paths: [careerPathById['life_bio']!, careerPathById['chemistry']!],
    ),
    SurveyRecommendation(
      category: '공학계열',
      score: computer * 2 + engineering * 2 + inquiry,
      paths: [careerPathById['computer_ai']!, careerPathById['chemistry']!],
    ),
    SurveyRecommendation(
      category: '의약계열',
      score: bio * 2 + inquiry + social,
      paths: [careerPathById['medical']!, careerPathById['life_bio']!],
    ),
    SurveyRecommendation(
      category: '인문사회계열',
      score: social * 2 + inquiry,
      paths: [careerPathById['psych_social']!],
    ),
    SurveyRecommendation(
      category: '교육계열',
      score: social * 2 + (6 - (computer - 3).abs()) + inquiry,
      paths: [careerPathById['education']!],
    ),
  ]..sort((a, b) => b.score.compareTo(a.score));

  final topScore = rawScores.first.score;
  final closeResults =
      rawScores.where((item) => topScore - item.score <= 2).take(2).toList();
  return closeResults.isEmpty ? rawScores.take(1).toList() : closeResults;
}

class RecommendationResultScreen extends StatelessWidget {
  const RecommendationResultScreen({
    super.key,
    required this.sourceTitle,
    required this.categories,
    required this.paths,
    required this.onOpenTimer,
  });

  final String sourceTitle;
  final List<String> categories;
  final List<CareerPath> paths;
  final VoidCallback onOpenTimer;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('추천 결과')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SectionCard(
                backgroundColor: AppColors.navy,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      sourceTitle,
                      style: const TextStyle(
                        color: Color(0xFFD7E9FF),
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      '추천 계열',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: categories.map((category) {
                        return DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            child: Text(
                              category,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              ...paths.map((path) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: CareerResultCard(path: path),
                );
              }),
              PrimaryActionButton(
                icon: Icons.timer_rounded,
                label: '추천 과목 공부 시간 기록하기',
                onPressed: onOpenTimer,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CareerResultCard extends StatelessWidget {
  const CareerResultCard({super.key, required this.path});

  final CareerPath path;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.lightBlue,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.route_rounded, color: AppColors.blue),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  path.category,
                  style: const TextStyle(
                    color: AppColors.text,
                    fontSize: 19,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          InfoBlock(
            title: '관련 학과군',
            icon: Icons.account_balance_rounded,
            items: path.majors,
          ),
          const SizedBox(height: 14),
          InfoBlock(
            title: '추천 선택과목',
            icon: Icons.menu_book_rounded,
            items: path.subjects,
          ),
          const SizedBox(height: 14),
          InfoBlock(
            title: '진로 준비 활동',
            icon: Icons.task_alt_rounded,
            items: path.activities,
          ),
          const SizedBox(height: 14),
          AdviceBlock(text: path.advice),
        ],
      ),
    );
  }
}

class StudyTimerScreen extends StatefulWidget {
  const StudyTimerScreen({
    super.key,
    required this.careerCategories,
    required this.careerSubjects,
    required this.studyTimeStore,
    required this.firebaseStatus,
  });

  final List<String> careerCategories;
  final List<String> careerSubjects;
  final StudyTimeStore studyTimeStore;
  final FirebaseConnectionStatus firebaseStatus;

  @override
  State<StudyTimerScreen> createState() => _StudyTimerScreenState();
}

class _StudyTimerScreenState extends State<StudyTimerScreen> {
  final Map<String, int> _totals = {
    for (final subject in studySubjects) subject: 0,
  };

  String _selectedSubject = studySubjects.first;
  bool _loading = true;
  bool _running = false;
  int _currentSeconds = 0;
  DateTime? _startedAt;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _loadTotals();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadTotals() async {
    final loadedTotals = await widget.studyTimeStore.loadTotals();

    if (!mounted) return;
    setState(() {
      _totals
        ..clear()
        ..addAll(loadedTotals);
      _loading = false;
    });
  }

  Future<void> _saveTotals() async {
    await widget.studyTimeStore.saveTotals(_totals);
  }

  void _startTimer() {
    if (_running) return;
    setState(() {
      _running = true;
      _startedAt = DateTime.now();
      _currentSeconds = 0;
    });

    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final startedAt = _startedAt;
      if (startedAt == null) return;
      setState(() {
        _currentSeconds = DateTime.now().difference(startedAt).inSeconds;
      });
    });
  }

  Future<void> _stopTimer() async {
    if (!_running) return;
    _timer?.cancel();
    _timer = null;

    final addedSeconds = _currentSeconds;
    setState(() {
      _totals[_selectedSubject] =
          (_totals[_selectedSubject] ?? 0) + addedSeconds;
      _running = false;
      _startedAt = null;
      _currentSeconds = 0;
    });
    await _saveTotals();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${widget.studyTimeStore.label}에 공부 시간이 저장되었습니다.'),
      ),
    );
  }

  void _resetCurrentTimer() {
    _timer?.cancel();
    _timer = null;
    setState(() {
      _running = false;
      _startedAt = null;
      _currentSeconds = 0;
    });
  }

  Future<void> _resetAllRecords() async {
    _resetCurrentTimer();
    setState(() {
      for (final subject in studySubjects) {
        _totals[subject] = 0;
      }
    });
    await _saveTotals();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${widget.studyTimeStore.label} 기록을 초기화했습니다.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final relatedSubjects = mapCareerSubjectsToStudySubjects(
      widget.careerSubjects,
    );
    final totalSeconds = _totals.values.fold<int>(
      0,
      (currentTotal, value) => currentTotal + value,
    );
    final relatedSeconds = relatedSubjects.fold<int>(
      0,
      (currentTotal, subject) => currentTotal + (_totals[subject] ?? 0),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('공부 시간 측정'),
        actions: [
          IconButton(
            tooltip: '누적 기록 초기화',
            onPressed: _resetAllRecords,
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    StorageStatusStrip(status: widget.firebaseStatus),
                    const SizedBox(height: 16),
                    SectionCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          DropdownButtonFormField<String>(
                            initialValue: _selectedSubject,
                            items: studySubjects.map((subject) {
                              return DropdownMenuItem(
                                value: subject,
                                child: Text(subject),
                              );
                            }).toList(),
                            onChanged: _running
                                ? null
                                : (value) {
                                    if (value == null) return;
                                    setState(() => _selectedSubject = value);
                                  },
                            decoration: InputDecoration(
                              labelText: '과목 선택',
                              filled: true,
                              fillColor: Colors.white,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(18),
                                borderSide: const BorderSide(
                                  color: AppColors.border,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              vertical: 28,
                              horizontal: 16,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.lightBlue,
                              borderRadius: BorderRadius.circular(22),
                            ),
                            child: Column(
                              children: [
                                Text(
                                  _selectedSubject,
                                  style: const TextStyle(
                                    color: AppColors.navy,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  formatClock(_currentSeconds),
                                  style: const TextStyle(
                                    color: AppColors.text,
                                    fontSize: 44,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 0,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: ElevatedButton.icon(
                                  icon: const Icon(Icons.play_arrow_rounded),
                                  label: const Text('시작'),
                                  onPressed: _running ? null : _startTimer,
                                  style: actionButtonStyle(AppColors.blue),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: ElevatedButton.icon(
                                  icon: const Icon(Icons.stop_rounded),
                                  label: const Text('정지'),
                                  onPressed: _running ? _stopTimer : null,
                                  style: actionButtonStyle(AppColors.navy),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: OutlinedButton.icon(
                                  icon: const Icon(Icons.refresh_rounded),
                                  label: const Text('초기화'),
                                  onPressed: _resetCurrentTimer,
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: AppColors.navy,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 14,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    CareerStudyFeedback(
                      categories: widget.careerCategories,
                      relatedSubjects: relatedSubjects,
                      totalSeconds: totalSeconds,
                      relatedSeconds: relatedSeconds,
                    ),
                    const SizedBox(height: 16),
                    SectionCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '과목별 누적 공부 시간',
                            style: TextStyle(
                              color: AppColors.text,
                              fontSize: 19,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 14),
                          StudyBarChart(totals: _totals),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

const List<String> studySubjects = [
  '국어',
  '영어',
  '수학',
  '생명과학',
  '화학',
  '물리학',
  '지구과학',
  '정보',
  '사회',
  '한국사',
];

class CareerStudyFeedback extends StatelessWidget {
  const CareerStudyFeedback({
    super.key,
    required this.categories,
    required this.relatedSubjects,
    required this.totalSeconds,
    required this.relatedSeconds,
  });

  final List<String> categories;
  final List<String> relatedSubjects;
  final int totalSeconds;
  final int relatedSeconds;

  @override
  Widget build(BuildContext context) {
    final hasRecommendation =
        categories.isNotEmpty && relatedSubjects.isNotEmpty;
    final needsMoreCareerStudy = hasRecommendation &&
        totalSeconds > 0 &&
        relatedSeconds / totalSeconds < 0.35;
    final color = needsMoreCareerStudy ? AppColors.warning : AppColors.success;
    final text = !hasRecommendation
        ? '추천 결과를 먼저 확인하면 진로 관련 과목 피드백이 표시됩니다.'
        : totalSeconds == 0
            ? '추천 계열 관련 과목: ${relatedSubjects.join(', ')}'
            : needsMoreCareerStudy
                ? '진로 관련 과목 학습 시간이 부족합니다.'
                : '진로 관련 과목 학습 균형이 좋습니다.';

    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FeedbackBox(
            icon: needsMoreCareerStudy
                ? Icons.warning_amber_rounded
                : Icons.check_circle_rounded,
            color: color,
            text: text,
          ),
          if (hasRecommendation) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ...categories.map((category) => SmallPill(label: category)),
                ...relatedSubjects.map(
                  (subject) => SmallPill(label: subject, filled: true),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '진로 관련 누적 시간: ${formatReadableDuration(relatedSeconds)}',
              style: const TextStyle(
                color: AppColors.muted,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class StudyBarChart extends StatelessWidget {
  const StudyBarChart({super.key, required this.totals});

  final Map<String, int> totals;

  @override
  Widget build(BuildContext context) {
    final maxSeconds = max(1, totals.values.fold<int>(0, max));

    return Column(
      children: studySubjects.map((subject) {
        final seconds = totals[subject] ?? 0;
        final progress = seconds / maxSeconds;
        return Padding(
          padding: const EdgeInsets.only(bottom: 13),
          child: Row(
            children: [
              SizedBox(
                width: 72,
                child: Text(
                  subject,
                  style: const TextStyle(
                    color: AppColors.text,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    minHeight: 12,
                    value: progress,
                    backgroundColor: AppColors.lightBlue,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      seconds == 0 ? AppColors.border : AppColors.blue,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 82,
                child: Text(
                  formatReadableDuration(seconds),
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: AppColors.text,
            fontSize: 23,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          subtitle,
          style: const TextStyle(
            color: AppColors.muted,
            fontSize: 14,
            height: 1.45,
          ),
        ),
      ],
    );
  }
}

class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.child,
    this.backgroundColor = Colors.white,
  });

  final Widget child;
  final Color backgroundColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(22),
        border: backgroundColor == Colors.white
            ? Border.all(color: AppColors.border)
            : null,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
  }
}

class PrimaryActionButton extends StatelessWidget {
  const PrimaryActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      icon: Icon(icon),
      label: Text(label),
      onPressed: onPressed,
      style: actionButtonStyle(AppColors.navy),
    );
  }
}

class SecondaryActionButton extends StatelessWidget {
  const SecondaryActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      icon: Icon(icon),
      label: Text(label),
      onPressed: onPressed,
      style: actionButtonStyle(AppColors.blue),
    );
  }
}

ButtonStyle actionButtonStyle(Color color) {
  return ElevatedButton.styleFrom(
    backgroundColor: color,
    foregroundColor: Colors.white,
    elevation: 0,
    padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 14),
    textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
  );
}

class InfoBlock extends StatelessWidget {
  const InfoBlock({
    super.key,
    required this.title,
    required this.icon,
    required this.items,
  });

  final String title;
  final IconData icon;
  final List<String> items;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 20, color: AppColors.blue),
            const SizedBox(width: 8),
            Text(
              title,
              style: const TextStyle(
                color: AppColors.text,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: items.map((item) => SmallPill(label: item)).toList(),
        ),
      ],
    );
  }
}

class AdviceBlock extends StatelessWidget {
  const AdviceBlock({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.lightBlue,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.lightbulb_rounded, color: AppColors.blue),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: AppColors.text,
                height: 1.45,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SmallPill extends StatelessWidget {
  const SmallPill({super.key, required this.label, this.filled = false});

  final String label;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: filled ? AppColors.navy : AppColors.lightBlue,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: filled ? Colors.white : AppColors.navy,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class FeedbackBox extends StatelessWidget {
  const FeedbackBox({
    super.key,
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: color,
                height: 1.45,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class StorageStatusStrip extends StatelessWidget {
  const StorageStatusStrip({super.key, required this.status});

  final FirebaseConnectionStatus status;

  @override
  Widget build(BuildContext context) {
    final color = status.connected ? AppColors.success : AppColors.warning;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.11),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(
              status.connected
                  ? Icons.cloud_done_rounded
                  : Icons.cloud_off_rounded,
              color: color,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  status.title,
                  style: const TextStyle(
                    color: AppColors.text,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  status.message,
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class UserAccountStrip extends StatelessWidget {
  const UserAccountStrip({
    super.key,
    required this.email,
    required this.onSignOut,
  });

  final String email;
  final VoidCallback? onSignOut;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.lightBlue,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          const Icon(Icons.account_circle_rounded, color: AppColors.navy),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '로그인 계정',
                  style: TextStyle(
                    color: AppColors.text,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  email,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: onSignOut,
            icon: const Icon(Icons.logout_rounded, size: 18),
            label: const Text('로그아웃'),
            style: TextButton.styleFrom(foregroundColor: AppColors.navy),
          ),
        ],
      ),
    );
  }
}

String formatClock(int totalSeconds) {
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  return '${twoDigits(hours)}:${twoDigits(minutes)}:${twoDigits(seconds)}';
}

String formatReadableDuration(int totalSeconds) {
  if (totalSeconds <= 0) return '0분';

  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;

  if (hours > 0) {
    return '$hours시간 $minutes분';
  }
  if (minutes > 0) {
    return '$minutes분 $seconds초';
  }
  return '$seconds초';
}

String twoDigits(int value) => value.toString().padLeft(2, '0');
