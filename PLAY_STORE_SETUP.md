# Google Play Store & Android Release Setup (`dev.nairolf.tokentracker`)

> **Stand:** Der Upload-Keystore wurde bereits erzeugt (lokal in `%USERPROFILE%\AgentAmpel-keystore`, **Backup anlegen!**) und die vier Keystore-Secrets sind in GitHub gesetzt. Schritt 1 entfällt. Offen sind nur Schritt 2 (Service Account), Schritt 3 (erstes AAB von Hand) und das Secret `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`. Bis dahin installieren Tester die APK aus dem GitHub Release.


Diese Anleitung beschreibt Schritt für Schritt, wie du das automatische Android-Signing sowie den vollautomatischen Upload des Android App Bundles (`.aab`) in den **Google Play Store (Internal Testing Track)** über GitHub Actions (`.github/workflows/release.yml`) einrichtest.

> **Wichtiger Hinweis zur Ausfallsicherheit:**  
> Unsere GitHub Actions Pipeline ist so konfiguriert, dass sie **auch ohne gesetzte Secrets sofort funktioniert**! Solange `ANDROID_KEYSTORE_BASE64` noch nicht hinterlegt ist, generiert die Pipeline automatisch einen Fallback-Keystore, damit `AgentAmpel-android.apk` und `AgentAmpel-android.aab` bei jedem Push gebaut und an das GitHub Release angehängt werden. Sobald du die 4 Schritte unten abschließt, signiert GitHub Actions mit deinem Produktions-Keystore und lädt jedes Release direkt in die Google Play Console hoch.

---

## Schritt 1: Upload-Keystore generieren & in Base64 umwandeln

Für den Google Play Store benötigst du einen eigenen Upload-Keystore (`upload-keystore.jks`). Bewahre diese Datei sowie die Passwörter sicher auf (z. B. im Passwort-Manager) und committe sie **niemals** ins Git-Repository.

### 1.1 Keystore mit `keytool` erstellen

**Windows (PowerShell):**
```powershell
keytool -genkeypair -v `
  -keystore upload-keystore.jks `
  -keyalg RSA `
  -keysize 2048 `
  -validity 10000 `
  -alias upload
```

**Linux / macOS (Bash / Zsh):**
```bash
keytool -genkeypair -v \
  -keystore upload-keystore.jks \
  -keyalg RSA \
  -keysize 2048 \
  -validity 10000 \
  -alias upload
```

Merke dir die beiden vergebenen Passwörter (`ANDROID_STORE_PASSWORD` und `ANDROID_KEY_PASSWORD`) sowie den Alias (`upload`).

### 1.2 Keystore in einen einzeiligen Base64-String umwandeln (`ANDROID_KEYSTORE_BASE64`)

Damit GitHub Actions die Binärdatei `upload-keystore.jks` sicher aus einem GitHub Secret wiederherstellen kann, wandelst du sie in einen Base64-String um:

**Windows (PowerShell – kopiert den String direkt in die Zwischenablage):**
```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("upload-keystore.jks")) | Set-Clipboard
Write-Host "Base64-String wurde in die Zwischenablage kopiert!"
```

**Linux (Bash):**
```bash
base64 -w 0 upload-keystore.jks
```

**macOS (Zsh / Bash):**
```bash
base64 -i upload-keystore.jks | tr -d '\n' | pbcopy
echo "Base64-String wurde in die Zwischenablage kopiert!"
```

Speichere diesen Base64-Wert später als GitHub Secret **`ANDROID_KEYSTORE_BASE64`** (siehe Schritt 4).

---

## Schritt 2: Google Cloud & Play Console Service Account einrichten

Damit GitHub Actions per API neue Versionen in deinen Google Play Developer Account hochladen darf, wird ein **Google Cloud Service Account** mit aktivierter **Google Play Android Developer API** benötigt.

### 2.1 Google Play Android Developer API aktivieren & Service Account erstellen
1. Öffne die [Google Cloud Console](https://console.cloud.google.com/) und wähle ein bestehendes Projekt aus (oder erstelle ein neues Projekt, z. B. `AgentAmpel-PlayStore-Deploy`).
2. Navigiere im linken Menü zu **APIs & Dienste** → **Bibliothek** (*APIs & Services → Library*).
3. Suche nach **`Google Play Android Developer API`**, klicke darauf und wähle **Aktivieren** (*Enable*).
4. Navigiere zu **IAM & Verwaltung** → **Dienstkonten** (*IAM & Admin → Service Accounts*).
5. Klicke oben auf **+ Dienstkonto erstellen** (*+ Create Service Account*):
   - **Dienstkontoname:** `github-actions-play-uploader`
   - Klicke auf **Erstellen und fortfahren** (*Create and Continue*) und anschließend auf **Fertig** (*Done*).
6. Kopiere dir die generierte **E-Mail-Adresse des Dienstkontos** (z. B. `github-actions-play-uploader@<projekt-id>.iam.gserviceaccount.com`).

### 2.2 JSON-Schlüssel für das Dienstkonto herunterladen
1. Klicke in der Liste der Dienstkonten auf dein neu erstelltes Konto `github-actions-play-uploader`.
2. Wechsle oben auf den Reiter **Schlüssel** (*Keys*).
3. Klicke auf **Schlüssel hinzufügen** → **Neuen Schlüssel erstellen** (*Add Key → Create new key*).
4. Wähle **JSON** und klicke auf **Erstellen** (*Create*).
5. Eine `.json`-Datei wird automatisch heruntergeladen. Der **gesamte Textinhalt** dieser Datei wird später als GitHub Secret **`GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`** hinterlegt.

### 2.3 Dienstkonto in der Google Play Console berechtigen
1. Öffne die [Google Play Console](https://play.google.com/console/).
2. Klicke im linken Hauptmenü auf **Nutzer und Berechtigungen** (*Users and permissions*).
3. Klicke auf **Neue Nutzer einladen** (*Invite new users*).
4. Füge unter **E-Mail-Adresse** die E-Mail-Adresse deines Service Accounts ein (`github-actions-play-uploader@...iam.gserviceaccount.com`).
5. Vergib unter **Berechtigungen** (*Permissions*):
   - **Reiter „App-Berechtigungen" (*App permissions*):** Füge deine App **`Agent-Ampel` (`dev.nairolf.tokentracker`)** hinzu (oder vergib die Berechtigungen direkt auf Kontoebene).
   - Aktiviere mindestens folgende Rechte:
     - **App-Informationen ansehen und Sammelberichte herunterladen** (*View app information and download bulk reports*)
     - **Releases auf Test-Tracks verwalten (Interner Test / Geschlossener Test)** (*Release to testing tracks / Manage testing track releases*)
     - Optional: **Produktion verwalten** (*Release to production*), falls du später auch auf den Production-Track veröffentlichen möchtest.
6. Klicke unten rechts auf **Nutzer einladen** (*Invite user*) und bestätige die Einladung.

---

## Schritt 3: Erstmaliger manueller Upload (Wichtige Google-Restriktion!)

> [!IMPORTANT]  
> **Wichtige Einschränkung der Google Play Developer API:**  
> Google erlaubt das automatische Anlegen einer **komplett neuen App-ID (`dev.nairolf.tokentracker`)** per API **nicht**. Die App muss einmalig manuell in der Google Play Console angelegt werden, und das **allererste `.aab` (Android App Bundle)** muss einmalig manuell hochgeladen werden. Alle darauffolgenden Releases laufen danach zu 100 % vollautomatisch über GitHub Actions!

So führst du den einmaligen Initial-Upload durch:
1. Stelle sicher, dass du in Schritt 1 & Schritt 4 deinen Produktions-Keystore (`ANDROID_KEYSTORE_BASE64`, `ANDROID_STORE_PASSWORD`, `ANDROID_KEY_PASSWORD`, `ANDROID_KEY_ALIAS`) bereits in den GitHub Secrets hinterlegt hast, damit das erste `.aab` mit deinem endgültigen Upload-Key signiert wird.
2. Starte den Workflow **Multi-Platform Release & Play Store Deployment** in GitHub Actions (oder pushe auf `main`) und lade aus den **GitHub Actions Artifacts** (`android-release`) oder von der **GitHub Releases**-Seite die Datei **`AgentAmpel-android.aab`** (bzw. `app-release.aab`) herunter.
3. Öffne die [Google Play Console](https://play.google.com/console/) und klicke auf **App erstellen** (*Create app*):
   - **App-Name:** `Agent-Ampel & Usage-HUD`
   - **Standardsprache:** `Deutsch (Deutschland)`
   - **App oder Spiel:** `App`
   - **Kostenlos oder kostenpflichtig:** `Kostenlos`
4. Navigiere im linken Menü deiner neuen App zu **Testen** → **Interner Test** (*Testing → Internal testing*).
5. Klicke auf **Neues Release erstellen** (*Create new release*):
   - Bestätige ggf. die Aktivierung von **Play App-Signatur** (*Play App Signing*).
   - Lade unter **App Bundles** deine heruntergeladene Datei **`AgentAmpel-android.aab`** manuell hoch.
   - Vergib einen Release-Namen (z. B. `1.0.1`) und klicke auf **Speichern** (*Save*) bzw. **Release überprüfen** (*Review release*).
6. **Hinweis zum App-Status (`completed` vs. `draft`):**
   - Solange in deiner Google Play Console noch Pflichtangaben im Dashboard (Datenschutzerklärung, Altersfreigabe, Zielgruppe) fehlen, befindet sich die App im Status **Entwurf (`draft`)**.
   - Falls dein Account das erste Release noch als Entwurf führt, kannst du in `.github/workflows/release.yml` beim Schritt `Upload AAB to Google Play Store (Internal Testing Track)` die Zeile `status: completed` temporär auf `status: draft` setzen, bis alle Store-Fragebögen ausgefüllt sind.

---

## Schritt 4: Exakte GitHub Secrets Tabelle

Öffne dein GitHub-Repository **`https://github.com/NairolfDev/TokenTracker`** und navigiere zu:  
**Settings** → **Secrets and variables** → **Actions** → **New repository secret**.

Lege dort exakt die folgenden **5 Repository Secrets** an:

| GitHub Secret Name | Pflicht / Optional | Beschreibung & Format | Beispielwert |
| :--- | :--- | :--- | :--- |
| **`ANDROID_KEYSTORE_BASE64`** | Empfohlen (Fallback vorhanden) | Einzeiliger Base64-String deiner `upload-keystore.jks`-Datei aus **Schritt 1.2**. | `MIIJQwIBAzCCCP8GCSqGSIb3DQEHAaCCC...` |
| **`ANDROID_KEY_ALIAS`** | Empfohlen (Standard: `upload`) | Der Key-Alias, den du beim `keytool`-Befehl unter `-alias` angegeben hast. | `upload` |
| **`ANDROID_STORE_PASSWORD`** | Empfohlen | Das Keystore-Passwort (`-storepass`) deiner `upload-keystore.jks`-Datei. | `MeinSicheresStorePasswort!` |
| **`ANDROID_KEY_PASSWORD`** | Empfohlen | Das Schlüssel-Passwort (`-keypass`) für den Key-Alias (oft identisch mit `ANDROID_STORE_PASSWORD`). | `MeinSicheresKeyPasswort!` |
| **`GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`** | Optional (aktiviert Play-Store-Upload) | Der **komplette JSON-Inhalt** der heruntergeladenen Google Cloud Service-Account-Schlüsseldatei aus **Schritt 2.2**. | `{"type": "service_account", "project_id": "...", "private_key": "-----BEGIN PRIVATE KEY-----\n..."}` |

---

## Zusammenfassung des automatischen Release-Workflows

Sobald die Secrets eingerichtet sind, führt jeder Push auf `main`/`master` oder jeder Tag-Push (`v*.*.*`) vollautomatisch folgende Schritte aus:
1. **Windows (`windows-latest`):** Baut und veröffentlicht `AgentAmpel-windows-x64.zip` und `AgentAmpel-windows-x64.exe`.
2. **Linux (`ubuntu-latest`):** Baut und veröffentlicht `AgentAmpel-linux-x64.tar.gz`.
3. **macOS (`macos-latest`):** Baut und veröffentlicht `AgentAmpel-macos.zip`.
4. **Web (`ubuntu-latest`):** Baut und veröffentlicht `AgentAmpel-web.zip`.
5. **Android (`ubuntu-latest`):** Baut und signiert `AgentAmpel-android.apk` sowie `AgentAmpel-android.aab` und lädt das `.aab` direkt in den **Google Play Store (`internal` Track)** hoch.
6. **In-App Auto-Updater (`AutoUpdaterService`):** Laufende Clients prüfen beim Start sowie alle 30 Minuten `https://api.github.com/repos/NairolfDev/TokenTracker/releases/latest`, erkennen neue Versionen per Semantic Versioning und installieren das Update auf Knopfdruck.
