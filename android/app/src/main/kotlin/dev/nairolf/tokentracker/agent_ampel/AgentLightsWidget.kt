package dev.nairolf.tokentracker.agent_ampel

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.widget.RemoteViews
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

/// Home-screen widget: reads the paired desktop's last status snapshot from the ntfy topic
/// (the pairing secret is the one the Flutter app saved with shared_preferences) and shows one line per agent.
class AgentLightsWidget : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val pending = goAsync()
        thread {
            try {
                val snapshot = fetchSnapshot(context)
                for (id in ids) manager.updateAppWidget(id, render(context, snapshot))
            } finally {
                pending.finish()
            }
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action == ACTION_REFRESH) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, AgentLightsWidget::class.java))
            onUpdate(context, manager, ids)
        }
    }

    private fun secret(context: Context): String? =
        context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .getString("flutter.join_secret", null)?.takeIf { it.isNotBlank() }

    private fun fetchSnapshot(context: Context): JSONObject? {
        val secret = secret(context) ?: return null
        val cache = context.getSharedPreferences("agent_lights_widget", Context.MODE_PRIVATE)
        try {
            val conn = URL("https://ntfy.sh/agentlights-$secret/json?poll=1&since=2h").openConnection() as HttpURLConnection
            conn.connectTimeout = 8000
            conn.readTimeout = 8000
            var latest: String? = null
            conn.inputStream.bufferedReader().useLines { lines ->
                for (line in lines) {
                    if (line.isBlank()) continue
                    val m = JSONObject(line)
                    if (m.optString("event") == "message") latest = m.optString("message")
                }
            }
            if (latest != null) cache.edit().putString("last", latest).apply()
        } catch (_: Exception) {
            // offline: fall back to the last snapshot we saw
        }
        return cache.getString("last", null)?.let { runCatching { JSONObject(it) }.getOrNull() }
    }

    private fun render(context: Context, snapshot: JSONObject?): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.agent_lights_widget)
        val dots = intArrayOf(R.id.dot1, R.id.dot2, R.id.dot3)
        val names = intArrayOf(R.id.name1, R.id.name2, R.id.name3)
        val vals = intArrayOf(R.id.val1, R.id.val2, R.id.val3)
        val agents = snapshot?.optJSONObject("agents")
        val order = listOf("codex", "antigravity", "claude")
        for (i in order.indices) {
            val a = agents?.optJSONObject(order[i])
            if (a == null) {
                views.setTextViewText(names[i], if (i == 0) "Nicht verbunden" else "")
                views.setTextViewText(vals[i], if (i == 0) "In der App koppeln" else "")
                views.setTextColor(dots[i], Color.parseColor("#475569"))
                continue
            }
            views.setTextViewText(names[i], a.optString("title"))
            views.setTextColor(dots[i], when (a.optString("traffic_light")) {
                "working" -> Color.parseColor("#22C55E")
                "needsInput" -> Color.parseColor("#FFB800")
                "outOfUsage" -> Color.parseColor("#FF2A2A")
                else -> Color.parseColor("#CBD5E1")
            })
            val wins = a.optJSONArray("primary_windows")
            val parts = ArrayList<String>()
            if (wins != null) {
                for (w in 0 until minOf(wins.length(), 2)) {
                    val win = wins.getJSONObject(w)
                    if (win.isNull("remaining_percent") || win.optBoolean("disabled")) continue
                    val label = if (win.optString("key").contains("seven_day") || win.optString("key").contains("weekly")) "Wo" else "5h"
                    parts.add("$label ${Math.round(win.getDouble("remaining_percent"))}%")
                }
            }
            views.setTextViewText(vals[i], if (parts.isEmpty()) a.optString("subtitle").take(22) else parts.joinToString(" · "))
        }
        val open = PendingIntent.getActivity(
            context, 0, Intent(context, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE,
        )
        views.setOnClickPendingIntent(R.id.root, open)
        val refresh = PendingIntent.getBroadcast(
            context, 1, Intent(context, AgentLightsWidget::class.java).setAction(ACTION_REFRESH), PendingIntent.FLAG_IMMUTABLE,
        )
        views.setOnClickPendingIntent(R.id.title, refresh)
        return views
    }

    companion object {
        const val ACTION_REFRESH = "dev.nairolf.tokentracker.WIDGET_REFRESH"
    }
}
