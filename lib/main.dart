import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/hoyoplay_client.dart';
import 'download/download_manager.dart';
import 'ui/home_page.dart';

void main() {
  runApp(const HoYoDownloaderApp());
}

class HoYoDownloaderApp extends StatelessWidget {
  const HoYoDownloaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<HoYoPlayApiClient>(
          create: (_) => HoYoPlayApiClient(),
          dispose: (_, client) => client.close(),
        ),
        ChangeNotifierProvider<DownloadManager>(
          create: (_) => DownloadManager(),
        ),
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
