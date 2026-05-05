import 'package:flutter/material.dart';
import 'screens/home_screen.dart';
import 'services/windows_registry_service.dart';
import 'services/history_service.dart';
import 'package:app_links/app_links.dart';
import 'package:animations/animations.dart';
import 'package:google_fonts/google_fonts.dart';
import 'config.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Register deep link protocol on Windows
  await WindowsRegistryService.registerProtocol();

  // Fetch live tunnel URL from local server (macOS) before app starts.
  // On Android this fails gracefully and uses the hardcoded fallback.
  await AppConfig.initialize();
  await HistoryService().load();
  
  runApp(const TransferaApp());
}

class TransferaApp extends StatelessWidget {
  const TransferaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Transfera',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: const Color(0xFFBB86FC),
        scaffoldBackgroundColor: const Color(0xFF050505),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6200EE),
          brightness: Brightness.dark,
          surface: const Color(0xFF121212),
          primary: const Color(0xFFBB86FC),
          secondary: const Color(0xFF03DAC6),
        ),
        useMaterial3: true,
        textTheme: GoogleFonts.outfitTextTheme(ThemeData.dark().textTheme),
        appBarTheme: AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          titleTextStyle: GoogleFonts.outfit(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: SharedAxisPageTransitionsBuilder(
              transitionType: SharedAxisTransitionType.horizontal,
            ),
            TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
            TargetPlatform.macOS: ZoomPageTransitionsBuilder(),
          },
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFBB86FC),
            foregroundColor: Colors.black,
            minimumSize: const Size(double.infinity, 56),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            textStyle: GoogleFonts.outfit(
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
