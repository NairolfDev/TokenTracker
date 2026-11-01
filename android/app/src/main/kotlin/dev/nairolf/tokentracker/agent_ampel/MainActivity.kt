package dev.nairolf.tokentracker.agent_ampel

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The app pings the widget after every fresh snapshot so it never lags behind the app.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "agentlights/widget").setMethodCallHandler { call, result ->
            if (call.method == "refresh") {
                sendBroadcast(Intent(this, AgentLightsWidget::class.java).setAction(AgentLightsWidget.ACTION_REFRESH))
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
    }
}
