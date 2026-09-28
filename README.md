# ClaudeDeck

Birden fazla projede aynı anda çalışan Claude Code (CLI) oturumlarını tek pencereden yöneten macOS uygulaması.
Claude'u sarmalamaz ya da taklit etmez: her oturum gömülü bir terminalde (SwiftTerm, gerçek pty) senin kurulu
`claude` komutunu login shell üzerinden çalıştırır. Ayarların, `CLAUDE.md`'lerin, remote-control, MCP ve diğer
hook'ların aynen geçerlidir.

## Derleme

```sh
./build.sh          # release → build/ClaudeDeck.app (widget dahil, takımla otomatik imzalı)
./build.sh debug    # debug derleme
./build.sh run      # derle ve (yeniden) başlat
swift build         # yalnızca SwiftPM (widget'sız) hızlı derleme
swift test          # Core birim testleri
xcodegen generate   # ClaudeDeck.xcodeproj'u project.yml'den üret, sonra Xcode'da aç
```

`build.sh` artık `xcodegen generate` + `xcodebuild` (şema `ClaudeDeck`, `build/xcode` altında) ile derler
ve çıkan `ClaudeDeck.app`'i `build/ClaudeDeck.app`'e kopyalar: SwiftPM uygulama uzantısı (widget)
derleyemez. İmzalamayı xcodebuild yapar (otomatik imzalama, `DEVELOPMENT_TEAM` = V6G4B5T63L).
`xcodegen` kurulu değilse eski SwiftPM paketleme yoluna düşer (widget olmadan).

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

## Masaüstü widget'ı

Küçük ve orta boy WidgetKit widget'ı (masaüstü / Bildirim Merkezi): kırmızı bekleyen, yeşil çalışan,
sarı sıra sende sayıları; orta boyda dikkat bekleyen ilk 4 oturum (proje, durum, kısa ayrıntı).
Tıklamak uygulamayı o oturumda açar (`claudedeck://session/<uuid>`). Eklemek için: uygulamayı en az bir
kez çalıştır, masaüstünde sağ tık › "Widget'ları Düzenle…" › ClaudeDeck.

Uygulama durum sayıları değiştikçe (~1 sn gecikmeyle) App Group kapsayıcısına
(`~/Library/Group Containers/V6G4B5T63L.dev.medeni.ClaudeDeck/widget-snapshot.json`) küçük bir
özet yazar. Uygulama sandbox'sızdır (pty/shell için); widget uzantısı sandbox'lıdır. SwiftPM
derlemesinde App Group yetkisi olmadığından bu adım sessizce atlanır.

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
- Ayrı worktree: projenin menüsünde "Yeni Claude oturumu (ayrı worktree)…" (yalnızca git deposunda)
  `claude --name … --worktree <ad>` ile kendi git worktree'sinde (`<repo>/.claude/worktrees/<ad>`, dal
  `worktree-<ad>`) çalışan bir oturum açar; aynı projedeki paralel oturumlar aynı dosyaları düzenlemez.
  Ad varsayılan olarak `<proje>-2`, `<proje>-3`…; yalnızca `A-Z a-z 0-9 . _ -`. Gerçek klasör hook'ların
  bildirdiği `cwd`'den öğrenilir; devam ettirme (`--resume`) o klasörde çalışır, `--worktree` tekrar verilmez.
  Sidebar'da dal simgesi + worktree adı görünür; Dosyalar paneli worktree klasörünü gösterir.
- ⌘V: panoda yalnızca görüntü varsa Claude'a resim olarak eklenir.
- Veriler: `~/Library/Application Support/ClaudeDeck/deck.json`.

## iCloud eşitleme (isteğe bağlı)

Ayarlar › iCloud › "Projeleri ve grupları iCloud Drive ile eşitle" (varsayılan kapalı). Entitlement
gerekmez: düz bir dosya kullanılır — `~/Library/Mobile Documents/com~apple~CloudDocs/ClaudeDeck/projects.json`.
iCloud Drive kapalıysa (`com~apple~CloudDocs` klasörü yoksa) seçenek devre dışıdır.

- **Eşitlenen:** gruplar (kimlik, ad, renk) ve projeler (yol, ad, grup, sabitleme). Ev klasörü altındaki
  yollar `~/…` olarak yazılır, farklı kullanıcı adlı Mac'lerde de eşleşir.
- **Eşitlenmeyen:** oturumlar, bölmeler, seçim, ayarlar, grupların/projelerin açık-kapalı durumu,
  terminal / Claude oturum kimlikleri.
- **Birleştirme:** projeler yola, gruplar kimliğe göre birleştirilir; eksik olanlar eklenir, iki tarafta da
  olan öğede son değiştiren kazanır (öğe başına `modifiedAt`). Açılışta, dosya değişince (klasör izlenir)
  ve yerel proje/grup değişikliğinden sonra çalışır; dosya geçici dosyaya yazılıp yerine taşınır.
- **Silme yayılmaz:** bir Mac'te silinen proje/grup diğerlerinde kalır ve dosyada durur (dosya yalnızca
  büyür). Silen Mac onu geri getirmez; ancak başka bir Mac o öğeyi silmeden *sonra* değiştirirse geri
  eklenir. Tamamen sıfırlamak için `projects.json`'u sil. Eşitleme hiçbir zaman yerel proje ya da oturum silmez.
- Bu Mac'te bulunmayan yollar da listeye eklenir; orada açılan terminal ev klasöründe başlar.
- iCloud dosyayı henüz indirmediyse (`.projects.json.icloud`) üzerine yazılmaz; indirme beklenir.

## Geliştirme notu

`CLAUDEDECK_SNAPSHOT_DIR=<dir> open build/ClaudeDeck.app` pencereleri periyodik olarak PNG'ye yazar ve
`<dir>/<oturum-uuid>.in` dosyalarını o terminale yazar (`<CR>`, `<ESC>` desteklenir) — ekran kaydı izni
olmadan uçtan uca test için.
