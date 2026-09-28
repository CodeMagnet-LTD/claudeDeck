# ClaudeDeck

Birden fazla projede aynı anda çalışan Claude Code (CLI) oturumlarını tek pencereden yöneten macOS uygulaması.
Claude'u sarmalamaz ya da taklit etmez: her oturum gömülü bir terminalde (SwiftTerm, gerçek pty) senin kurulu
`claude` komutunu login shell üzerinden çalıştırır. Ayarların, `CLAUDE.md`'lerin, remote-control, MCP ve diğer
hook'ların aynen geçerlidir.

## Derleme

```sh
./build.sh          # release → build/ClaudeDeck.app (takım sertifikasıyla imzalı)
./build.sh run      # derle ve (yeniden) başlat
swift test          # Core birim testleri
xcodegen generate   # ClaudeDeck.xcodeproj'u project.yml'den üret, sonra Xcode'da aç
```

Xcode projesi üretilir; ayarları (takım, bundle id) `project.yml` içinde değiştir. Xcode ilk açılışta
SwiftTerm'in build eklentisi için "Trust & Enable" sorar.

Uygulama ikonu kodla çizilir: `swift tools/make-icon.swift Support` → `Support/AppIcon.icns`
(`build.sh` kopyalar) ve `Support/Assets.xcassets/AppIcon.appiconset` (Xcode derlemesi kullanır).

## Dağıtım / Notarization

```sh
./notarize.sh   # derle → Developer ID ile imzala → notarize et → zımbala (staple) → spctl ile doğrula
```

Başka Mac'lerde Gatekeeper uyarısı olmadan açılması için gerekir. Ön koşullar (bir kez):

1. Anahtar zincirinde **Developer ID Application** sertifikası (Xcode › Settings › Accounts ›
   Manage Certificates › "+"; Apple Development sertifikası yetmez). Birden fazlaysa
   `DEVELOPER_ID="Developer ID Application: Ad (TAKIMID)"` ile seç.
2. notarytool profili (app-specific password ile):
   `xcrun notarytool store-credentials claudedeck --apple-id <e-posta> --team-id V6G4B5T63L --password <app-specific-password>`
   Farklı ad için `NOTARY_PROFILE=<ad>`.

Çıktı: zımbalanmış `build/ClaudeDeck.app` ve dağıtılacak `build/ClaudeDeck.zip`. Sertifika yoksa
betik hiçbir şey derlemeden/göndermeden açıklamayla durur.

## Durum nasıl bilinir (ekran okuma yok)

1. İlk açılışta `~/.claude/settings.json` dosyasına ClaudeDeck hook'u **eklenir** (önce
   `settings.json.claudedeck-backup-<zaman>` yedeği alınır; diğer hook'lara dokunulmaz; tekrar
   eklenmez). Ayarlar › "Kaldır" ile geri alınır.
2. Hook (`~/.claude/deck/bin/deck-hook.sh`, sh + `/usr/bin/jq`) yalnızca `CLAUDEDECK_TERMINAL_ID`
   taşıyan terminallerde çalışır ve `~/.claude/deck/sessions/<session_id>.json` dosyasını atomik yazar.
3. Uygulama bu klasörü DispatchSource ile izler (polling yok).
4. Esc ile kesme ve izin reddi hook tetiklemez (resmi doküman: Stop kullanıcı kesmesinde çalışmaz);
   bunlar oturumun transcript'indeki `[Request interrupted by user…]` kaydından anında yakalanır.

| Olay | Durum |
|---|---|
| UserPromptSubmit, PreToolUse, PostToolUse(Failure) | 🟢 Çalışıyor |
| PermissionRequest, Notification `permission_prompt` | 🔴 İzin bekliyor |
| PreToolUse `AskUserQuestion`, Notification `elicitation_dialog` | 🔴 Soru soruyor |
| Stop, StopFailure, Notification `idle_prompt`, transcript kesme kaydı | 🟡 Sıra sende |
| SessionEnd / süreç çıktı | ⚪️ Durdu |

## Davranış

- Oturum adları proje adından gelir (`claude --name "<proje>"`, sonra `"<proje> · 2"`); remote-control'de de bu ad görünür. Yeniden adlandırma çalışan oturuma `/rename` ile iletilir.
- Uygulama kapanırken açık olan oturumlar, açılışta `claude --resume <id>` ile kendiliğinden geri gelir; büyük transcript'lerde ardından `/compact` gönderilir (Ayarlar'dan kapatılabilir / eşik değiştirilebilir). Durmuş bir oturumu seçmek de onu devam ettirir.
- Bildirim: izin / soru / bitti durumlarında; o terminal zaten öndeyse gösterilmez. Tıklayınca o terminal açılır. Dock rozeti = bekleyen oturum sayısı; Dock ikonu zıplar.
- Yan yana bölmeler (en fazla 4): sidebar'dan bir oturumu terminal alanının sol/sağ yarısına sürükle
  ya da sağ tık › "Yanına aç". Bölme başlığındaki ✕ yalnızca bölmeyi kapatır; süreç çalışmaya devam eder.
- Dosyalar paneli (⌘⇧E): odaktaki oturumun projesi; aç, VS Code'da aç, Finder'da göster, Claude'a
  `@dosya` olarak ekle, yolu kopyala, yeni dosya/klasör, yeniden adlandır, çöpe taşı. Çift tık = VS Code
  (kuruluysa) ya da varsayılan uygulama. Araç çubuğundaki `</>` projeyi VS Code'da açar.
- Düz terminal (⌥⌘T): proje klasöründe login shell. Sağ tık › "Başlangıç komutu…" ile her açılışta
  yazılıp çalıştırılan komut (ör. `yarn start`); "Uygulama açılınca otomatik başlat" ile kapalı olsa bile
  uygulama açılışında başlar. Projenin menüsünde "Yeni terminal (komutla)…".
- Ayarlar › "Bilgisayar açılınca ClaudeDeck'i başlat" (giriş öğesi). Uygulamanın /Applications'da olması
  gerekir: `./build.sh install`.
- ⌘V: panoda yalnızca görüntü varsa Claude'a resim olarak eklenir.
- Veriler: `~/Library/Application Support/ClaudeDeck/deck.json`.

## Geliştirme notu

`CLAUDEDECK_SNAPSHOT_DIR=<dir> open build/ClaudeDeck.app` pencereleri periyodik olarak PNG'ye yazar ve
`<dir>/<oturum-uuid>.in` dosyalarını o terminale yazar (`<CR>`, `<ESC>` desteklenir) — ekran kaydı izni
olmadan uçtan uca test için.
