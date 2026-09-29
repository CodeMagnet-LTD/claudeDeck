# ClaudeDeck

[English](README.md) · **Türkçe** · [Web sitesi](https://codemagnet-ltd.github.io/claudeDeck/tr/)

**Birden fazla projede aynı anda çalışan Claude Code oturumlarını tek pencereden yöneten macOS uygulaması.**

Hangi oturum çalışıyor, hangisi izin bekliyor, hangisi soru soruyor, hangisi bitti ve sıra sende:
hepsini tek bakışta görürsün. İzni bildirimden verirsin, oturumları yan yana açarsın, uygulamayı
kapatıp açınca kaldığın yerden devam edersin.

> Not: Uygulama İngilizce ve Türkçe destekler ve sistem dilini izler. Yalnızca ClaudeDeck'in dilini
> değiştirmek için: Sistem Ayarları › Genel › Dil ve Bölge › Uygulamalar.

ClaudeDeck Claude'u sarmalamaz ya da taklit etmez, ekran da okumaz. Her oturum gömülü bir terminalde
(SwiftTerm, gerçek pty) senin kurulu `claude` komutunu login shell üzerinden çalıştırır.
Ayarların, `CLAUDE.md` dosyaların, remote-control, MCP, skill'ler ve diğer hook'ların aynen geçerlidir.

## Ekran görüntüleri

![Kenar çubuğu, yan yana iki oturum ve Dosyalar paneliyle ClaudeDeck](docs/screenshots/main.png)

**Bütün oturumlar için tek pencere.** Görüntüde neler var:
- **Kenar çubuğu (solda):** tüm projeler ve oturumlar, gruplarıyla. Seni bekleyen her şey en üstteki
  **Needs Attention** (Bekleyenler) bölümüne çıkar. `PR #42` ve `#118`, oturumlara bağlanmış GitHub pull
  request'i ve issue'sudur; renkleri durumlarını gösterir.
- **İki bölme (ortada):**
  - Solda, bir Bash komutu için izin bekleyen oturum. Bölme başlığındaki **Allow / Deny** ile ya da her
    zamanki gibi terminalden cevap verebilirsin.
  - Yanında, aynı projede çalışmaya devam eden ikinci oturum.
- **Sağ panel:** **Files** (seçili projenin canlı dosya ağacı) ile **Changes** (kaynak kontrolü) arasında geçiş yapar.

<table>
  <tr>
    <td width="40%" valign="top">
      <img src="docs/screenshots/needs-attention.png" alt="Bekleyenler: İzin Ver ve Reddet düğmeli izin istemi, bir soru ve biten bir oturum">
    </td>
    <td valign="top">
      <b>Bekleyenler.</b> Seni bekleyen oturumlar, en acil olan önce:
      <ul>
        <li>🔴 <b>İzin bekliyor</b>: tam komutla birlikte, tek tıkla İzin Ver / Reddet.</li>
        <li>🔴 <b>Soru soruyor</b>: sorunun kendisiyle.</li>
        <li>🟡 <b>Sıra sende</b>: Claude işini bitirdi; sen bakana kadar son mesajıyla burada kalır.</li>
      </ul>
      Aynı istemler İzin Ver / Reddet düğmeli macOS bildirimleri olarak, Dock rozetinde ve menü çubuğunda da görünür.
    </td>
  </tr>
  <tr>
    <td width="40%" valign="top">
      <img src="docs/screenshots/sidebar.png" alt="Sabitlenen projeler, renkli gruplar, aktif ve pasif bölümleriyle kenar çubuğu">
    </td>
    <td valign="top">
      <b>Projeler, gruplar ve tüm durumlar tek bakışta.</b>
      <ul>
        <li><b>Pinned</b> (sabitlenen) projeler en üstte kalır.</li>
        <li><b>Active</b>, çalışan her şeyi başlattığın sırayla, renkli grupları (<i>Open Source</i>, <i>Client Work</i>) ve canlı sayaçlarıyla listeler.</li>
        <li><b>Inactive</b>, çalışan oturumu olmayan projeleri katlar.</li>
        <li>Her satırda durum, Claude'un o an ne yaptığı ve durumun ne zaman değiştiği görünür.</li>
        <li>Dal ikonu worktree oturumunu (<code>fix-tables</code>) gösterir.</li>
        <li><b>Terminal</b> ve <b>⚡ Auto</b> etiketli satır, başlangıç komutu (<code>./dev.sh</code>) uygulama açılınca çalışan düz bir shell'dir.</li>
      </ul>
    </td>
  </tr>
  <tr>
    <td width="40%" valign="top">
      <img src="docs/screenshots/files.png" alt="Git işaretli dosyalar paneli">
    </td>
    <td valign="top">
      <b>Dosyalar paneli (⌘⇧E).</b> Projenin canlı güncellenen dosya ağacı, git işaretleriyle:
      <ul>
        <li>Turuncu <b>M</b>: değişmiş. Yeşil <b>A/?</b>: yeni. Değişiklik içeren klasörler noktalı. <code>.gitignore</code>'un dışladığı dosyalar gizli kalır.</li>
        <li>Bir dosyayı seçince commit geçmişi ve diff'leri görünür; kaydedilmemiş değişiklikler de dahil.</li>
        <li>Dosyayı bir Claude bölmesine sürükle, <code>@yol</code> olarak eklensin. Dosyaları bir klasörün üstüne sürükleyerek taşırsın, Finder'dan da bırakabilirsin.</li>
        <li>Üstteki <b>Files | Changes</b> paneli kaynak kontrolüne çevirir.</li>
      </ul>
    </td>
  </tr>
  <tr>
    <td width="40%" valign="top">
      <img src="docs/screenshots/widget.png" alt="Bekleyen, çalışan ve sıra sende oturum sayılarını gösteren masaüstü widget'ı">
    </td>
    <td valign="top">
      <b>Masaüstü widget'ı.</b> Bekleyen, çalışan ve biten oturum sayıları, ayrıca seni bekleyen ilk oturumlar ve ne istedikleri. Bir oturuma tıklayınca doğrudan ona gidersin. Eklemek için: masaüstüne sağ tık › Widget'ları Düzenle… › ClaudeDeck.
    </td>
  </tr>
</table>

<table>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/screenshots/tabs-editor.png" alt="Araç çubuğunda düzenleyici sekmeleri, açık bir TypeScript dosyası ve Dosyalar paneli">
    </td>
    <td valign="top">
      <b>Sekmeler ve yerleşik düzenleyici.</b> Dosyalar araç çubuğunda sekme olarak açılır; ilk sekme her zaman <b>Oturumlar</b> (Sessions) sekmesidir:
      <ul>
        <li>Sözdizimi renklendirmesi, satır numaraları, bul ve değiştir ve ⌘S ile hafif bir kod düzenleyicisi.</li>
        <li><b>Claude'a Ekle</b> (yol çubuğundaki <code>@</code>) seçili oturuma <code>@yol</code> yazar; satır seçiliyse <code>@yol#L10-20</code>.</li>
        <li>Hızlı Aç'tan ya da Değişiklikler'den açılan dosyalar italik bir önizleme sekmesinde açılır, sonraki onun yerine geçer. Sekmeler arasında ⌘1–⌘9 ve ⌃Tab ile geçilir.</li>
      </ul>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/screenshots/changes.png" alt="Hazırlanan ve hazırlanmayan dosyalarıyla Changes paneli ve Stage Hunk düğmeli tam genişlikte diff sekmesi">
    </td>
    <td valign="top">
      <b>Değişiklikler (Changes, ⌘⇧G).</b> Seçili projenin kaynak kontrolü:
      <ul>
        <li>Dosya ya da hunk bazında stage, unstage ve discard. Her diff tam genişlikte bir sekmede açılır.</li>
        <li>Commit, amend, push ve pull. ✨ düğmesi commit mesajını senin <code>claude</code>'una yazdırır.</li>
        <li>Diff'te bir satıra sağ tık › <b>Claude'a bu satırı sor…</b>, sorunla birlikte <code>@yol#L12</code>'yi oturuma gönderir.</li>
      </ul>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/screenshots/automations.png" alt="Hafta içi zamanlaması ve çalışma geçmişiyle Otomasyonlar sekmesi">
    </td>
    <td valign="top">
      <b>Otomasyonlar.</b> Belirli zamanlarda Claude oturumu başlatan kayıtlı prompt'lar:
      <ul>
        <li>Saatte bir, her gün, hafta içi her gün ya da haftada bir; istersen yalnızca <b>Şimdi Çalıştır</b> (Run Now) ile.</li>
        <li>Proje klasöründe ya da her seferinde yeni bir git worktree'sinde çalışır. Hazır şablonlardan başlayabilirsin.</li>
        <li>Her çalışmanın geçmişi, oturumuna bağlantısıyla. İzin istemleri her oturumda olduğu gibi Bekleyenler'e düşer.</li>
      </ul>
      Otomasyonlar yalnızca ClaudeDeck açıkken çalışır.
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/screenshots/github.png" alt="Bağlı pull request'in durumu, başarısız kontrolü, istenen değişiklikler ve son etkinlikleriyle açılır penceresi">
    </td>
    <td valign="top">
      <b>GitHub issue'ları ve pull request'leri.</b> Bir oturuma bağla, rozeti durumunu göstersin:
      <ul>
        <li>Açılır pencerede açıklama, etiketler, CI kontrolleri, review'lar ve son yorumlar var.</li>
        <li><b>Claude'a Gönder</b> bağlantıyı oturuma yazar. <b>Yorum Ekle…</b> GitHub'a yorum gönderir.</li>
        <li>Review gelince, CI kırılınca ya da pull request merge edilince bildirim alırsın.</li>
      </ul>
      Kendi <code>gh</code> CLI'ını ve onun oturumunu kullanır; ClaudeDeck token saklamaz.
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/screenshots/quick-open.png" alt="cart ile eşleşen dosyaları listeleyen Hızlı Aç penceresi">
    </td>
    <td valign="top">
      <b>Hızlı Aç (⌘P) ve Dosyalarda Bul (⌘⇧F).</b> Adının bir kısmını yazarak projedeki herhangi bir dosyaya atla. ↩ açar, ⌥↩ Claude'a <code>@yol</code> olarak ekler. Dosyalarda Bul içerikte arar; git'e eklenmemiş dosyalar da dahil.
    </td>
  </tr>
</table>

<table>
  <tr>
    <td><img src="docs/screenshots/settings-general.png" alt="Genel ayarlar: tema, çıkış onayı, menü çubuğu modu"></td>
    <td><img src="docs/screenshots/settings-sessions.png" alt="Oturum ayarları: otomatik /compact eşiği, devam mesajı, bildirimler"></td>
  </tr>
  <tr>
    <td valign="top"><b>Ayarlar › Genel:</b> Sistem / Açık / Koyu tema, terminaller açıkken çıkmadan önce onay ve pencere kapanınca yalnızca menü çubuğunda çalışma.</td>
    <td valign="top"><b>Ayarlar › Oturumlar ve Uyarılar:</b> otomatik <code>/compact</code> için token eşiği, otomatik devamdan sonra isteğe bağlı "devam et" mesajı ve bildirim seçenekleri.</td>
  </tr>
</table>

<sub>Görüntüler, uydurma projeler, depolar ve kişilerle çalışan yerleşik demo moduyla (<code>tools/demo.sh</code>) alındı.</sub>

## Nedir, ne değildir

| ClaudeDeck **şudur** | ClaudeDeck **şu değildir** |
|---|---|
| Kendi kurulu `claude` CLI'ını gerçek terminallerde çalıştıran bir **oturum yöneticisi** | Claude'un yerine geçen bir sohbet uygulaması ya da API istemcisi |
| Durumu Claude Code'un resmi **hook**'larından öğrenen bir pano | Ekranı okuyan, terminal çıktısını ayrıştıran ya da tuş kaydeden bir araç |
| Birçok projeyi ve paralel oturumu tek pencerede toplayan yerel bir macOS uygulaması | Bulut hizmeti, hesap sistemi ya da telemetri; hiçbir veri dışarı gönderilmez |
| Senin ayarlarını, `CLAUDE.md`'lerini, MCP'lerini ve skill'lerini olduğu gibi kullanan bir kabuk | Claude Code'un davranışını, izin kurallarını ya da modelini değiştiren bir eklenti |
| İzin istemine senin basacağın tuşu gönderen bir kısayol | İzinleri kendiliğinden onaylayan bir otomasyon |

Ücretlendirme, kullanım limitleri ve oturum açma tamamen Claude Code'a aittir; ClaudeDeck bunlara dokunmaz.

## Öne çıkanlar

- 🟢🔴🟡 **Canlı durum:** her oturum için çalışıyor / izin bekliyor / soru soruyor / sıra sende.
  Bu bilgi Claude Code hook'larından gelir, ekran okuma yoktur.
- 🔔 **Bildirim, Dock rozeti, menü çubuğu ve masaüstü widget'ı:** dikkat bekleyen oturumları kaçırmazsın.
- ✅ **Uygulamadan "İzin ver / Reddet":** bildirimden, listeden ya da bölme başlığından.
- 🗂 **Projeler ve gruplar:** sabitleme, renkli gruplar, bekleyen oturumlar en üstte.
- 🪟 **Yan yana bölmeler:** sürükle-bırakla 4 bölmeye kadar.
- ♻️ **Kalıcılık:** uygulama kapanıp açılınca oturumlar `claude --resume` ile geri gelir; context şişmişse
  otomatik `/compact` gönderilir.
- 🌿 **Worktree oturumları:** aynı projede `claude --worktree` ile birbirine karışmayan paralel oturumlar.
- 📁 **Dosyalar paneli:** canlı dosya ağacı, git işaretleri, dosya geçmişi ve diff, Hızlı Aç (⌘P) ve
  Dosyalarda Bul (⌘⇧F). Dosyayı terminale sürükleyerek `@yol` olarak eklersin.
- 📑 **Sekmeler ve yerleşik düzenleyici:** dosyalar, diff'ler ve Otomasyonlar oturumlarının yanında sekme olarak
  açılır. Sözdizimi renkli, bul-değiştirli hafif bir düzenleyici; "Claude'a Ekle" ile `@yol#L10-20`.
- 🔀 **Değişiklikler (⌘⇧G):** dosya ya da hunk bazında stage / unstage / discard, commit, push ve pull; commit
  mesajını Claude yazar.
- 🐙 **GitHub bağlantıları:** bir oturuma issue ya da pull request bağla; durumunu, review'ları ve CI'ı gör,
  değişince bildirim al. Senin `gh` CLI'ını kullanır.
- ⏰ **Otomasyonlar:** zamanlanmış prompt'lar (saatlik, günlük, hafta içi, haftalık), Run Now ve çalışma geçmişi.
- 🔄 **Oturumu Yeniden Başlat (⌥⌘R):** `claude`'dan çıkıp aynı konuşmaya geri döner; yeni MCP sunucuları ve
  ayarlar devreye girer.
- ✏️ **Pencil (pen.dev):** ClaudeDeck'in başlattığı oturumlar Pencil'ın tasarım araçlarını kullanabilir;
  `.pen` dosyaları Pencil'da açılır.
- 💻 **Düz terminaller:** proje klasöründe shell ya da `yarn start` gibi bir başlangıç komutu; uygulama
  açılınca otomatik başlar.
- ☁️ **iCloud eşitleme (isteğe bağlı):** proje listesi ve gruplar Mac'lerin arasında eşitlenir.
- 🎨 Açık/koyu tema, terminal yakınlaştırma (⌘+ / ⌘- / ⌘0), ⌘V ile Claude'a resim yapıştırma.

## Kurulum

1. [Releases](../../releases/latest) sayfasından en son `ClaudeDeck-<sürüm>.dmg` dosyasını indir.
2. DMG'yi aç ve **ClaudeDeck**'i **Applications** klasörüne sürükle.
3. Uygulamayı aç. İlk açılışta Claude Code hook'u `~/.claude/settings.json`'a eklenir
   (öncesinde yedek alınır, ayrıntılar aşağıda).

Uygulama Developer ID ile imzalı ve Apple tarafından notarize edilmiştir; Gatekeeper uyarısı çıkmaz.

### Gereksinimler

- macOS 15 (Sequoia) veya üstü
- [Claude Code](https://docs.claude.com/en/docs/claude-code) CLI kurulu ve login shell'de `claude` komutu çalışıyor olmalı
- `jq`: macOS 15 ile birlikte `/usr/bin/jq` olarak gelir
- İsteğe bağlı: git işaretleri ve dosya geçmişi için Command Line Tools (`xcode-select --install`) ya da
  Homebrew git; ikisi de yoksa bu özellikler sessizce kapanır. Dış editörde açmak için VS Code, Insiders
  ya da VSCodium (yerleşik düzenleyici için hiçbir şey gerekmez). GitHub bağlantıları için
  `gh auth login` ile oturum açılmış [GitHub CLI](https://cli.github.com) (`gh`). Pencil entegrasyonu için
  [pen.dev](https://pen.dev)'deki Pencil masaüstü uygulaması.

## Kaynaktan derleme

```sh
./build.sh           # release → build/ClaudeDeck.app (widget ve ikon dahil)
./build.sh debug     # debug derleme
./build.sh run       # derle ve (yeniden) başlat
./build.sh install   # derle, /Applications/ClaudeDeck.app'e kopyala ve oradan aç
swift build          # yalnızca SwiftPM (widget'sız) hızlı derleme
swift test           # Core birim testleri
xcodegen generate    # ClaudeDeck.xcodeproj'u project.yml'den üret, sonra Xcode'da aç
```

- `build.sh`, `xcodegen generate` + `xcodebuild` ile derler (SwiftPM uygulama uzantısı/widget derleyemez)
  ve sonucu `build/ClaudeDeck.app`'e kopyalar. `xcodegen` yoksa (`brew install xcodegen`) SwiftPM
  paketleme yoluna düşer; bu yolda widget olmaz.
- Xcode projesi üretilir, elle düzenlenmez: hedefleri `project.yml`'de, takım, bundle id ve sürümü
  `Config/Shared.xcconfig`'te değiştir. Xcode ilk açılışta SwiftTerm'in build eklentisi için "Trust & Enable" sorar.
- Uygulama ikonu kodla çizilir: `swift tools/make-icon.swift Support` → `Support/AppIcon.icns` ve
  `Support/Assets.xcassets/AppIcon.appiconset`.

### Kendi Apple hesabınla derlemek

Varsayılan ayarlar resmi sürümün takımını kullanır. Kendi Mac'inde derlemek için:

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # git'e girmez
# DEVELOPMENT_TEAM = <Team ID'n>     (ücretsiz Apple ID'nin kişisel takımı da olur)
# DECK_BUNDLE_PREFIX = com.adin      (resmi bundle id'den farklı olmalı)
./build.sh
```

Widget'ın App Group'u, bundle id'ler ve imza bu iki değerden türetilir; kodda değiştirilecek başka yer yoktur.
Sabit bir imza kullanıldığı için macOS'un verdiği izinler (klasör erişimi, bildirim) her derlemede tekrar sorulmaz.

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
- **Oturumu Yeniden Başlat (⌥⌘R):** oturumun `claude`'unu kapatıp aynı bölmede, aynı konuşmaya devam
  ederek yeniden başlatır. MCP sunucusu ekledikten, ayarları ya da `CLAUDE.md`'yi değiştirdikten sonra kullan.
  Dosya › "Tüm Claude Oturumlarını Yeniden Başlat" çalışan bütün Claude oturumlarını yeniden başlatır; çalışmakta olan
  oturumlar için önce sorar, istersen onları atlar. Düz terminalde shell'i ve başlangıç komutunu yeniden çalıştırır.
- **Sağ tık menüsü:** Yanına aç / Bölmeyi kapat, İzin ver / Reddet (izin bekliyorsa), Oturumu bitir,
  Devam et, Oturumu Yeniden Başlat, Yeni başlat, Yeniden adlandır, GitHub Issue veya PR Bağla…, Bitir ve
  listeden kaldır (onay sorar; Claude geçmişi silinmez).

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

### Sekmeler
- Oturumlar dışında bir şey açılınca araç çubuğunda pencere başlığının yerine sekmeler çıkar:
  - **Oturumlar** her zaman ilk sekmedir (⌘1): kenar çubuğundaki oturumlar ve bölmeler, eskisi gibi.
  - **Dosyalar** yerleşik düzenleyicide, Değişiklikler'deki **diff'ler** tam genişlikte, **Otomasyonlar** kendi sekmesinde açılır.
- **Önizleme sekmesi:** Hızlı Aç'tan ya da Dosyalarda Bul'dan açılan dosyalar ve Değişiklikler'de tıklanan
  diff'ler italik bir önizleme sekmesinde açılır; sonraki onun yerine geçer. Düzenlersen ya da "Açık tut"
  dersen kalıcı olur. Dosyalar panelinde çift tık kalıcı bir sekme açar.
- ⌘1–⌘9 sekme seçer, ⌃Tab / ⌃⇧Tab sekmeler arasında gezer, ⌘W açık sekmeyi kapatır. Sekmeleri sürükleyerek sıralarsın.
- Sekme menüsü: Sekmeyi kapat, Diğer sekmeleri kapat, Sağdaki sekmeleri kapat, Ayrı pencerede aç,
  Yolu Kopyala, Finder'da Göster.
- Açık sekmeler uygulama yeniden açılınca geri gelir. Ayarlar › Düzenleyici › "Dosyaları sekmeler yerine
  ayrı pencerelerde aç" ile her dosya kendi penceresinde açılır.

### Yerleşik düzenleyici
- Dosyalar panelinde bir metin dosyasına çift tıkla (ya da "Düzenleyicide Aç") ve düzenle. Hızlı Aç, Dosyalarda Bul
  ve Değişiklikler de dosyaları aynı şekilde açar.
- Swift, JavaScript/TypeScript, JSON, Python, Go, Rust, shell, YAML, Markdown, HTML/XML, CSS ve C ailesi
  için sözdizimi renkleri. Satır numaraları, otomatik girinti, satır kaydırma ve değiştirmeli standart bul
  çubuğu (⌘F).
- ⌘S kaydeder; kaydedilmemiş değişiklikle sekmeyi kapatırken ya da çıkarken önce sorar.
- Dosya diskte değişirse (örneğin Claude düzenlediyse) düzenleyici yeniden yükler. Senin de kaydedilmemiş
  değişikliğin varsa bir çubuk **Yeniden Yükle** ya da **Benimkini Koru** seçeneği sunar.
- **Claude'a Ekle** seçili oturuma `@yol` yazar; satır seçiliyse `@yol#L10-20`.
- Ayarlar › Düzenleyici: yazı boyutu, satır kaydırma ve çift tıkın yerleşik düzenleyiciyi kullanıp kullanmayacağı.
  8 MB'tan büyük ve ikili dosyalar varsayılan uygulamalarında açılır.

### Değişiklikler (⌘⇧G)
- Sağ paneldeki **Değişiklikler** tarafı (ya da ⌘⇧G) seçili projenin dalını, stage edilmiş ve edilmemiş dosyalarını
  ve çakışmaları gösterir; dosyalar değiştikçe güncellenir.
- Bir dosyaya tıklayınca diff'i tam genişlikte bir sekmede açılır. Tek dosyayı, bütün dosyaları ya da tek bir
  hunk'ı stage, unstage ya da discard edebilirsin. Discard önce sorar; yeni dosyalar Çöp'e gider.
- İsteğe bağlı **Düzelt (amend)** ile **Commit et** ya da Commit et ve gönder. Push, pull (yalnızca fast-forward) ve dalı yayınlama.
- ✨ **Commit mesajını Claude ile oluştur:** senin `claude`'un (`claude -p`) stage edilmiş diff'i okuyup mesajı yazar.
- Diff'te bir satıra sağ tık › **Claude'a bu satırı sor…**, sorunla birlikte `@yol#L<satır>`'ı seçili
  oturuma gönderir. Aynı menüde "Satırı kopyala" ve "Dosyayı aç" da var.

### Dosyalar paneli (⌘⇧E)
- Sidebar'da son tıkladığın projenin (ya da seçili oturumun; worktree oturumunda worktree klasörünün) canlı
  güncellenen ağacı. Diskteki değişiklikleri (git işlemleri dahil) anında izler (FSEvents).
  `.gitignore`'un dışladığı dosyalar ve `.git`, `node_modules`, `.build` vb. gizli; göz ikonu gizli
  dosyaları, ⋯ menüsündeki "Yok Sayılan Dosyaları Göster" dışlananları gösterir.
- **Git:** değişen dosyalar turuncu **M**, yeniler yeşil **A/?**, silinen/çakışan kırmızı; değişiklik içeren
  klasörler noktalı. Dosya seçince altta **geçmiş** (commit'ler); commit'e tıklayınca o dosyanın diff'i,
  en üstte kaydedilmemiş değişiklikler.
- Tek tık seçer (⌘-tık çoklu), çift tık VS Code'da (kurulu değilse varsayılan uygulamada) açar.
- Sağ tık: Düzenleyicide Aç, VS Code'da aç, Aç, Finder'da göster, Claude'a ekle (`@yol`), yolu/göreli yolu
  kopyala, yeni dosya/klasör, yeniden adlandır, çoğalt, kes / kopyala / yapıştır, çöpe taşı.
- Dosyaları bir klasörün üstüne sürükleyerek taşırsın; Finder'dan bırakılan dosyalar projeye kopyalanır.
- **Hızlı Aç (⌘P):** dosya adının bir kısmını yaz; ↩ açar, ⌥↩ Claude'a ekler.
- **Dosyalarda Bul (⌘⇧F):** dosya içeriklerinde `git grep` ile arar, git'e eklenmemiş dosyalar dahil. Bir
  sonuca tıklamak dosyayı açar; ⌥-tık Claude'a `@yol#L<satır>` ekler.
- Dosyayı bir terminal bölmesine sürükle: Claude'da `@göreli/yol` (resimler tam yol, Claude resim olarak
  ekler), düz terminalde kaçışlı yol yazılır.
- Araç çubuğundaki `</>` ve projenin menüsü › "VS Code'da aç" projeyi VS Code'da açar (VS Code / Insiders /
  VSCodium kurulu değilse düğmeler görünmez).

### GitHub issue'ları ve pull request'leri
- Oturum menüsü › **GitHub Issue veya PR Bağla…** bir URL ya da `sahip/depo#123` alır. **Geçerli Dalın
  PR'ını Bağla**, oturumun bulunduğu dalın pull request'ini bulur.
- Oturum adının yanındaki rozet `PR #42` ya da `#118`'i öğenin rengiyle gösterir: açık yeşil, merge edilmiş
  mor, kapalı kırmızı, taslak gri. Nokta, son baktığından beri değiştiğini gösterir.
- Rozete tıklayınca başlık, etiketler, açıklama, CI kontrolleri, review kararı, son review'lar ve yorumlar
  görünür. **Claude'a Gönder** bağlantıyı oturuma yazar, **Yorum Ekle…** yorum gönderir.
- ClaudeDeck öndeyken bağlı öğeleri dakikada bir kontrol eder; pull request merge edilince ya da kapanınca,
  CI kırılınca ya da düzelince, review ya da yeni yorum gelince bildirim gönderir.
- Her şey senin `gh` CLI'ın ve onun oturumu üzerinden gider. `gh` yoksa açılır pencere nasıl kurulacağını anlatır.

### Otomasyonlar
- Kenar çubuğunun altındaki saat düğmesinden, Dosya › "Otomasyonlar…" menüsünden ya da menü çubuğundan
  açılır; sekme olarak gelir.
- Bir otomasyon; bir prompt, bir proje ve bir ya da daha fazla zamanlamadır: her saat belirli bir dakikada,
  her gün, hafta içi her gün ya da haftada bir belirli saatte. Zamanlama yoksa yalnızca **Şimdi Çalıştır** ile çalışır.
- Her çalışma proje klasöründe ya da yeni bir git worktree'sinde bir Claude oturumu başlatır; ya sıfırdan
  başlar ya da önceki çalışmanın oturumuna devam eder.
- Şablonlar: Kritik hataları bul, Bağımlılıkları denetle, Test sağlığı, TODO'ları ayıkla, Haftalık değişiklik günlüğü.
- **Geçmiş**, her çalışmayı durumuyla (Başarılı, Başarısız, Atlandı…) listeler ve oturumunu açar.
- Otomasyonlar yalnızca ClaudeDeck açıkken çalışır. Mac uykudayken kaçırılan çalışma, "Kaçırılırsa"
  sınırından eskiyse atlanır. Hiç kaçırmamak için uygulamayı menü çubuğunda tut ve girişte açılsın.

### Pencil (pen.dev)
- Pencil masaüstü uygulaması kuruluysa ClaudeDeck'in başlattığı yeni ve devam ettirilen Claude oturumları
  onun MCP sunucusunu (`--mcp-config` ile) alır; böylece Claude tasarımlarınla çalışabilir. Genel Claude
  yapılandırman değişmez.
- Bu oturumlar bölme başlığında **Pencil** etiketiyle görünür. Zaten çalışan oturumlar için oturumu yeniden
  başlatman gerekir.
- `.pen` dosyaları Dosyalar panelinden Pencil'da açılır. Entegrasyon Ayarlar'dan kapatılabilir.

### Terminal
- Klavye, renk, kısayollar, yeniden boyutlandırma, kopyala/yapıştır; bölme ya da oturum değiştirmek
  süreçleri öldürmez.
- **Yakınlaştırma:** ⌘+ / ⌘- / ⌘0 ya da trackpad'de iki parmakla; kalıcıdır.
- **Tema:** sistem / açık / koyu (Ayarlar); terminal renkleri de temaya uyar.
- **⌘V ile resim:** panoda yalnızca görüntü varsa Claude oturumunda resim olarak eklenir (Terminal.app gibi);
  Finder'dan kopyalanmış dosyalar yol olarak yapıştırılır.

### Ayarlar (⚙︎ ya da ⌘,)
- Bilgisayar açılınca ClaudeDeck'i başlat (giriş öğesi; uygulama `/Applications`'da olmalı: `./build.sh install`).
- Açılışta oturumları otomatik devam ettir, /compact ve token eşiği.
- Bildirim ve Dock zıplatma.
- Düzenleyici: yerleşik düzenleyici açık/kapalı, sekmeler yerine ayrı pencereler, yazı boyutu, satır kaydırma.
- Pencil: Claude oturumlarını Pencil'a bağlama ve durumu.
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

## Dağıtım

```sh
./make-dmg.sh    # build/ClaudeDeck.app'ten test DMG'si (imzasız)
./notarize.sh    # derle → Developer ID ile imzala → app ve DMG'yi notarize et → staple → doğrula
./release.sh     # notarize.sh + v<sürüm> etiketi + GitHub Release (DMG ve SHA-256 ekli; yayından önce onay sorar)
```

Sürüm tek yerde tutulur: `Config/Shared.xcconfig` › `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`.
Notarization için anahtar zincirinde **Developer ID Application** sertifikası ve bir `notarytool`
profili gerekir. İkisi de yalnızca yerel anahtar zincirinde durur, repoda hiçbir imza anahtarı ya da
şifre yoktur. Eksik bir şey varsa `notarize.sh` hiçbir şey derlemeden ya da göndermeden, açıklamayla durur.

## Veriler

| Ne | Nerede |
|---|---|
| Projeler, gruplar, oturumlar, bölmeler, ayarlar, GitHub bağlantıları, otomasyonlar ve çalışma geçmişleri | `~/Library/Application Support/ClaudeDeck/deck.json` |
| Açık sekmeler, panel düzeni | Uygulamanın tercihleri (`defaults read <bundle-id>`) |
| Anlık oturum durumları (hook'un yazdığı) | `~/.claude/deck/sessions/<session_id>.json` |
| Hook betiği | `~/.claude/deck/bin/deck-hook.sh` |
| settings.json yedekleri | `~/.claude/settings.json.claudedeck-backup-<tarih>` |
| Widget özeti | `~/Library/Group Containers/<takım>.<bundle-önek>.ClaudeDeck/widget-snapshot.json` |
| iCloud eşitleme (açıksa) | `~/Library/Mobile Documents/com~apple~CloudDocs/ClaudeDeck/projects.json` |
| Konuşma geçmişi | Claude'un kendi yeri: `~/.claude/projects/<proje>/<id>.jsonl` (ClaudeDeck yalnızca okur) |

## Kod yapısı

- `Sources/ClaudeDeckCore/` — UI'sız, test edilen katman: hook betiği ve settings.json birleştirme
  (`HookScript`, `HookInstaller`), durum modeli (`SessionState`, `StatusDirectory`), transcript okuma
  (`Transcript`), kalıcı veri (`DeckData`), dosya listeleme ve git (`FileListing`, `Git`, `GitChanges`,
  `GitExplorer`, `UnifiedDiff`), sekmeler (`WorkspaceTabList`), editör metni ve sözdizimi (`TextFileIO`,
  `SyntaxTokenizer`), `gh` ile GitHub (`GitHub`, `GitHubLink`), otomasyonlar (`Automations`), yeniden
  başlatma ve Pencil (`SessionRestart`, `PencilIntegration`), iCloud (`DeckSync`), widget özeti (`WidgetSnapshot`).
- `Sources/ClaudeDeck/` — SwiftUI uygulaması: `AppModel`, `TerminalRegistry` (SwiftTerm, süreçler),
  `SidebarView`, `ContentView` (bölmeler), `WorkspaceTabs` / `TabStrip`, `EditorWindow` / `CodeTextView`,
  `FileBrowser` / `ExplorerSearch`, `ChangesView` / `DiffTab`, `AutomationsView` / `AutomationScheduler`,
  `GitHubLinkViews` / `GitHubMonitor`, `AppModel+Restart`, `PencilApp`, `AttentionCenter` (bildirim/Dock),
  `PermissionActions`, `MenuBarViews`, `SettingsView`, `WidgetBridge`, `DeckSyncController`.
- `Widget/` — WidgetKit uzantısı. `tools/make-icon.swift` — ikon üretici.
- `Tests/ClaudeDeckCoreTests/` — birim testleri (gerçek hook betiği ve gerçek git deposu dahil).

## Geliştirme notu

`CLAUDEDECK_SNAPSHOT_DIR=<dir> open build/ClaudeDeck.app` ekran kaydı izni olmadan uçtan uca test içindir:
pencereleri periyodik olarak PNG'ye, liste satır sayılarını `rows.txt`'ye yazar ve `<dir>` içindeki komut
dosyalarını işler: `<oturum>.in` (terminale yaz; `<CR>`, `<ESC>`), `<oturum>.select`, `<oturum>.beside`,
`<oturum>.paste`, `<oturum>.approve` / `.deny`, `<proje>.shell`; `<ad>.tab` (`file<TAB><yol><TAB><önizleme 0|1>`,
`diff<TAB><depo><TAB><yol><TAB><staged 0|1>`, `automations`, `sessions`, `close-all`), `<ad>.inspector`
(`files`, `changes`, `hide`), `<ad>.quickopen` (arama metni), `<oturum>.github` (bağlantıyı getir),
`<oturum>.popover` (açılır pencereyi aç), `<ad>.frame` (`x y w h`, ana pencere), `<ad>.scroll` (pencerede
`x y`, oradaki görünümü sona kaydırır) ve `app.quit`. `screencapture -l <pencere no>` ile birlikte ekran
görüntüleri hiç tık ya da tuş olmadan alınır. Not: yeni cam (Liquid Glass) kenar çubuğu snapshot'ta boş
görünür; satır sayısı `rows.txt`'dedir.

`./build.sh && tools/demo.sh` uygulamayı uydurma projeler, oturumlar, otomasyonlar ve GitHub bağlantılarıyla
demo modunda açar (veriler `/tmp/ClaudeDeckDemo`'da, her çalıştırmada yeniden oluşturulur; GitHub'a
fixture dosyalarından cevap veren sahte bir `gh` kullanılır). Demo modu `~/.claude/settings.json`'a,
`deck.json`'ına ya da iCloud'a dokunmaz.

## Lisans ve yasal not

[MIT](LICENSE) © 2026 [CODE MAGNET YAZILIM LTD. ŞTİ.](https://codemagnet.co)
Üçüncü taraf lisansları: [Support/THIRD_PARTY_LICENSES.txt](Support/THIRD_PARTY_LICENSES.txt) (SwiftTerm, MIT).

ClaudeDeck bağımsız bir açık kaynak projedir; Anthropic ile bağlantılı değildir, Anthropic tarafından
onaylanmamış ya da desteklenmemektedir. "Claude" ve "Claude Code", Anthropic PBC'nin ticari markalarıdır.
