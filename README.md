# TokenTracker 2.5

Ein lokales Python-Cockpit für KI-Anbieter, Guthaben und verfügbare Nutzungslimits.

## Starten

Unter Windows `start.bat` doppelklicken. Benötigt Python 3.10 oder neuer und Chrome oder Microsoft Edge für Browser-Verbindungen. Der Starter erstellt die virtuelle Umgebung und aktualisiert Abhängigkeiten, sobald `requirements.txt` geändert wurde. Eine zusätzliche Playwright-Browserinstallation ist nicht nötig.

Alternativ aus dem Projektordner:

```powershell
.\venv\Scripts\python.exe -m pip install -r requirements.txt
.\venv\Scripts\python.exe main.py
```

## Verbindungen

In **Einstellungen → Anbieter** jeden Zugang einzeln verbinden. Auf der Übersicht stehen ausschließlich verbundene und eingeschaltete Anbieter. Ausschalten blendet den Anbieter aus und pausiert neue Abrufe; der Zugang bleibt gespeichert. Trennen entfernt den lokalen API-Schlüssel oder das betreffende Browser-Profil. Einen API-Schlüssel beim Anbieter widerrufen, wenn auch dessen externe Berechtigung entfallen soll.

- **OpenRouter:** »Im Browser verbinden« öffnet die offizielle PKCE-Anmeldung. Im Browser freigeben und zur App zurückkehren. Der Rückruf läuft ausschließlich über einen temporären localhost-Port. Ein bestehender Schlüssel kann alternativ über den verdeckten Eingabedialog verbunden werden.
- **Codex · ChatGPT:** »Codex verbinden« nutzt deine vorhandene Anmeldung in der offiziellen Codex-App oder CLI. Die dokumentierte App-Server-Schnittstelle liefert die Abo-Limits; ein ChatGPT-Browserfenster ist dafür nicht nötig. Ein API-Schlüssel liefert keine ChatGPT-Abo-Limits. »Trennen« entfernt die Verbindung in TokenTracker und meldet die offizielle Codex-App nicht ab.
- **Antigravity:** »Verbinden« übernimmt die bestehende Anmeldung in der laufenden Antigravity-App. »Antigravity öffnen« startet die installierte App bei Bedarf; automatische Abrufe starten oder laden sie niemals neu. Gemini und Claude/GPT haben eigene 5-Stunden- und Wochenfenster, also vier getrennte Restbalken mit Reset-Zeiten. Gemini Chat und Google AI Studio sind eigenständige Produkte und liefern diese Antigravity-Limits nicht. »Trennen« entfernt nur die Tracker-Verbindung und meldet Antigravity nicht ab.
- **Claude, Gemini, Google AI Studio, DeepSeek, Perplexity, Le Chat:** Anmeldung im separaten, normalen Chrome-/Edge-Fenster. Gemini Chat und Google AI Studio sind eigene Verbindungen mit getrennten Profilen. Die App prüft die Sitzung automatisch für fünf Minuten und berücksichtigt auch weitere Anbieter-Tabs. Weiterleitungen und Navigationen innerhalb einer Seite verlieren den Login nicht. Während der Anmeldung bleiben Browser-Seite, App-Eingaben und Scrollposition erhalten. Das erneute Öffnen eines laufenden Logins erhält dessen Formular. Sicherheitsprüfungen beim Anbieter selbst abschließen. Bei »Anmeldung nicht bestätigt« das Konto-Menü im Browser öffnen und in der App »Prüfen« wählen.
- **OpenAI API, Claude API, Gemini API, DeepSeek API, Groq, Mistral API:** API-Schlüssel eingeben; er wird vor dem Speichern über einen lesenden API-Aufruf geprüft. Es werden keine kostenpflichtigen Modellantworten erzeugt. Chat-Abonnements und Entwickler-APIs sind getrennte Zugänge.

Browser-Verbindungen starten keine unsichtbaren Headless-Browser. Manuelle Logins verwenden keine Chrome-Automationsoptionen und keine Skripte zur Änderung des Browser-Fingerprints. Die lokale Leseverbindung ist an einen zufälligen, ausschließlich auf `127.0.0.1` erreichbaren Port und das konkrete Anbieter-Profil gebunden. Die App kann eine Sicherheitsprüfung des Anbieters weiterhin nicht selbst beantworten.

**Claude:** Die Anmeldung beginnt auf der normalen Startseite. Einen per E-Mail erhaltenen Login-Link im selben Anbieter-Fenster öffnen, damit die Sitzung in dessen Profil gespeichert wird. Nach bestätigter Anmeldung lädt die App die originale Nutzungsübersicht in einem eigenen Hintergrund-Tab. Der Login-/Chat-Tab und der Vordergrund bleiben erhalten; nur der von der App angelegte Nutzungs-Tab wird bei einem Abruf aktualisiert.

**Gemini:** Der Eintrag »Gemini« liest die originale Seite `https://gemini.google.com/usage`. »Aktuelle Nutzung« ist das 5-Stunden-Fenster, »Wöchentliches Limit« das Wochenfenster. Die Anmeldung beginnt weiterhin auf der normalen Gemini-App-Seite. Google rendert teilweise ausgeblendete und sichtbare Kopien seines Konto-Links; die Erkennung prüft alle passenden sichtbaren Kontoelemente. Der Leser wartet auf die tatsächlichen Nutzungs-Komponenten statt auf einen Dialog und unterstützt deutsche/englische Prozentwerte sowie die angezeigten Reset-Uhrzeiten und -Daten. Alle Abrufe finden in einem eigenen Leser statt, ohne einen Chat zu öffnen oder Prompts zu erzeugen. Google AI Studio bleibt eine eigenständige API-Projektverbindung.

**Bei geschlossenem Anbieter-Fenster:** Codex wird direkt über die offizielle lokale Schnittstelle aktualisiert. Browser-Verbindungen, einschließlich Claude und Gemini, pausieren den automatischen Abruf; gespeicherte Messwerte bleiben als älterer Stand sichtbar. »Prüfen« oder »Anmelden« öffnet das Anbieter-Fenster bewusst wieder. Laufende Login-Formulare werden weiterhin nie neu geladen. Ein nach App-Neustart noch geöffnetes Anbieter-Fenster wird wieder angebunden. Anbieter-Sicherheitsprüfungen müssen bei Bedarf im sichtbaren Fenster abgeschlossen werden.

**Abo-Kapazität:** Kurzübersicht und Dashboard zeigen **5 Stunden** und **Woche** mit separaten Restbalken und gemeldeten Reset-Zeiten. »100% übrig« bedeutet unverbrauchte gemeldete Kapazität; »0% übrig« bedeutet ausgeschöpft. Der große Restwert zeigt das knappere gemeldete Zeitfenster. Ein nicht gemeldetes Fenster wird nie als 100% oder unlimitiert ausgegeben. Diese Abo-Limits sind Prozentwerte, keine feste restliche Tokenanzahl. Bei Abruffehlern bleiben echte frühere Messwerte als älterer Stand sichtbar; `.tracker/usage.json` speichert nur Prozentwerte, Reset-Zeiten, Quelle und Messzeitpunkt und übersteht App-Neustarts. Ein abgelaufener Reset setzt den Balken erst nach einer neuen Anbieter-Messung zurück.

Ein bestätigter Zugang und verfügbare Nutzungsdaten werden getrennt angezeigt. Jeder Anbieter erklärt bereits in den Einstellungen, welches Tracking verfügbar ist.

| Verbindung | Automatisch angezeigte Daten |
| --- | --- |
| OpenRouter | Kosten gesamt/heute und verbleibendes Schlüsselbudget, wenn gesetzt. Das Kontoguthaben ist separat; der normale PKCE-Schlüssel kann es nicht über die Management-API abrufen. |
| Codex · ChatGPT | Verbleibende 5-Stunden- und Wochenkapazität samt Reset aus `account/rateLimits/read`, anhand der gemeldeten Fensterdauer zugeordnet. Funktioniert unabhängig vom ChatGPT-Browser. |
| Antigravity | Jeweils 5 Stunden und Woche für die separaten Pools Gemini und Claude/GPT. Bruchteile verbleibender Kapazität und Reset-Zeiten aus dem Quota-Dienst der laufenden offiziellen Antigravity-App. |
| Claude Chat | Verbleibende Sitzungs- und Wochenkapazität samt Reset, wenn die eigene Nutzungsseite diese Werte liefert. Auch ein volles Wochenlimit erzeugt einen Hinweis. |
| Gemini Chat | Verbleibende 5-Stunden- und Wochenkapazität aus der tatsächlich geöffneten Abo-Nutzungsübersicht. Nicht lesbare Werte bleiben ausdrücklich unbekannt. |
| DeepSeek API | Kontoguthaben, auch bei gültigem Zugang mit leerem Guthaben. |
| OpenAI Nutzung | Input inklusive Cache und Output aus dem offiziellen Organisationsbericht für Modellanfragen, sieben UTC-Kalendertage einschließlich heute. Benötigt einen Admin-Schlüssel mit Usage-Berechtigung. ChatGPT-Nutzung und andere API-Dienste sind separat. |
| Claude API Nutzung | Input inklusive Cache-Lesen/Schreiben und Output aus dem offiziellen Organisationsbericht, gleicher Zeitraum. Benötigt einen passenden Admin-Zugang einer Claude-Console-Organisation; kein privates Chat-Abonnement. |
| AI Studio, DeepSeek Chat, Perplexity, Le Chat | Bestätigter Sitzungsstatus und lesbare Limit-Hinweise. AI Studio ist ein API-Projektzugang, kein Gemini-Abo-Zähler. |
| Normale OpenAI-, Claude-, Gemini-, Groq-, Mistral-API-Schlüssel | Zugang wird geprüft. Diese Integration bekommt damit keinen organisationsweiten Tokenbericht; die Nutzung lässt sich über das Anbieter-Dashboard öffnen. |

**OpenAI Nutzung** und **Claude API Nutzung** sind optionale, einzeln schaltbare Verbindungen unter den Entwickler-APIs. Ihre Eingabedialoge erklären den benötigten Schlüssel. Es werden ausschließlich lesende Nutzungsabfragen ausgeführt. Berichte können beim Anbieter verzögert sein. Alle Seiten eines Berichts werden zusammengezählt; bei unvollständigen oder veränderten Antworten wird keine geschätzte Summe angezeigt.

Nicht verfügbare Werte heißen ausdrücklich »Nicht verfügbar«; »Verbunden« bedeutet keinen unbegrenzten Zugang. Für Browser-Verbindungen liest die App Kontonachweise und Nutzungsantworten, die die originale Seite selbst liefert. Chat-Inhalte werden nicht als Nutzungszähler interpretiert. Layoutänderungen oder Sicherheitsprüfungen der Anbieter können die Sitzungserkennung beeinträchtigen. »Beim Anbieter öffnen« zeigt die originale Übersicht.

## Darstellung und Bedienung

Die App startet als **kleine Kurzübersicht**. »Ausklappen« bzw. ↗ öffnet das große Dashboard, »Kurzübersicht« oder das Schließen des großen Fensters klappt es wieder ein. Beide Fenster halten sich nur dann über anderen Fenstern, wenn **Immer im Vordergrund** aktiviert ist. Die Position der Kurzübersicht wird gespeichert.

Das **T-Symbol im Windows-Infobereich** (gegebenenfalls unter »^«) bleibt im Hintergrund verfügbar. Linksklick öffnet die Kurzübersicht, Rechtsklick das Menü mit Dashboard, Einstellungen, Aktualisieren, Vordergrund-Schalter und **Beenden**. Das Schließen oder »—« der Kurzübersicht blendet sie in den Infobereich aus; Abrufe laufen weiter. »Beenden« im Symbol-Menü schließt die App vollständig. Ein weiterer Start zeigt die bereits laufende Kurzübersicht an.

**Einstellungen → Darstellung:** Hell, Dunkel, Windows-Systemschema und »Immer im Vordergrund«. **Allgemein:** manuell oder automatische Aktualisierung alle 1, 5, 10, 15, 30 oder 60 Minuten. Einstellungen werden sofort gespeichert. Tastenkürzel: `Strg+R` aktualisiert, `Strg+,` öffnet die Einstellungen.

Hintergrundprüfungen aktualisieren nur Werte und bauen die Einstellungen nicht erneut auf. Die Kurzübersicht wird dabei weder positioniert noch nach vorne geholt. Startfehler stehen in `.tracker/startup-error.log`, Fehler aus UI-Aktionen in `.tracker/ui-error.log` (Stack und Fehlertyp ohne Eingabewerte).

## Lokale Daten und Migration

Alle Pfade werden vom Projektordner aus aufgelöst, unabhängig vom aktuellen Arbeitsverzeichnis. `config.json` enthält Einstellungen und Verbindungsstatus. `.tracker/credentials.json` enthält ausschließlich per Windows DPAPI verschlüsselte Schlüssel, lesbar mit demselben Windows-Konto. `.tracker/browser/<anbieter>` enthält getrennte Chrome-Profile. `.tracker/usage.json` enthält ausschließlich den letzten gemessenen Abo-Stand und bestätigt keine Anmeldung. Diese Ordner enthalten persönliche Sitzungen und gehören nicht in Git. Liegt das Projekt in OneDrive, können lokale Dateien gemäß deiner OneDrive-Konfiguration synchronisiert werden.

Der bisherige Klartext-OpenRouter-Schlüssel wird beim ersten Start verschlüsselt übernommen, anschließend aus `config.json` entfernt und vor Anzeige geprüft. Die alte Datei `auth_state.json` mit »ready« gilt nicht als Anmeldung. Das bisher gemeinsam genutzte `chrome_profile` wird erhalten; die Anbieter müssen in ihren neuen getrennten Profilen erneut angemeldet werden. Der frühere »Antigravity«-Eintrag öffnete tatsächlich Google AI Studio und heißt jetzt entsprechend Google AI Studio. Seit 2.5 hat die echte Antigravity-App einen eigenen Eintrag, unabhängig von diesen Browser-Profilen. Originale Programmdateien liegen unter `.tracker/original-source`.

## Tests

```powershell
.\venv\Scripts\python.exe -m unittest discover -s tests -v
.\venv\Scripts\python.exe tests/ui_smoke.py
.\venv\Scripts\python.exe tests/browser_smoke.py
```

Backend-Tests prüfen Verschlüsselung/Migration, Sichtbarkeit, Sitzungsnachweise aller Browser-Adapter, ungültige und abgelaufene Zugänge, API-Fehler, Tokenberichte mit Pagination und Cache-Zählung, PKCE-Rückrufe, abgebrochene Hintergrundvorgänge und doppelte App-Starts. UI-Tests verwenden isolierte Testdaten ohne echte Schlüssel und prüfen 60 wiederholte Datenaktualisierungen auf stabile Eingaben, Fokus, Scrollposition, Fensterposition, Vordergrund-Verhalten sowie Auf-/Einklappen und das echte Windows-Symbol. Zusätzlich prüfen sie die Übernahme eines erkannten Logins und die Kennzeichnung älterer Messwerte. Der Browser-Test verwendet echtes Chrome und ausschließlich lokale Testseiten: native WebDriver-Markierung aus, Login in einem weiteren Tab, Navigation per History-API, verspätete Gast-Antworten, getrennte Nachweise je Tab, gespeicherte mehrteilige Sitzungs-Cookies, DOM-/JSON-Nutzungsdaten im Hintergrund-Tab, abgelaufene Sitzungen, unveränderte Login-Seiten/Weiterleitungen, geschlossene Login-Fenster, Profile und Trennen. Tests mit lokalen Fixtures bestätigen die Adapterlogik; persönliche Anbieter-Anmeldungen erfordern die jeweiligen Konten.

## Verwendete Anbieter-Dokumentation

[OpenRouter PKCE](https://openrouter.ai/docs/guides/overview/auth/oauth), [OpenRouter Limits](https://openrouter.ai/docs/api/reference/limits), [DeepSeek Guthaben](https://api-docs.deepseek.com/api/get-user-balance/), [OpenAI Authentifizierung](https://developers.openai.com/api/reference/overview), [Claude Modelle](https://platform.claude.com/docs/en/api/models/list), [Gemini Modelle](https://ai.google.dev/api/models), [Groq API](https://console.groq.com/docs/api-reference), [Mistral Modelle](https://docs.mistral.ai/api/endpoint/models).

[OpenRouter Guthaben und Management-Zugang](https://openrouter.ai/docs/api/api-reference/credits/get-remaining-credits), [OpenAI Organisations-Nutzung](https://developers.openai.com/api/reference/resources/admin/subresources/organization/subresources/usage), [Claude Usage & Cost API](https://platform.claude.com/docs/en/manage-claude/usage-cost-api), [Claude Nutzungsbericht-Schema](https://platform.claude.com/docs/en/api/beta/organization/usage_report/retrieve_messages).

[Codex App-Server](https://developers.openai.com/codex/app-server), [Codex Abo-Limits](https://developers.openai.com/codex/pricing), [Claude Nutzungslimits](https://support.claude.com/en/articles/11647753-how-do-usage-and-length-limits-work), [Gemini Abo-Limits](https://support.google.com/gemini/answer/16275805).

[Antigravity Modelle und View Usage](https://antigravity.google/docs/models), [Antigravity Tarife und Quota-Fenster](https://antigravity.google/docs/plans). Der lokale Aufruf `RetrieveUserQuotaSummary` und sein Schema wurden mit dem ausgelieferten offiziellen Engine-Frontend geprüft. Nur der laufende Antigravity-Prozess und seine eigenen Ports werden erkannt; der Aufruf geht ausschließlich per HTTPS an `127.0.0.1`, ohne Weiterleitungen oder Proxys. Der lokale CSRF-Wert bleibt im Arbeitsspeicher und wird nicht gespeichert. Google-Anmeldedateien werden nicht gelesen. Bei geschlossener Antigravity-App bleibt der letzte echte Messstand als veraltet sichtbar. Ein deaktiviertes oder nicht gemeldetes Fenster gilt niemals als 100% verfügbar. AI-Credit-Zukäufe und Modellanfragen werden nicht ausgeführt. Die lokale Schnittstelle ist kein öffentlich zugesichertes Integrations-API; bei Änderungen meldet die App einen Abruffehler, statt Kapazität zu schätzen.
