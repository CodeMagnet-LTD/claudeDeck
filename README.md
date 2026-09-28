# ClaudeDeck

Birden fazla projede aynı anda çalışan Claude Code (CLI) oturumlarını tek pencereden yöneten macOS
uygulaması (macOS 15+, SwiftUI, Swift 6). Claude'u sarmalamaz ya da taklit etmez, ekran okumaz: her oturum
gömülü bir terminalde (SwiftTerm, gerçek pty) senin kurulu `claude` komutunu login shell üzerinden
çalıştırır. Ayarların, `CLAUDE.md`'lerin, remote-control, MCP, skill'ler ve diğer hook'ların aynen geçerlidir.

## Derleme ve kurulum

```sh
./build.sh           # release → build/ClaudeDeck.app (widget ve ikon dahil, takım sertifikasıyla imzalı)
./build.sh debug     # debug derleme
./build.sh run       # derle ve (yeniden) başlat
./build.sh install   # derle, /Applications/ClaudeDeck.app'e kopyala ve oradan aç
swift build          # yalnızca SwiftPM (widget'sız) hızlı derleme
swift test           # Core birim testleri
xcodegen generate    # ClaudeDeck.xcodeproj'u project.yml'den üret, sonra Xcode'da aç
```

- `build.sh`, `xcodegen generate` + `xcodebuild` ile derler (SwiftPM uygulama uzantısı/widget derleyemez)
  ve sonucu `build/ClaudeDeck.app`'e kopyalar. `xcodegen` yoksa eski SwiftPM paketleme yoluna düşer
  (widget'sız, takım sertifikasıyla imzalar).
- İmza: takım `V6G4B5T63L` (Apple Development). İmza sabit olduğu için macOS'un verdiği izinler
  (klasör erişimi, bildirim) her derlemede tekrar sorulmaz.
- Xcode projesi üretilir; ayarları (takım, bundle id, hedefler) `project.yml`'de değiştir. Xcode ilk
  açılışta SwiftTerm'in build eklentisi için "Trust & Enable" sorar.
- Uygulama ikonu kodla çizilir: `swift tools/make-icon.swift Support` → `Support/AppIcon.icns` ve
  `Support/Assets.xcassets/AppIcon.appiconset`.

## Durum nasıl bilinir (ekran okuma yok)

1. İlk açılışta `~/.claude/settings.json`'a ClaudeDeck hook'u **eklenir**: önce
   `settings.json.claudedeck-backup-<zaman>` yedeği alınır, diğer hook'lara (GSD, graphify…) dokunulmaz,
   tekrar eklenmez, symlink'li dosyalarda link korunur. Ayarlar › Claude Code hook'ları › "Kaldır" ile geri alınır.
2. Hook (`~/.claude/deck/bin/deck-hook.sh`, sh + `/usr/bin/jq`, ~40 ms) yalnızca `CLAUDEDECK_TERMINAL_ID`
   taşıyan (ClaudeDeck'in açtığı) terminallerde çalışır ve `~/.claude/deck/sessions/<session_id>.json`
   dosyasını atomik yazar. Başka terminallerdeki claude'lar için hiçbir şey yapmaz.
3. Uygulama bu klasörü DispatchSource ile izler (polling yok); ölü/eski dosyaları temizler.
4. Esc ile kesme ve izin reddi hook tetiklemez (resmi doküman: Stop kullanıcı kesmesinde çalışmaz); bunlar
   oturumun transcript'indeki `[Request interrupted by user…]` kaydından anında yakalanır.
5. Paralel araçlar: izin istemi açıkken başka bir aracın bitmesi durumu "çalışıyor"a çekmez.

| Olay | Durum |
|---|---|
| UserPromptSubmit, PreToolUse, PostToolUse(Failure), izne cevap verildi | 🟢 Çalışıyor |
| PermissionRequest, Notification `permission_prompt` | 🔴 İzin bekliyor |
| AskUserQuestion (PermissionRequest/PreToolUse), Notification `elicitation_dialog` | 🔴 Soru soruyor |
| Stop, StopFailure, Notification `idle_prompt`, transcript kesme/ret kaydı | 🟡 Sıra sende |
| SessionEnd / süreç çıktı | ⚪️ Durdu |

## Özellikler

### Oturumlar
- **Yeni Claude oturumu:** projenin başlığındaki **+**, sağ tık menüsü ya da ⌘T. Aynı projede istediğin
  kadar oturum. Adlar proje adından gelir (`claude --name "<proje>"`, sonra `"<proje> · 2"`); remote-control'de
  de bu ad görünür. Yeniden adlandırma çalışan oturuma `/rename` ile iletilir.
- **Eski konuşmayı devam ettir:** projenin menüsü › "Eski oturumu devam ettir…" (`~/.claude/projects`
  transcript'lerinden liste).
- **Kalıcılık:** uygulama kapanırken açık olan oturumlar açılışta `claude --resume <id>` ile kendiliğinden geri
  gelir. Durmuş bir oturumu seçmek de onu devam ettirir; `/exit` ile kapattığın ya da "Oturumu bitir" dediğin
  oturum ise "Devam et" deyince döner.
- **Otomatik /compact:** geri gelen oturumun context'i eşiği aşıyorsa `/compact` gönderilir. Eşik gerçek
  context token'ıdır (transcript'teki son asistan mesajının `input + cache_read + cache_creation` toplamı;
  dosya boyutu değil). Ayarlar'dan açılır/kapanır, 50 bin – 1 milyon token (varsayılan 200 bin).
- **Ayrı worktree:** projenin menüsü › "Yeni Claude oturumu (ayrı worktree)…" (yalnızca git deposunda).
  `claude --worktree <ad>` ile kendi git worktree'sinde çalışır; aynı projedeki paralel oturumlar aynı
  dosyaları düzenlemez. Gerçek klasör hook'ların bildirdiği `cwd`'den öğrenilir; devam ettirme o klasörde
  çalışır. Sidebar'da dal simgesi + worktree adı görünür.
- **Sağ tık menüsü:** Yanına aç / Bölmeyi kapat, İzin ver / Reddet (izin bekliyorsa), Oturumu bitir,
  Devam et, Yeni başlat, Yeniden adlandır, Bitir ve listeden kaldır (onay sorar; Claude geçmişi silinmez).

### Düz terminal
- Projenin başlığındaki terminal ikonu, sağ tık › "Yeni terminal" ya da ⌥⌘T: proje klasöründe login shell.
  Listede mavi "Terminal" etiketi ve o anki terminal başlığıyla görünür; durum/bildirim sayılarına girmez.
- **Başlangıç komutu:** sağ tık › "Başlangıç komutu…" (ör. `yarn start`) — terminal her açıldığında yazılıp
  çalıştırılır (geçmişte görünür, Ctrl+C terminali kapatmaz). Projenin menüsünde "Yeni terminal (komutla)…".
- **Uygulama açılınca otomatik başlat:** komutlu terminallerde varsayılan açık; uygulama kapanırken kapalı
  olsa bile açılışta başlar.

### İzin ve bildirimler
- **Bildirim:** izin / soru / bitti durumlarında, mesajla (hangi araç, hangi komut/dosya). Terminal zaten
  ekrandaysa (görünen bir bölmede) gösterilmez. Esc ya da ret gibi senin yaptığın şeyler için bildirim yok.
  Tıklayınca uygulama öne gelir ve o oturum seçilir.
- **İzin ver / Reddet:** bildirimde, "Bekleyenler" satırında, bölme başlığında ve sağ tık menüsünde. Hook'lara
  ve terminalde cevaplamaya dokunulmaz: uygulama senin basacağın tuşu terminale yazar (onay = `1`, ret = Esc).
  Yalnızca oturum hâlâ aynı izin isteminde bekliyorsa gönderilir; sorular ve plan onayı (ExitPlanMode) hariç.
- **Dock:** rozet = bekleyen oturum sayısı; izin/soruda sen dönene kadar, bitince bir kez zıplar.
- **Menü çubuğu:** bekleyen / çalışan / sıra sende sayaçları; tıklayınca oturum listesi.
- **Widget:** masaüstünde sağ tık › "Widget'ları Düzenle…" › ClaudeDeck (uygulama en az bir kez açılmış
  olmalı). Küçük: sayaçlar; orta: dikkat bekleyen ilk 4 oturum. Tıklayınca o oturum açılır
  (`claudedeck://session/<uuid>`). Veri App Group kapsayıcısından okunur.

### Sidebar
- **Bekleyenler:** izin isteyen, soru soran ya da bitip henüz bakmadığın oturumlar en üstte, proje adı ve
  mesajla; izin bekleyenler kırmızı zeminli.
- **Durum etiketleri:** 🟢 Çalışıyor (akan noktalar), 🔴 İzin bekliyor / Soru soruyor (nabız), 🟡 Sıra sende,
  ⚪️ Durdu, 🔵 Terminal; durum değişince satır kısa bir an parlar.
- **Projeler:** "Sabitlenenler" ve "Projeler". Gruplar "Projeler" içinde klasör gibi durur (yalnızca başlığı
  grubun rengiyle tonlu). Bekleyen ya da aktif oturumu olan projeler/gruplar üste çıkar. Aktif oturumu
  olmayan projeler kapalı başlar; bekleyen oturumu olan proje/grup kendiliğinden açılır. Projeye tıklamak
  son oturumunu açar ve Dosyalar panelini o projeye çevirir.
- **Gruplar:** "Projeler" başlığındaki **+** › "Yeni grup…" (proje seçmeden). Grubun **+**'sı ya da sağ tık
  menüsü › "Projeleri seç…" ile çoklu atama, "Bu gruba proje ekle…" ile klasör seçerek ekleme. Renk ve ad
  sağ tıkla değişir.
- Onay/isim soruları pencerenin içinde (sheet) açılır; silme işlemleri "Emin misin?" diye sorar.

### Yan yana bölmeler
- Sidebar'dan bir oturumu terminal alanının sol/sağ yarısına sürükle ya da sağ tık › "Yanına aç"; projenin
  menüsünde "Oturumlarını yan yana aç". En fazla 4 bölme, aradaki çizgiyi sürükleyerek genişlik ayarlanır.
- Her bölmenin başlığında ad, durum, İzin ver/Reddet ve ✕ (yalnızca bölmeyi kapatır; süreç çalışır).
  Tıkladığın bölme odak olur. Düzen kalıcıdır.

### Dosyalar paneli (⌘⇧E)
- Sidebar'da son tıkladığın projenin (ya da seçili oturumun; worktree oturumunda worktree klasörünün) canlı
  güncellenen ağacı. `.git`, `node_modules`, `.build` vb. gizli; göz ikonuyla gizli dosyalar.
- **Git:** değişen dosyalar turuncu **M**, yeniler yeşil **A/?**, silinen/çakışan kırmızı; değişiklik içeren
  klasörler noktalı. Dosya seçince altta **geçmiş** (commit'ler); commit'e tıklayınca o dosyanın diff'i,
  en üstte kaydedilmemiş değişiklikler.
- Tek tık seçer (⌘-tık çoklu), çift tık VS Code'da (kurulu değilse varsayılan uygulamada) açar.
- Sağ tık: VS Code'da aç, Aç, Finder'da göster, Claude'a ekle (`@yol`), yolu/göreli yolu kopyala, yeni
  dosya/klasör, yeniden adlandır, çöpe taşı.
- Dosyayı bir terminal bölmesine sürükle: Claude'da `@göreli/yol` (resimler tam yol, Claude resim olarak
  ekler), düz terminalde kaçışlı yol yazılır.
- Araç çubuğundaki `</>` ve projenin menüsü › "VS Code'da aç" projeyi VS Code'da açar (VS Code / Insiders /
  VSCodium kurulu değilse düğmeler görünmez).

### Terminal
- Klavye, renk, kısayollar, yeniden boyutlandırma, kopyala/yapıştır; bölme ya da oturum değiştirmek
  süreçleri öldürmez.
- **⌘V ile resim:** panoda yalnızca görüntü varsa Claude oturumunda resim olarak eklenir (Terminal.app gibi);
  Finder'dan kopyalanmış dosyalar yol olarak yapıştırılır.

### Ayarlar (⚙︎ ya da ⌘,)
- Bilgisayar açılınca ClaudeDeck'i başlat (giriş öğesi; uygulama `/Applications`'da olmalı: `./build.sh install`).
- Açılışta oturumları otomatik devam ettir, /compact ve token eşiği.
- Bildirim ve Dock zıplatma.
- iCloud eşitleme (aşağıda).
- Claude Code hook'ları: durum, yeniden kur, kaldır.

## iCloud eşitleme (isteğe bağlı)

Ayarlar › iCloud (varsayılan kapalı). Entitlement gerekmez; düz dosya:
`~/Library/Mobile Documents/com~apple~CloudDocs/ClaudeDeck/projects.json`.

- **Eşitlenen:** gruplar (kimlik, ad, renk) ve projeler (yol, ad, grup, sabitleme). Ev klasörü altındaki
  yollar `~/…` olarak yazılır.
- **Eşitlenmeyen:** oturumlar, bölmeler, seçim, ayarlar, açık/kapalı durumu, terminal / Claude kimlikleri.
- **Birleştirme:** projeler yola, gruplar kimliğe göre; eksikler eklenir, çakışmada son değiştiren kazanır.
- **Silme yayılmaz:** bir Mac'te silinen öğe diğerlerinde kalır. Eşitleme hiçbir zaman yerel proje ya da
  oturum silmez.

## Dağıtım / Notarization

```sh
./notarize.sh   # derle → Developer ID ile imzala → notarize et → staple → spctl ile doğrula
```

Başka Mac'lerde Gatekeeper uyarısı olmadan açılması için gerekir. Ön koşullar (bir kez):

1. Anahtar zincirinde **Developer ID Application** sertifikası (Xcode › Settings › Accounts › Manage
   Certificates › "+"; Apple Development sertifikası yetmez). Birden fazlaysa `DEVELOPER_ID="…"` ile seç.
2. notarytool profili:
   `xcrun notarytool store-credentials claudedeck --apple-id <e-posta> --team-id V6G4B5T63L --password <app-specific-password>`
   (farklı ad için `NOTARY_PROFILE=<ad>`).

Sertifika yoksa betik hiçbir şey derlemeden/göndermeden açıklamayla durur.

## Veriler

| Ne | Nerede |
|---|---|
| Projeler, gruplar, oturumlar, bölmeler, ayarlar | `~/Library/Application Support/ClaudeDeck/deck.json` |
| Anlık oturum durumları (hook'un yazdığı) | `~/.claude/deck/sessions/<session_id>.json` |
| Hook betiği | `~/.claude/deck/bin/deck-hook.sh` |
| settings.json yedekleri | `~/.claude/settings.json.claudedeck-backup-<tarih>` |
| Widget özeti | `~/Library/Group Containers/V6G4B5T63L.dev.medeni.ClaudeDeck/widget-snapshot.json` |
| iCloud eşitleme (açıksa) | `~/Library/Mobile Documents/com~apple~CloudDocs/ClaudeDeck/projects.json` |
| Konuşma geçmişi | Claude'un kendi yeri: `~/.claude/projects/<proje>/<id>.jsonl` (ClaudeDeck yalnızca okur) |

## Kod yapısı

- `Sources/ClaudeDeckCore/` — UI'sız, test edilen katman: hook betiği ve settings.json birleştirme
  (`HookScript`, `HookInstaller`), durum modeli (`SessionState`, `StatusDirectory`), transcript okuma
  (`Transcript`), kalıcı veri (`DeckData`), dosya listeleme ve git (`FileListing`, `Git`), iCloud
  (`DeckSync`), widget özeti (`WidgetSnapshot`).
- `Sources/ClaudeDeck/` — SwiftUI uygulaması: `AppModel`, `TerminalRegistry` (SwiftTerm, süreçler),
  `SidebarView`, `ContentView` (bölmeler), `FileBrowser`, `AttentionCenter` (bildirim/Dock),
  `PermissionActions`, `MenuBarViews`, `SettingsView`, `WidgetBridge`, `DeckSyncController`.
- `Widget/` — WidgetKit uzantısı. `tools/make-icon.swift` — ikon üretici.
- `Tests/ClaudeDeckCoreTests/` — birim testleri (gerçek hook betiği ve gerçek git deposu dahil).

## Geliştirme notu

`CLAUDEDECK_SNAPSHOT_DIR=<dir> open build/ClaudeDeck.app` ekran kaydı izni olmadan uçtan uca test içindir:
pencereleri periyodik olarak PNG'ye, liste satır sayılarını `rows.txt`'ye yazar ve `<dir>` içindeki komut
dosyalarını işler: `<oturum>.in` (terminale yaz; `<CR>`, `<ESC>`), `<oturum>.select`, `<oturum>.beside`,
`<oturum>.paste`, `<oturum>.approve` / `.deny`, `<proje>.shell`. Not: yeni cam (Liquid Glass) kenar çubuğu
snapshot'ta boş görünür; satır sayısı `rows.txt`'dedir.
