import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/app_store.dart';
import 'ui/workspace.dart';

final storeProvider = FutureProvider<AppStore>((ref) async {
  final store = await AppStore.open();
  ref.onDispose(store.close);
  return store;
});

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: ZeraviApp()));
}

class ZeraviApp extends ConsumerStatefulWidget {
  const ZeraviApp({super.key});
  @override
  ConsumerState<ZeraviApp> createState() => _ZeraviAppState();
}

class _ZeraviAppState extends ConsumerState<ZeraviApp> {
  ThemeMode themeMode = ThemeMode.dark;

  ThemeData theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xff4ddbb3),
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: dark
          ? const Color(0xff101419)
          : const Color(0xfff7f9fa),
      fontFamily: 'sans',
      dividerColor: dark ? const Color(0xff29313a) : const Color(0xffdde4e8),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        isDense: true,
      ),
      tooltipTheme: const TooltipThemeData(
        waitDuration: Duration(milliseconds: 400),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Zeravi',
    debugShowCheckedModeBanner: false,
    theme: theme(Brightness.light),
    darkTheme: theme(Brightness.dark),
    themeMode: themeMode,
    home: ref
        .watch(storeProvider)
        .when(
          data: (store) => Workspace(
            store: store,
            onToggleTheme: () => setState(() {
              themeMode = themeMode == ThemeMode.dark
                  ? ThemeMode.light
                  : ThemeMode.dark;
            }),
          ),
          loading: () =>
              const Scaffold(body: Center(child: CircularProgressIndicator())),
          error: (error, _) => Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.storage_rounded, size: 48),
                    const SizedBox(height: 16),
                    const Text('Could not open Zeravi’s local storage'),
                    const SizedBox(height: 8),
                    SelectableText('$error'),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () => ref.invalidate(storeProvider),
                      child: const Text('Try again'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
  );
}
