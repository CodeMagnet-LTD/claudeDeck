# Sonraki faz notları

## İzni uygulamadan / bildirimden onaylamak
Resmi dokümanda doğrulandı: `PermissionRequest` hook'u karar döndürebilir.

```json
{ "hookSpecificOutput": { "hookEventName": "PermissionRequest",
    "decision": { "behavior": "allow" } } }
```
(`"deny"` da mümkün; `updatedPermissions` ile mod değiştirilebilir.)
Plan: hook, ClaudeDeck terminalindeyse durum dosyasını yazıp uygulamanın kararını kısa süre bekler
(ör. `~/.claude/deck/decisions/<session>.json`, zaman aşımında hiçbir şey döndürmez → normal terminal
istemi). Bildirime "İzin ver / Reddet" aksiyonları eklenir. Hook zaman aşımı ve terminaldeki istemle
yarış durumu dikkatle ele alınmalı.

## Diğer fikirler
- Widget (WidgetKit): XcodeGen'e app extension hedefi + App Group; uygulama `WidgetCenter.reloadAllTimelines()` çağırır.
- Oturum başına git worktree (aynı projede paralel oturumların dosya çakışmasını önlemek için; `claude -w`).
- Projeler/gruplar için iCloud Drive eşitleme.
- Notarization (Developer ID) — başka Mac'lerde Gatekeeper uyarısı olmadan açılış.
- Doğrulandı: `AskUserQuestion` bir `PermissionRequest` (tool_name=AskUserQuestion) tetikliyor → 🔴 Soru soruyor, soru metniyle.
