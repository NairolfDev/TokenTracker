import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import '../models/app_constants.dart';
import 'platform/platform_bridge.dart';

class DesktopIntegrationService with WindowListener, TrayListener {
  final VoidCallback onSyncRequested;
  final VoidCallback onReinstallHooksRequested;
  final VoidCallback onCheckUpdatesRequested;

  bool _initialized = false;
  bool _alwaysOnTop = true;
  bool _autostartEnabled = true;

  DesktopIntegrationService({
    required this.onSyncRequested,
    required this.onReinstallHooksRequested,
    required this.onCheckUpdatesRequested,
  });

  bool get isDesktop => PlatformBridge.isDesktop;
  bool get alwaysOnTop => _alwaysOnTop;
  bool get autostartEnabled => _autostartEnabled;

  static final HotKey _toggleHotKey = HotKey(
    key: PhysicalKeyboardKey.space,
    modifiers: [HotKeyModifier.alt],
    scope: HotKeyScope.system,
  );

  Future<void> initialize() async {
    if (!PlatformBridge.isDesktop || _initialized) return;
    _initialized = true;

    try {
      await windowManager.ensureInitialized();
      windowManager.addListener(this);

      const windowOptions = WindowOptions(
        size: Size(
          AppConstants.hudCollapsedWidth,
          AppConstants.hudCollapsedHeight,
        ),
        minimumSize: Size(480, 235),
        center: true,
        backgroundColor: Colors.transparent,
        skipTaskbar: false,
        titleBarStyle: TitleBarStyle.hidden,
        alwaysOnTop: true,
        title: AppConstants.appTitle,
      );

      await windowManager.waitUntilReadyToShow(windowOptions, () async {
        await windowManager.setPreventClose(true);
        await windowManager.setAlwaysOnTop(true);
        await windowManager.show();
        await windowManager.focus();
      });
    } catch (_) {}

    await _initGlobalHotKey();
    await _initAutostart();
    await _initSystemTray();
  }

  Future<void> _initGlobalHotKey() async {
    if (!PlatformBridge.isDesktop) return;
    try {
      await hotKeyManager.unregisterAll();
      await hotKeyManager.register(
        _toggleHotKey,
        keyDownHandler: (_) async {
          await toggleWindowVisibility();
        },
      );
    } catch (_) {}
  }

  Future<void> _initAutostart() async {
    if (!PlatformBridge.isDesktop) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final alreadyInit = prefs.getBool('autostart_initialized') ?? false;
      final savedPref = prefs.getBool('autostart_enabled') ?? true;
      _autostartEnabled = alreadyInit ? savedPref : true;

      final packageInfo = await PackageInfo.fromPlatform();
      final exePath = PlatformBridge.resolvedExecutable;
      if (exePath.isNotEmpty) {
        launchAtStartup.setup(
          appName: packageInfo.appName.isNotEmpty
              ? packageInfo.appName
              : AppConstants.appPackageName,
          appPath: exePath,
        );
        if (!alreadyInit || _autostartEnabled) {
          await setAutostartEnabled(true);
          await prefs.setBool('autostart_initialized', true);
        }
      }
    } catch (_) {}
  }

  Future<void> setAutostartEnabled(bool enabled) async {
    _autostartEnabled = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('autostart_enabled', enabled);
      if (!PlatformBridge.isDesktop) return;

      if (enabled) {
        await launchAtStartup.enable();
      } else {
        await launchAtStartup.disable();
      }

      if (PlatformBridge.isLinux) {
        final home = PlatformBridge.homeDirectory;
        final exe = PlatformBridge.resolvedExecutable;
        if (home.isNotEmpty && exe.isNotEmpty) {
          final desktopFile = p.join(
            home,
            '.config',
            'autostart',
            'agentlights.desktop',
          );
          if (enabled) {
            final content = '''[Desktop Entry]
Type=Application
Name=Agent Lights
Comment=Agent Lights
Exec="$exe"
Terminal=false
StartupNotify=false
X-GNOME-Autostart-enabled=true
''';
            await PlatformBridge.writeFileString(desktopFile, content);
          } else {
            await PlatformBridge.writeFileString(
              desktopFile,
              '[Desktop Entry]\nHidden=true\n',
            );
          }
        }
      }
    } catch (_) {}
  }

  Future<void> setAlwaysOnTop(bool enabled) async {
    _alwaysOnTop = enabled;
    if (!PlatformBridge.isDesktop) return;
    try {
      await windowManager.setAlwaysOnTop(enabled);
    } catch (_) {}
  }

  /// Dynamically adjusts the HUD window height when the Antigravity sub-limits drawer is expanded/collapsed.
  Future<void> setHudExpanded(bool expanded) async {
    if (!PlatformBridge.isDesktop) return;
    try {
      final currentSize = await windowManager.getSize();
      final targetHeight = expanded
          ? AppConstants.hudExpandedHeight
          : AppConstants.hudCollapsedHeight;
      await windowManager.setSize(
        Size(currentSize.width, targetHeight),
        animate: true,
      );
    } catch (_) {}
  }

  /// Switches between the compact Alt+Space HUD and a large, regular app window.
  Future<void> toggleLargeWindow() async {
    if (!PlatformBridge.isDesktop) return;
    try {
      final size = await windowManager.getSize();
      if (size.width < AppConstants.largeLayoutWidth) {
        await setAlwaysOnTop(false);
        await windowManager.setSize(
          const Size(AppConstants.hudLargeWidth, AppConstants.hudLargeHeight),
        );
        await windowManager.center();
      } else {
        await windowManager.setSize(
          const Size(AppConstants.hudCollapsedWidth, AppConstants.hudCollapsedHeight),
        );
        await setAlwaysOnTop(true);
      }
    } catch (_) {}
  }

  /// Toggles window visibility for `Alt + Space`, `Escape`, or Tray click.
  Future<void> toggleWindowVisibility() async {
    if (!PlatformBridge.isDesktop) return;
    try {
      // Visible always hides, focused or not: the HUD floats on top and rarely has focus.
      if (await windowManager.isVisible()) {
        await windowManager.hide();
      } else {
        await showAndFocusWindow();
      }
    } catch (_) {}
  }

  Future<void> hideWindowToTray() async {
    if (!PlatformBridge.isDesktop) return;
    try {
      await windowManager.hide();
    } catch (_) {}
  }

  Future<void> showAndFocusWindow() async {
    if (!PlatformBridge.isDesktop) return;
    try {
      await windowManager.show();
      await windowManager.setAlwaysOnTop(_alwaysOnTop);
      await windowManager.focus();
    } catch (_) {}
  }

  Future<void> startWindowDrag() async {
    if (!PlatformBridge.isDesktop) return;
    try {
      await windowManager.startDragging();
    } catch (_) {}
  }

  Future<void> _initSystemTray() async {
    if (!PlatformBridge.isDesktop) return;
    try {
      trayManager.addListener(this);
      final iconPath = PlatformBridge.isWindows
          ? 'assets/icons/tray_icon.ico'
          : 'assets/icons/tray_icon.png';
      await trayManager.setIcon(iconPath);
      if (!PlatformBridge.isLinux) {
        await trayManager.setToolTip('Agent Lights (Alt+Space)');
      }
      final menu = Menu(
        items: [
          MenuItem(
            key: 'toggle_window',
            label: 'Agent Lights ein-/ausblenden (Alt+Space)',
          ),
          MenuItem.separator(),
          MenuItem(
            key: 'sync_now',
            label: 'Usage & Hooks jetzt synchronisieren',
          ),
          MenuItem(
            key: 'reinstall_hooks',
            label: 'Hooks neu installieren',
          ),
          MenuItem(
            key: 'check_updates',
            label: 'Nach Updates suchen',
          ),
          MenuItem.separator(),
          MenuItem(
            key: 'exit_app',
            label: 'Beenden',
          ),
        ],
      );
      await trayManager.setContextMenu(menu);
    } catch (_) {}
  }

  @override
  void onWindowClose() async {
    // Minimize to tray instead of terminating the background hook server
    await hideWindowToTray();
  }

  @override
  void onTrayIconMouseDown() async {
    await toggleWindowVisibility();
  }

  @override
  void onTrayIconRightMouseDown() async {
    try {
      await trayManager.popUpContextMenu();
    } catch (_) {}
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'toggle_window':
        await toggleWindowVisibility();
        break;
      case 'sync_now':
        await showAndFocusWindow();
        onSyncRequested();
        break;
      case 'reinstall_hooks':
        onReinstallHooksRequested();
        break;
      case 'check_updates':
        await showAndFocusWindow();
        onCheckUpdatesRequested();
        break;
      case 'exit_app':
        await exitApplication();
        break;
    }
  }

  Future<void> exitApplication() async {
    if (!PlatformBridge.isDesktop) return;
    try {
      await hotKeyManager.unregisterAll();
      await trayManager.destroy();
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } catch (_) {}
  }
}
