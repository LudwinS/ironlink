import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/notify/iron_notify_host.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_colors.dart';
import 'core/theme/theme_provider.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  runApp(const ProviderScope(child: IronLinkApp()));
}

class IronLinkApp extends ConsumerWidget {
  const IronLinkApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final theme = ref.watch(themeProvider);
    AppColors.use(theme);
    final data = AppColors.theme();

    return MaterialApp.router(
      title: 'IronLink',
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('es'), Locale('en')],
      locale: const Locale('es'),
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      // Paleta Nocturne (oscuro, AMOLED o claro) elegida en «Tú».
      theme: data,
      darkTheme: data,
      themeMode: data.brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light,
      // Muchos widgets leen AppColors directamente; al cambiar de tema se
      // vuelve a montar el navegador para que todos tomen la nueva paleta.
      // La sesión, los borradores y las conversaciones viven en providers.
      builder: (context, child) => MediaQuery(
        // El calendario usa 24 horas; también debe aceptarlas la entrada manual.
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        // Los avisos (IronNotify) se dibujan encima de toda la app y
        // sobreviven al cambio de tema.
        child: IronNotifyHost(
          child: KeyedSubtree(key: ValueKey(theme), child: child!),
        ),
      ),
    );
  }
}
