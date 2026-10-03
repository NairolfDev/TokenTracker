"""Provider metadata. Web subscriptions and developer APIs are separate connections."""
from dataclasses import dataclass


@dataclass(frozen=True)
class Provider:
    id: str
    name: str
    kind: str
    subtitle: str
    color: str
    monogram: str
    url: str
    endpoint: str = ""
    domains: tuple[str, ...] = ()
    session_cookies: tuple[str, ...] = ()
    account_selectors: tuple[str, ...] = ()
    credential_hint: str = ""
    login_url: str = ""


CATALOG = (
    Provider("openrouter", "OpenRouter", "oauth", "Ein Zugang. Viele Modelle.", "#8B7CF8", "OR",
             "https://openrouter.ai/settings/credits", "https://openrouter.ai/api/v1/key"),
    Provider("claude", "Claude", "browser", "Dein Claude-Abonnement", "#CC8D6B", "C",
             "https://claude.ai/settings/usage", domains=("claude.ai",), session_cookies=("sessionKey",),
             account_selectors=('[data-testid="user-menu-button"]', 'button[aria-label*="User menu"]',
                                'button[aria-label*="Settings"]', 'a[href="/settings/account"]',
                                'a[href="/settings/usage"]', '[data-testid="account-menu"]'), login_url="https://claude.ai"),
    Provider("chatgpt", "Codex · ChatGPT", "codex", "5-Stunden- und Wochenlimits deines ChatGPT-Abos", "#37B99C", "G",
             "https://chatgpt.com/codex/settings/usage", domains=("chatgpt.com", "openai.com"),
             session_cookies=("__Secure-next-auth.session-token", "__Secure-authjs.session-token"),
             account_selectors=('[data-testid="accounts-profile-button"]', '[data-testid="profile-button"]',
                                'button[aria-label*="Open profile"]', 'button[aria-label*="Profil öffnen"]')),
    Provider("antigravity", "Antigravity", "antigravity", "Modell-Limits deiner Antigravity-Anmeldung", "#85A9FF", "AG",
             "https://antigravity.google/docs/models"),
    Provider("gemini", "Google AI Studio", "browser", "Dein Google-AI-Studio-Projekt", "#6599F5", "AS",
             "https://aistudio.google.com", domains=("google.com",),
             session_cookies=("SID", "__Secure-1PSID", "__Secure-3PSID"),
             account_selectors=('a[href*="SignOutOptions"]', 'button[aria-label*="Google Account"]',
                                'a[aria-label*="Google Account"]', 'a[aria-label*="Google-Konto"]',
                                'button[aria-label*="Google-Konto"]')),
    Provider("gemini_chat", "Gemini", "browser", "Dein Gemini-Chat-Abonnement", "#6599F5", "✦",
             "https://gemini.google.com/usage", domains=("google.com",), login_url="https://gemini.google.com/app",
             session_cookies=("SID", "__Secure-1PSID", "__Secure-3PSID"),
             account_selectors=('a[href*="SignOutOptions"]', 'button[aria-label*="Google Account"]',
                                'a[aria-label*="Google Account"]', 'a[aria-label*="Google-Konto"]',
                                'button[aria-label*="Google-Konto"]')),
    Provider("deepseek", "DeepSeek", "browser", "Dein DeepSeek-Chat", "#6F8BF7", "DS",
             "https://chat.deepseek.com", domains=("deepseek.com",), session_cookies=("userToken", "ds_session_id"),
             account_selectors=('[data-testid="user-avatar"]', '[data-testid="user-menu"]',
                                'button[aria-label*="Profile"]')),
    Provider("perplexity", "Perplexity", "browser", "Recherche & dein Pro-Konto", "#44B5BC", "P",
             "https://www.perplexity.ai", domains=("perplexity.ai",),
             session_cookies=("__Secure-next-auth.session-token", "__Secure-authjs.session-token"),
             account_selectors=('button[aria-label*="Account"]', 'button[aria-label*="Profile"]',
                                'a[href="/settings/account"]', '[data-testid="user-avatar"]')),
    Provider("lechat", "Le Chat", "browser", "Dein Mistral-Chat", "#E4A44F", "M",
             "https://chat.mistral.ai/chat", domains=("mistral.ai",),
             session_cookies=("session", "session_token", "__Secure-next-auth.session-token"),
             account_selectors=('[data-testid="user-menu"]', 'button[aria-label*="Account"]',
                                'button[aria-label*="Profile"]')),
    Provider("openai_api", "OpenAI API", "api", "Dein Entwickler-Zugang", "#37B99C", "AI",
             "https://platform.openai.com/settings/organization/usage", "https://api.openai.com/v1/models"),
    Provider("anthropic_api", "Claude API", "api", "Dein Anthropic-API-Zugang", "#CC8D6B", "CA",
             "https://platform.claude.com", "https://api.anthropic.com/v1/models"),
    Provider("gemini_api", "Gemini API", "api", "Dein Google-API-Projekt", "#6599F5", "GA",
             "https://aistudio.google.com/usage", "https://generativelanguage.googleapis.com/v1beta/models"),
    Provider("deepseek_api", "DeepSeek API", "api", "Guthaben direkt aus der API", "#6F8BF7", "DA",
             "https://platform.deepseek.com/usage", "https://api.deepseek.com/user/balance"),
    Provider("groq", "Groq", "api", "Schnelle Inferenz, eigener Zugang", "#EF936C", "Q",
             "https://console.groq.com/settings/usage", "https://api.groq.com/openai/v1/models"),
    Provider("mistral_api", "Mistral API", "api", "Dein Mistral-API-Zugang", "#E4A44F", "MA",
             "https://console.mistral.ai", "https://api.mistral.ai/v1/models"),
    Provider("openai_usage", "OpenAI Nutzung", "api", "Tokenstatistik deiner Organisation", "#37B99C", "OU",
             "https://platform.openai.com/settings/organization/admin-keys", "https://api.openai.com/v1/organization/usage/completions",
             credential_hint="Benötigt einen OpenAI-Admin-Schlüssel mit Leserecht für Usage.\nErfasst die Modellnutzung deiner API-Organisation, nicht ChatGPT."),
    Provider("anthropic_usage", "Claude API Nutzung", "api", "Tokenstatistik deiner Organisation", "#CC8D6B", "CU",
             "https://platform.claude.com/settings/admin-keys", "https://api.anthropic.com/v1/organizations/usage_report/messages",
             credential_hint="Benötigt einen Anthropic-Admin-Zugang für Usage Reports.\nNur API-Organisationen; kein Claude-Chat-Abonnement."),
)
PROVIDERS = {provider.id: provider for provider in CATALOG}


def tracking_support(provider_id):
    if provider_id in ("openai_usage", "anthropic_usage"):
        return "Tracking: Organisations-Tokenverbrauch, 7 Tage; Admin-Zugang erforderlich"
    if provider_id == "openrouter":
        return "Tracking: Schlüsselbudget & Kosten; Kontoguthaben im Anbieter-Dashboard"
    if provider_id == "deepseek_api":
        return "Tracking: API-Guthaben; kein globaler Tokenzähler"
    if provider_id == "claude":
        return "Abo-Limits: 5 Stunden & Woche, verbleibend und Reset"
    if provider_id == 'chatgpt':
        return "Abo-Limits: Codex, 5 Stunden & Woche aus deiner Codex-Anmeldung"
    if provider_id == 'gemini_chat':
        return "Abo-Limits: 5 Stunden & Woche aus Gemini → Nutzungslimits"
    if provider_id == 'antigravity':
        return "Antigravity-Limits: Gemini & Claude/GPT, jeweils 5 Stunden und Woche"
    if provider_id == 'gemini':
        return "API-Projekt; für Google-Abo-Limits die Verbindung »Gemini« verwenden"
    if PROVIDERS[provider_id].kind == "browser":
        return "Tracking: sichtbare Limit-Meldungen; kein garantierter Restzähler"
    return "Zugang prüfbar; Tokenstatistik nur im Anbieter-Dashboard"
