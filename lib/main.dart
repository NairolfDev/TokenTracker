import 'dart:async';
import 'package:flutter/material.dart';
import 'controllers/ampel_controller.dart';
import 'models/app_constants.dart';
import 'ui/screens/ampel_hud_screen.dart';
import 'ui/theme/ampel_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = AmpelController();
  unawaited(controller.initialize());
  runApp(AgentLightsApp(controller: controller));
}

class AgentLightsApp extends StatefulWidget {
  final AmpelController? controller;

  const AgentLightsApp({
    super.key,
    this.controller,
  });

  @override
  State<AgentLightsApp> createState() => _AgentLightsAppState();
}

class _AgentLightsAppState extends State<AgentLightsApp> {
  late final AmpelController _controller;
  late final bool _ownsController;

  @override
  void initState() {
    super.initState();
    if (widget.controller != null) {
      _controller = widget.controller!;
      _ownsController = false;
    } else {
      _controller = AmpelController();
      _ownsController = true;
      unawaited(_controller.initialize());
    }
  }

  @override
  void dispose() {
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConstants.appTitle,
      debugShowCheckedModeBanner: false,
      theme: AmpelTheme.darkTheme,
      darkTheme: AmpelTheme.darkTheme,
      themeMode: ThemeMode.dark,
      home: AmpelHudScreen(controller: _controller),
    );
  }
}
