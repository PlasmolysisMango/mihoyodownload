import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/app_settings.dart';
import 'core/hoyoplay_client.dart';
import 'download/download_manager.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final settings = AppSettings(prefs);
  final manager = DownloadManager(prefs: prefs);
  // Bring back tasks from the previous session as paused entries.
  await manager.restoreTasks();
  runApp(HoYoDownloaderApp(settings: settings, manager: manager));
}

class HoYoDownloaderApp extends StatelessWidget {
  const HoYoDownloaderApp(
      {super.key, required this.settings, required this.manager});

  final AppSettings settings;
  final DownloadManager manager;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<HoYoPlayApiClient>(
          create: (_) => HoYoPlayApiClient(),
          dispose: (_, client) => client.close(),
        ),
        ChangeNotifierProvider<AppSettings>.value(value: settings),
        ChangeNotifierProvider<DownloadManager>.value(value: manager),
      ],
      child: MaterialApp(
        title: 'HoYo Downloader',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.deepPurple,
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: const HomePage(),
      ),
    );
  }
}
