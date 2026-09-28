#!/bin/sh
# Launches build/ClaudeDeck.app in demo mode with made-up projects and sessions, for screenshots.
#
#   ./build.sh && tools/demo.sh
#
# Everything lives in $CLAUDEDECK_DEMO_ROOT (default /tmp/ClaudeDeckDemo) and is recreated on every run.
# Demo mode never touches ~/.claude/settings.json, your deck.json or iCloud: sessions run
# tools/demo-claude.sh (a stand-in that prints a canned conversation and reports a fixed state)
# instead of the real `claude`.
set -eu
cd "$(dirname "$0")/.."

ROOT="${CLAUDEDECK_DEMO_ROOT:-/tmp/ClaudeDeckDemo}"
APP=build/ClaudeDeck.app
[ -d "$APP" ] || { echo "❌ $APP not found; run ./build.sh first" >&2; exit 1; }

pkill -f "$ROOT/bin/claude" 2>/dev/null || true
rm -rf "$ROOT"
mkdir -p "$ROOT/bin" "$ROOT/scenes" "$ROOT/sessions" "$ROOT/data" "$ROOT/projects"
cp tools/demo-claude.sh "$ROOT/bin/claude"
chmod +x "$ROOT/bin/claude"

# --- Projects: small git repos with a little history and some uncommitted changes ------------------
repo() { # name, then "path|content" lines on stdin
  dir="$ROOT/projects/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Demo"
  git -C "$dir" config user.email "demo@example.com"
  while IFS='|' read -r path content; do
    mkdir -p "$dir/$(dirname "$path")"
    printf '%s\n' "$content" > "$dir/$path"
  done
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "Initial commit"
}

repo acme-storefront <<'EOF'
package.json|{ "name": "acme-storefront", "private": true, "scripts": { "dev": "next dev", "test": "vitest" } }
README.md|# Acme Storefront
src/cart/CartSummary.tsx|export function CartSummary() { return null }
src/cart/useCart.ts|export function useCart() { return { items: [] } }
src/checkout/Checkout.tsx|export function Checkout() { return null }
src/checkout/payment.ts|export async function pay() {}
src/app/page.tsx|export default function Page() { return null }
tests/checkout.test.ts|import { test } from "vitest"
EOF
D="$ROOT/projects/acme-storefront"
printf 'export function CartSummary({ items }) {\n  const total = items.reduce((s, i) => s + i.price * i.qty, 0)\n  return total\n}\n' > "$D/src/cart/CartSummary.tsx"
git -C "$D" commit -qam "Show cart total"
printf 'export function CartSummary({ items, discount = 0 }) {\n  const subtotal = items.reduce((s, i) => s + i.price * i.qty, 0)\n  return subtotal - discount\n}\n' > "$D/src/cart/CartSummary.tsx"
printf 'export function applyCoupon(code) { return code === "WELCOME10" ? 0.1 : 0 }\n' > "$D/src/cart/coupons.ts"

repo payments-api <<'EOF'
go.mod|module example.com/payments
main.go|package main
internal/webhooks/worker.go|package webhooks
internal/webhooks/retry.go|package webhooks
docker-compose.yml|services: {}
EOF
printf 'package webhooks\n\n// TODO: backoff\n' > "$ROOT/projects/payments-api/internal/webhooks/retry.go"
cat > "$ROOT/projects/payments-api/dev.sh" <<'EOF'
#!/bin/sh
# Demo stand-in for a dev server.
printf '\033[35mpayments-db \033[0m | database system is ready to accept connections\n'
printf '\033[36mpayments-api\033[0m | migrations up to date (42)\n'
printf '\033[36mpayments-api\033[0m | listening on http://localhost:8080\n'
printf '\033[36mpayments-api\033[0m | POST /v1/webhooks/stripe 200 12ms\n'
exec sleep 86400
EOF
chmod +x "$ROOT/projects/payments-api/dev.sh"

repo mobile-app <<'EOF'
Package.swift|// swift-tools-version: 6.0
Sources/Feed/FeedView.swift|import SwiftUI
Sources/Feed/FeedModel.swift|import Foundation
Tests/FeedTests/FeedTests.swift|import Testing
EOF

repo swift-markdown-kit <<'EOF'
Package.swift|// swift-tools-version: 6.0
Sources/MarkdownKit/Table.swift|struct Table {}
Sources/MarkdownKit/Parser.swift|struct Parser {}
EOF

repo blog <<'EOF'
astro.config.mjs|export default {}
src/posts/hello-world.md|# Hello
EOF

# --- deck.json ----------------------------------------------------------------------------------
G1=A0000000-0000-0000-0000-000000000001
G2=A0000000-0000-0000-0000-000000000002
P1=B0000000-0000-0000-0000-000000000001
P2=B0000000-0000-0000-0000-000000000002
P3=B0000000-0000-0000-0000-000000000003
P4=B0000000-0000-0000-0000-000000000004
P5=B0000000-0000-0000-0000-000000000005
S1=C0000000-0000-0000-0000-000000000001
S2=C0000000-0000-0000-0000-000000000002
S3=C0000000-0000-0000-0000-000000000003
S4=C0000000-0000-0000-0000-000000000004
S5=C0000000-0000-0000-0000-000000000005
S6=C0000000-0000-0000-0000-000000000006
S7=C0000000-0000-0000-0000-000000000007
NOW=$(date +%s)
P="$ROOT/projects"

cat > "$ROOT/data/deck.json" <<EOF
{
  "version": 1,
  "groups": [
    { "id": "$G1", "name": "Client Work", "collapsed": false, "colorIndex": 2 },
    { "id": "$G2", "name": "Open Source", "collapsed": false, "colorIndex": 4 }
  ],
  "projects": [
    { "id": "$P1", "path": "$P/acme-storefront", "name": "acme-storefront", "pinned": true, "collapsed": false },
    { "id": "$P2", "path": "$P/payments-api", "name": "payments-api", "groupID": "$G1", "pinned": false, "collapsed": false },
    { "id": "$P3", "path": "$P/mobile-app", "name": "mobile-app", "groupID": "$G1", "pinned": false, "collapsed": false },
    { "id": "$P4", "path": "$P/swift-markdown-kit", "name": "swift-markdown-kit", "groupID": "$G2", "pinned": false, "collapsed": false },
    { "id": "$P5", "path": "$P/blog", "name": "blog", "pinned": false, "collapsed": false }
  ],
  "sessions": [
    { "id": "$S1", "projectID": "$P1", "name": "acme-storefront", "kind": "claude", "createdAt": $NOW, "isOpen": true },
    { "id": "$S2", "projectID": "$P1", "name": "acme-storefront · 2", "kind": "claude", "createdAt": $NOW, "isOpen": true },
    { "id": "$S3", "projectID": "$P2", "name": "payments-api", "kind": "claude", "createdAt": $NOW, "isOpen": true },
    { "id": "$S4", "projectID": "$P2", "name": "payments-api · ./dev.sh", "kind": "shell", "createdAt": $NOW, "isOpen": true,
      "startupCommand": "./dev.sh", "autoStart": true },
    { "id": "$S5", "projectID": "$P3", "name": "mobile-app", "kind": "claude", "createdAt": $NOW, "isOpen": true },
    { "id": "$S6", "projectID": "$P4", "name": "swift-markdown-kit · fix-tables", "kind": "claude", "createdAt": $NOW, "isOpen": true, "worktreeName": "fix-tables" },
    { "id": "$S7", "projectID": "$P5", "name": "blog", "kind": "claude", "createdAt": $NOW, "lastActivityAt": $((NOW - 7200)), "isOpen": false }
  ],
  "selectedSessionID": "$S1",
  "panes": [ "$S1", "$S2" ],
  "settings": { "resumeOnLaunch": true, "compactOnResume": false, "notifications": true, "bounceDock": false, "confirmQuit": false }
}
EOF

# --- Scenes: what each stand-in session prints, and the state it reports -----------------------
# <id>.state: state|event|tool_name|detail
scene() { printf '%s\n' "$2" > "$ROOT/scenes/$1.state"; cat > "$ROOT/scenes/$1.txt"; }

scene $S1 'needsPermission|PermissionRequest|Bash|Bash: pnpm vitest run tests/checkout.test.ts' <<'EOF'
[1m> [0mAdd coupon support to the cart summary and make sure checkout still passes.

[1m●[0m I'll add a [36mdiscount[0m prop to CartSummary and a small coupon helper.

[1m●[0m [1mUpdate[0m(src/cart/CartSummary.tsx)
  [2m⎿  Updated with 2 additions and 1 removal[0m
     [32m+ export function CartSummary({ items, discount = 0 }) {[0m
     [32m+   const subtotal = items.reduce((s, i) => s + i.price * i.qty, 0)[0m
     [31m-   const total = items.reduce((s, i) => s + i.price * i.qty, 0)[0m

[1m●[0m [1mWrite[0m(src/cart/coupons.ts)
  [2m⎿  Wrote 1 line[0m

[1m●[0m Now let me run the checkout tests.

[33m╭──────────────────────────────────────────────────────────────────╮[0m
[33m│[0m [1mBash command[0m                                                     [33m│[0m
[33m│[0m                                                                  [33m│[0m
[33m│[0m   pnpm vitest run tests/checkout.test.ts                         [33m│[0m
[33m│[0m   [2mRun the checkout test suite[0m                                    [33m│[0m
[33m│[0m                                                                  [33m│[0m
[33m│[0m Do you want to proceed?                                          [33m│[0m
[33m│[0m [36m❯ 1. Yes[0m                                                         [33m│[0m
[33m│[0m   2. Yes, and don't ask again for [1mpnpm vitest[0m commands           [33m│[0m
[33m│[0m   3. No, and tell Claude what to do differently ([1mesc[0m)            [33m│[0m
[33m╰──────────────────────────────────────────────────────────────────╯[0m
EOF

scene $S2 'running|PostToolUse|Edit|Edit: src/checkout/Checkout.tsx' <<'EOF'
[1m> [0mMigrate the checkout page to the new design tokens.

[1m●[0m [1mRead[0m(src/checkout/Checkout.tsx)
  [2m⎿  Read 142 lines[0m

[1m●[0m [1mRead[0m(src/styles/tokens.ts)
  [2m⎿  Read 58 lines[0m

[1m●[0m The page still uses hard-coded colors in 9 places. Replacing them with tokens.

[1m●[0m [1mUpdate[0m(src/checkout/Checkout.tsx)
  [2m⎿  Updated with 9 additions and 9 removals[0m

[38;5;208m✻ Refactoring… [2m(34s · ↓ 1.2k tokens · esc to interrupt)[0m
EOF

scene $S3 'needsAnswer|PreToolUse|AskUserQuestion|Which retry strategy should the webhook worker use?' <<'EOF'
[1m> [0mMake webhook delivery retry on failures.

[1m●[0m [1mRead[0m(internal/webhooks/worker.go)
  [2m⎿  Read 211 lines[0m

[1m●[0m Before I change the worker, one decision:

[36m☐ Retry strategy[0m

[1mWhich retry strategy should the webhook worker use?[0m

[36m❯ 1. Exponential backoff[0m
     Up to 8 attempts over ~24h, with jitter
  2. Fixed interval
     Every 5 minutes, up to 12 attempts
  3. Dead-letter only
     No retries; failed events go to a queue for manual replay
EOF

scene $S5 'idle|Stop||Done — added pull-to-refresh to the feed and updated the snapshot tests.' <<'EOF'
[1m> [0mAdd pull-to-refresh to the feed screen.

[1m●[0m [1mUpdate[0m(Sources/Feed/FeedView.swift)
  [2m⎿  Updated with 6 additions[0m

[1m●[0m [1mUpdate[0m(Sources/Feed/FeedModel.swift)
  [2m⎿  Updated with 14 additions and 2 removals[0m

[1m●[0m [1mBash[0m(swift test)
  [2m⎿  ✔ Test run with 42 tests passed after 1.84 seconds.[0m

[1m●[0m Done — added pull-to-refresh to the feed and updated the snapshot tests.
  • [36mFeedView[0m uses [36m.refreshable[0m and shows the last-updated time
  • [36mFeedModel.reload()[0m is now async and cancels an in-flight load

[1m> [0m[7m [0m
EOF

scene $S6 'running|PreToolUse|Bash|Bash: swift test --filter TableTests' <<'EOF'
[1m> [0mTables with escaped pipes render as extra columns. Fix it.

[1m●[0m [1mRead[0m(Sources/MarkdownKit/Table.swift)
  [2m⎿  Read 96 lines[0m

[1m●[0m The cell splitter ignores backslash escapes. Adding a small scanner.

[1m●[0m [1mUpdate[0m(Sources/MarkdownKit/Table.swift)
  [2m⎿  Updated with 18 additions and 4 removals[0m

[1m●[0m [1mBash[0m(swift test --filter TableTests)
  [2m⎿  Running…[0m

[38;5;208m✻ Testing… [2m(12s · esc to interrupt)[0m
EOF

echo "Demo data: $ROOT"
CLAUDEDECK_DEMO=1 \
CLAUDEDECK_DATA_DIR="$ROOT/data" \
CLAUDEDECK_STATE_DIR="$ROOT/sessions" \
CLAUDEDECK_CLAUDE_PATH="$ROOT/bin/claude" \
  "$APP/Contents/MacOS/ClaudeDeck" >/dev/null 2>&1 &
echo "ClaudeDeck demo started (pid $!). Quit it with ⌘Q; run this script again for a fresh copy."
