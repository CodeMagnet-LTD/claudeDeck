# Sonraki faz notları

## Yapıldı: izni bildirimden / uygulamadan onaylamak
İzin isteyen oturumun bildiriminde "İzin ver / Reddet" aksiyonları var (kategori `permission`); aynı
düğmeler "Bekleyenler" satırında, bölme başlığında ve oturumun sağ tık menüsünde de çıkıyor.

Tasarım: pty zaten uygulamada, o yüzden kullanıcının basacağı tuşu yazıyoruz — onay = `1` (Evet,
Enter'sız), ret = Esc. Durum mevcut yollardan çözülüyor: `1` terminal girdisi olarak `userTyped`'a
düşer ve `answeredAt`'i ayarlar (→ çalışıyor); Esc transkripte "[Request interrupted by user for tool
use]" yazdırır ve tailer bunu `toolDenied` olarak okur (→ "İzin reddedildi — sıra sende").
Güvenlik: yalnızca `.claude` oturumu, terminal çalışıyor, çözülmüş durum `needsPermission` (soru
değil) ve hook'un `updated_at`'i bildirimin/düğmenin oluşturulduğu damgayla aynıysa. Aksi halde
bildirim aksiyonu sadece oturumu açar. `ExitPlanMode` hariç: orada 1 aynı zamanda izin modunu değiştirir.

Neden bloklayan `PermissionRequest` hook'u değil: hook uygulamanın kararını beklerken Claude
terminaldeki istemi göstermeyi geciktirir, zaman aşımı ile terminalden verilen cevap yarışır ve
terminalde doğrudan cevap vermek bozulabilir. Hook betiği ve settings.json'a hiç dokunulmadı.

## Diğer fikirler
- Widget (WidgetKit): XcodeGen'e app extension hedefi + App Group; uygulama `WidgetCenter.reloadAllTimelines()` çağırır.
- Oturum başına git worktree (aynı projede paralel oturumların dosya çakışmasını önlemek için; `claude -w`).
- Projeler/gruplar için iCloud Drive eşitleme.
- Notarization (Developer ID) — başka Mac'lerde Gatekeeper uyarısı olmadan açılış.
- Doğrulandı: `AskUserQuestion` bir `PermissionRequest` (tool_name=AskUserQuestion) tetikliyor → 🔴 Soru soruyor, soru metniyle.
