# Durum notları

Son güncelleme: 2026-09-28. Kullanım rehberi için README.md.

## Tamamlanan özellikler

Hepsi ana dalda ve derleniyor; birim testleri geçiyor.

| Özellik | Canlı test |
|---|---|
| Hook kurulumu (settings.json birleştirme, yedek, çift eklememe) | ✅ |
| Gömülü Claude terminalleri, `--name` ile proje adlı oturumlar, remote-control | ✅ |
| Durumlar: çalışıyor / izin bekliyor / soru soruyor / sıra sende | ✅ |
| Esc ile kesme ve izin reddinin transcript'ten yakalanması | ✅ |
| Paralel araç bitişinin izin istemini gizlememesi | ✅ |
| Kapanıp açılınca `--resume` ile otomatik devam | ✅ |
| Otomatik `/compact` | ✅ (dosya boyutu sürümü canlı; token eşiği birim testli) |
| Sidebar: Bekleyenler, durum etiketleri, animasyonlar, sağ tık menüleri | ✅ |
| Yan yana bölmeler ("Yanına aç") | ✅ (eski HSplitView sürümüyle; yeni bölme düzeni denenmedi) |
| Düz terminal, başlangıç komutu, açılışta otomatik başlatma | ✅ |
| Dosyalar paneli ağacı ve git işaretleri | ✅ |
| ⌘V ile resim yapıştırma (Claude'a resim olarak) | ✅ |
| Uygulamadan "İzin ver" (terminale `1`) | ✅ |
| Sabit imza, Xcode projesi, ikon, widget'lı derleme | ✅ derleme/paket |
| Terminale tıklayınca crash düzeltmesi (kendi bölme düzeni) | ⚠️ derleniyor, tıklanarak denenmedi |
| Dosya geçmişi ve diff penceresi | ⚠️ git sorguları testli, arayüz denenmedi |
| Sürükle-bırak (oturum → bölme, dosya → terminal), bölme çizgisini sürükleme | ⚠️ denenmedi |
| Sidebar/dosya paneli tıklamaları, dosya panelinin tıklanan projeyi göstermesi | ⚠️ denenmedi |
| Gruplar: boş grup, çoklu atama, grup +, otomatik açılma, sıralama, başlık rengi | ⚠️ denenmedi |
| Pencere içi onay soruları (sheet) | ⚠️ denenmedi |
| "Reddet" ve bildirimdeki İzin ver / Reddet düğmeleri | ⚠️ denenmedi |
| Bildirim banner'ı ve tıklayınca oturumun açılması | ⚠️ denenmedi |
| Dock rozeti / zıplama, menü çubuğu öğesi | ⚠️ denenmedi |
| Widget'ın masaüstünde görünmesi ve `claudedeck://` bağlantısı | ⚠️ denenmedi |
| Worktree oturumları (`claude --worktree`) | ⚠️ hiç çalıştırılmadı |
| iCloud eşitleme | ⚠️ yalnızca birim testleri |
| Bilgisayar açılınca başlat (giriş öğesi) | ⚠️ denenmedi (`./build.sh install` gerekir) |
| Kapalı pencereyi Dock'tan geri açma | ⚠️ denenmedi |

"Denenmedi" olanlar ekran kaydı izni olmadan ekrana tıklanamadığı içindir; kod derleniyor.

## Tasarım kararları

### İzni bildirimden / uygulamadan onaylamak
pty zaten uygulamada; kullanıcının basacağı tuşu yazıyoruz: onay = `1` (Enter'sız), ret = Esc. Durum mevcut
yollardan çözülür: `1` terminal girdisi olarak `answeredAt`'i ayarlar (→ çalışıyor); Esc transcript'e
"[Request interrupted by user for tool use]" yazdırır (→ "İzin reddedildi — sıra sende").
Güvenlik: yalnızca `.claude` oturumu, terminal çalışıyor, durum `needsPermission` (soru değil) ve hook'un
`updated_at`'i bildirimin/düğmenin damgasıyla aynıysa. `ExitPlanMode` hariç (orada `1` izin modunu da
değiştirir). Aynı istem için ikinci ret yok sayılır (ikinci Esc Claude'un geri alma seçicisini açabilirdi).

Neden bloklayan `PermissionRequest` hook'u değil: hook uygulamanın kararını beklerken terminaldeki istem
gecikir, zaman aşımı ile terminalden verilen cevap yarışır ve terminalde cevaplamak bozulabilir. Hook
betiği ve settings.json'a dokunulmadı.

### Durum kaynakları
- Hook olayları (resmi dokümandan): SessionStart/End, UserPromptSubmit, Pre/PostToolUse(Failure),
  PermissionRequest, Notification, Stop, StopFailure.
- Doğrulandı: hook'lar claude'un env'ini görür (`CLAUDEDECK_TERMINAL_ID`), `$PPID` claude sürecidir,
  `AskUserQuestion` bir `PermissionRequest` (tool_name=AskUserQuestion) tetikler, Esc/ret `Stop` tetiklemez,
  `PermissionRequest` `tool_use_id` taşımaz (araç imzasıyla eşleştirilir).
- Ekran okuma yok; transcript yalnızca kesme/ret kaydı ve context token'ı için okunur.

### Ortam
- Uygulama bir Claude oturumunun içinden açılırsa `CLAUDECODE` / `CLAUDE_CODE_*` değişkenleri alt
  süreçlere geçip claude'u "child session" yapıyordu (transcript kaydı kapanır). Terminal ortamından
  temizleniyor; login shell kullanıcının kendi ayarlarını yeniden yükler.
- Uygulama sandbox'sız (pty, shell, `~/.claude`); widget uzantısı sandbox'lı.

### Yerleşim
- SwiftUI `HSplitView`/`VSplitView` kullanılmıyor: NSSplitView'ın min-size güncellemeleri terminal
  görünümleriyle sonsuz constraint döngüsüne girip uygulamayı çökertiyordu (terminale tıklayınca /
  dosya geçmişi açılınca). Bölmeler kendi `PaneSplit` düzeniyle, sürüklenebilir çizgilerle çizilir;
  `TerminalHost` SwiftUI'ya kendi boyutunu bildirmez.

## Çözülen önemli hatalar
- Boş oturumda `--resume` hatası → transcript yoksa temiz başlatma.
- "Oturumu bitir" sonrası çıkışın bildirilmemesi (SwiftTerm monitörü iptal ediyordu) → reap + bildirim.
- Liste satırlarında sürükleme kaynağının tıklama seçimini yutması → açık tıklama işleme.
- Metin + Enter'ın tek seferde yapıştırma sayılması → Enter ayrı gönderilir.
- Crash: split view'ların constraint döngüsü → kendi bölme düzeni (yukarıda).
- Grup renginin tüm alt satırlara taşması → yalnızca başlık satırı tonlu.

## Bilinen sınırlar
- Transcript dosyası silinip yeniden oluşturulursa o oturumun kesme/ret takibi durur (Claude hep ekler;
  pratikte olmuyor).
- Worktree oturumu: `SessionStart` ilk `cwd`'yi proje kökü olarak bildirirse devam ettirme kökte çalışır;
  silinmiş worktree için `-w <ad>` tekrar verilir (claude'un davranışı doğrulanmadı).
- iCloud: silme yayılmaz; iCloud Drive'a ilk erişimde macOS izin sorabilir.
- Snapshot aracı cam kenar çubuğunu çizemez (yalnızca test aracı sınırı).

## Kalan işler
- **Notarization:** `notarize.sh` hazır; Developer ID Application sertifikası ve notarytool profili gerekiyor.
- Yukarıdaki ⚠️ maddelerin elle denenmesi.
