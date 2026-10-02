#!/bin/sh
# Launches build/ClaudeDeck.app in demo mode with made-up projects and sessions, for screenshots.
#
#   ./build.sh && tools/demo.sh
#   tools/demo.sh -AppleLanguages '(tr)'     # same, with the Turkish UI
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
checkout() { # extra text ("" for none): $1 after the imports, $2 after the state, $3 + $4 in and after <CartSummary>
  cat <<TSX
import { useState } from "react"
import { useCart } from "../cart/useCart"
import { CartSummary } from "../cart/CartSummary"
import { pay } from "./payment"$1

type Status = "idle" | "paying" | "done" | "error"

export function Checkout() {
  const { items, clear } = useCart()
  const [status, setStatus] = useState<Status>("idle")
  const [error, setError] = useState<string | null>(null)$2

  async function submit() {
    setStatus("paying")
    try {
      await pay(items)
      clear()
      setStatus("done")
    } catch (e) {
      setError(e instanceof Error ? e.message : "Payment failed")
      setStatus("error")
    }
  }

  if (status === "done") {
    return <p className="checkout-done">Thanks! Your order is on its way.</p>
  }

  return (
    <section className="checkout">
      <h1>Checkout</h1>
      <CartSummary items={items}$3 />$4
      {error && <p role="alert">{error}</p>}
      <button disabled={status === "paying"} onClick={submit}>
        Pay now
      </button>
    </section>
  )
}
TSX
}
checkout '' '' '' '' > "$D/src/checkout/Checkout.tsx"
git -C "$D" commit -qam "Checkout page"
printf 'export function CartSummary({ items, discount = 0 }) {\n  const subtotal = items.reduce((s, i) => s + i.price * i.qty, 0)\n  return subtotal - discount\n}\n' > "$D/src/cart/CartSummary.tsx"
printf 'export function applyCoupon(code) { return code === "WELCOME10" ? 0.1 : 0 }\n' > "$D/src/cart/coupons.ts"
checkout '
import { CouponField } from "./CouponField"' '
  const [discount, setDiscount] = useState(0)' ' discount={discount}' '
      <CouponField onApply={setDiscount} />' > "$D/src/checkout/Checkout.tsx"
git -C "$D" add src/cart/coupons.ts

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

# --- GitHub: a stand-in `gh` that answers from fixtures (made-up repositories and people) ----------
mkdir -p "$ROOT/github"
cat > "$ROOT/bin/gh" <<'EOF'
#!/bin/sh
# Demo stand-in for the GitHub CLI: answers `auth status`, `pr|issue view N`, `pr|issue list`,
# `repo view` and `run view --log-failed` from fixture files.
D="$(dirname "$0")/../github"
case "$1 $2" in
  "auth status") exit 0 ;;
  "pr view"|"issue view") [ -f "$D/$1-$3.json" ] && exec cat "$D/$1-$3.json" ;;
  "repo view")
    case "$(basename "$PWD")" in
      acme-storefront) echo acme/storefront; exit 0 ;;
      payments-api) echo acme/payments-api; exit 0 ;;
    esac ;;
  "pr list"|"issue list")
    case " $* " in *" --head "*) ;; *)
      f="$D/$1-list.json"
      case " $* " in *"@me"*) f="$D/$1-list-me.json" ;; esac
      [ -f "$f" ] && exec cat "$f"
      echo "[]"; exit 0 ;;
    esac ;;
  "run view") [ -f "$D/run-log.txt" ] && exec cat "$D/run-log.txt" ;;
esac
echo "demo gh: no fixture for: $*" >&2
exit 1
EOF
chmod +x "$ROOT/bin/gh"
ago() { date -u -v-"$1" +%Y-%m-%dT%H:%M:%SZ; }   # ago 3H → ISO 8601, three hours ago

cat > "$ROOT/github/pr-42.json" <<EOF
{ "number": 42, "title": "Coupon codes in the cart", "state": "OPEN", "isDraft": false,
  "url": "https://github.com/acme/storefront/pull/42", "headRefName": "coupon-codes",
  "author": { "login": "alex" }, "updatedAt": "$(ago 25M)",
  "labels": [ { "name": "feature", "color": "1d76db" }, { "name": "checkout", "color": "fbca04" } ],
  "body": "Adds a **coupon field** to checkout and a \`discount\` prop to \`CartSummary\`.\n\n- \`WELCOME10\` takes 10% off\n- Invalid codes show an inline error\n\nCloses #37.",
  "reviewDecision": "CHANGES_REQUESTED", "mergeStateStatus": "BLOCKED",
  "comments": [
    { "id": "c1", "author": { "login": "alex" }, "body": "Screenshots of the new field are in the description of #37.", "createdAt": "$(ago 3H)" }
  ],
  "latestReviews": [
    { "author": { "login": "sam" }, "state": "CHANGES_REQUESTED", "submittedAt": "$(ago 40M)",
      "body": "Looks good overall. Coupon codes should be **case-insensitive**, and the e2e checkout test fails with a discount applied." }
  ],
  "statusCheckRollup": [
    { "__typename": "CheckRun", "name": "lint", "status": "COMPLETED", "conclusion": "SUCCESS" },
    { "__typename": "CheckRun", "name": "unit tests", "status": "COMPLETED", "conclusion": "SUCCESS" },
    { "__typename": "CheckRun", "name": "build", "status": "COMPLETED", "conclusion": "SUCCESS" },
    { "__typename": "CheckRun", "name": "e2e (chromium)", "workflowName": "CI", "status": "COMPLETED", "conclusion": "FAILURE",
      "detailsUrl": "https://github.com/acme/storefront/actions/runs/9001/job/9002" }
  ] }
EOF
cat > "$ROOT/github/issue-118.json" <<EOF
{ "number": 118, "title": "Webhook deliveries are lost when the receiver times out", "state": "OPEN",
  "url": "https://github.com/acme/payments-api/issues/118", "author": { "login": "jordan" },
  "updatedAt": "$(ago 2H)", "labels": [ { "name": "bug", "color": "d73a4a" } ],
  "body": "When a merchant endpoint takes longer than 10 s we drop the event. We should retry with backoff.",
  "comments": [] }
EOF
cat > "$ROOT/github/pr-7.json" <<EOF
{ "number": 7, "title": "Escaped pipes in table cells", "state": "MERGED", "isDraft": false,
  "url": "https://github.com/acme/swift-markdown-kit/pull/7", "headRefName": "fix-tables",
  "author": { "login": "casey" }, "updatedAt": "$(ago 1d)", "labels": [], "body": "Fixes #6.",
  "reviewDecision": "APPROVED", "comments": [], "latestReviews": [],
  "statusCheckRollup": [ { "__typename": "CheckRun", "name": "swift test", "status": "COMPLETED", "conclusion": "SUCCESS" } ] }
EOF
cat > "$ROOT/github/issue-list.json" <<EOF
[ { "number": 51, "title": "Cart total ignores shipping for EU addresses", "author": { "login": "jordan" },
    "labels": [ { "name": "bug", "color": "d73a4a" } ], "createdAt": "$(ago 2H)", "updatedAt": "$(ago 1H)",
    "url": "https://github.com/acme/storefront/issues/51" },
  { "number": 37, "title": "Coupon codes at checkout", "author": { "login": "sam" },
    "labels": [ { "name": "feature", "color": "1d76db" } ], "createdAt": "$(ago 3d)", "updatedAt": "$(ago 3H)",
    "url": "https://github.com/acme/storefront/issues/37" } ]
EOF
cat > "$ROOT/github/issue-list-me.json" <<EOF
[ { "number": 51, "title": "Cart total ignores shipping for EU addresses", "author": { "login": "jordan" },
    "labels": [ { "name": "bug", "color": "d73a4a" } ], "createdAt": "$(ago 2H)", "updatedAt": "$(ago 1H)",
    "url": "https://github.com/acme/storefront/issues/51" } ]
EOF
cat > "$ROOT/github/issue-51.json" <<EOF
{ "number": 51, "title": "Cart total ignores shipping for EU addresses", "state": "OPEN",
  "url": "https://github.com/acme/storefront/issues/51", "author": { "login": "jordan" },
  "updatedAt": "$(ago 1H)", "labels": [ { "name": "bug", "color": "d73a4a" } ],
  "body": "With a German address the cart shows the **subtotal** as the total. \`shippingFor(country:)\` returns 0 for EU codes.",
  "comments": [ { "id": "c51", "author": { "login": "alex" }, "body": "Reproduced with DE and FR.", "createdAt": "$(ago 1H)" } ] }
EOF
cat > "$ROOT/github/pr-list.json" <<EOF
[ { "number": 42, "title": "Coupon codes in the cart", "author": { "login": "alex" }, "isDraft": false,
    "labels": [ { "name": "feature", "color": "1d76db" } ], "createdAt": "$(ago 1d)", "updatedAt": "$(ago 25M)",
    "url": "https://github.com/acme/storefront/pull/42" } ]
EOF
printf 'e2e (chromium)\tRun tests\t2026-01-01T10:00:00.0000000Z FAIL checkout.spec.ts > applies WELCOME10\ne2e (chromium)\tRun tests\t2026-01-01T10:00:00.0000000Z Expected: 90.00  Received: 100.00\n' > "$ROOT/github/run-log.txt"

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
A1=D0000000-0000-0000-0000-000000000001
A2=D0000000-0000-0000-0000-000000000002
A3=D0000000-0000-0000-0000-000000000003
at() { date -v"$1" -v"$2"H -v"$3"M -v0S +%s; }   # at -1d 9 0 → yesterday 09:00
NEXT_WEEKDAY=$(n=1; while [ "$(date -v+${n}d +%u)" -gt 5 ]; do n=$((n + 1)); done; at +${n}d 9 0)
NEXT_MONDAY=$(date -v+1d -v+mon -v10H -v0M -v0S +%s)

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
    { "id": "$S1", "projectID": "$P1", "name": "acme-storefront", "kind": "claude", "createdAt": $NOW, "isOpen": true,
      "linkedWorkItem": { "kind": "pr", "repo": "acme/storefront", "number": 42 } },
    { "id": "$S2", "projectID": "$P1", "name": "acme-storefront · 2", "kind": "claude", "createdAt": $NOW, "isOpen": true },
    { "id": "$S3", "projectID": "$P2", "name": "payments-api", "kind": "claude", "createdAt": $NOW, "isOpen": true,
      "linkedWorkItem": { "kind": "issue", "repo": "acme/payments-api", "number": 118 } },
    { "id": "$S4", "projectID": "$P2", "name": "payments-api · ./dev.sh", "kind": "shell", "createdAt": $NOW, "isOpen": true,
      "startupCommand": "./dev.sh", "autoStart": true },
    { "id": "$S5", "projectID": "$P3", "name": "mobile-app", "kind": "claude", "createdAt": $NOW, "isOpen": true },
    { "id": "$S6", "projectID": "$P4", "name": "swift-markdown-kit · fix-tables", "kind": "claude", "createdAt": $NOW, "isOpen": true, "worktreeName": "fix-tables",
      "linkedWorkItem": { "kind": "pr", "repo": "acme/swift-markdown-kit", "number": 7 } },
    { "id": "$S7", "projectID": "$P5", "name": "blog", "kind": "claude", "createdAt": $NOW, "lastActivityAt": $((NOW - 7200)), "isOpen": false }
  ],
  "selectedSessionID": "$S1",
  "panes": [ "$S1", "$S2" ],
  "automations": [
    { "id": "$A1", "name": "Test health", "projectID": "$P1", "workspace": "current", "reuseSession": false,
      "prompt": "Run the tests, lint and type checks. If anything is red, find the cause and fix what is safe to fix. Finish with a short summary of what you changed and what still needs a human.",
      "triggers": [ { "kind": "time", "schedule": "weekdays", "hour": 9, "minute": 0 } ],
      "enabled": true, "nextRunAt": $NEXT_WEEKDAY, "lastRunAt": $(at -1d 9 0), "lastRunStatus": "succeeded",
      "lastSessionID": "$S2", "createdAt": $((NOW - 864000)), "updatedAt": $((NOW - 864000)) },
    { "id": "$A2", "name": "Weekly changelog", "projectID": "$P2", "workspace": "newWorktree", "reuseSession": false,
      "prompt": "Summarize this week's commits into a changelog people can read, grouped by feature. Write it to CHANGELOG.md.",
      "triggers": [ { "kind": "time", "schedule": "weekly", "weekday": 2, "hour": 10, "minute": 0 } ],
      "enabled": true, "nextRunAt": $NEXT_MONDAY, "lastRunStatus": "succeeded", "createdAt": $((NOW - 1728000)) },
    { "id": "$A3", "name": "Audit dependencies", "projectID": "$P3", "workspace": "current", "reuseSession": false,
      "prompt": "Check Package.resolved for vulnerable, unused or unexpectedly upgraded packages.",
      "triggers": [ { "kind": "time", "schedule": "daily", "hour": 8, "minute": 30 } ],
      "enabled": false, "createdAt": $((NOW - 259200)) }
  ],
  "automationRuns": [
    { "id": "E0000000-0000-0000-0000-000000000001", "automationID": "$A1", "trigger": "scheduled", "scheduledFor": $(at -1d 9 0),
      "startedAt": $(at -1d 9 0), "completedAt": $(at -1d 9 6), "status": "succeeded", "sessionID": "$S2" },
    { "id": "E0000000-0000-0000-0000-000000000002", "automationID": "$A1", "trigger": "manual",
      "startedAt": $(at -2d 14 12), "completedAt": $(at -2d 14 19), "status": "succeeded" },
    { "id": "E0000000-0000-0000-0000-000000000003", "automationID": "$A1", "trigger": "scheduled", "scheduledFor": $(at -2d 9 0),
      "startedAt": $(at -2d 9 0), "completedAt": $(at -2d 9 30), "status": "failed", "error": "Timed out waiting for Claude to finish." },
    { "id": "E0000000-0000-0000-0000-000000000004", "automationID": "$A1", "trigger": "scheduled", "scheduledFor": $(at -3d 9 0),
      "startedAt": $(at -3d 11 42), "completedAt": $(at -3d 11 42), "status": "skipped", "error": "Missed the scheduled run beyond its grace period." },
    { "id": "E0000000-0000-0000-0000-000000000005", "automationID": "$A2", "trigger": "scheduled", "scheduledFor": $(at -2d 10 0),
      "startedAt": $(at -2d 10 0), "completedAt": $(at -2d 10 8), "status": "succeeded" }
  ],
  "settings": { "resumeOnLaunch": true, "compactOnResume": false, "notifications": true, "bounceDock": false, "confirmQuit": false,
                "pencilMCP": false, "terminalFontSize": 11 }
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

[33m╭──────────────────────────────────────────────────────────╮[0m
[33m│[0m [1mBash command[0m                                             [33m│[0m
[33m│[0m                                                          [33m│[0m
[33m│[0m   pnpm vitest run tests/checkout.test.ts                 [33m│[0m
[33m│[0m   [2mRun the checkout test suite[0m                            [33m│[0m
[33m│[0m                                                          [33m│[0m
[33m│[0m Do you want to proceed?                                  [33m│[0m
[33m│[0m [36m❯ 1. Yes[0m                                                 [33m│[0m
[33m│[0m   2. Yes, and don't ask again for [1mpnpm vitest[0m commands   [33m│[0m
[33m│[0m   3. No, and tell Claude what to do differently ([1mesc[0m)    [33m│[0m
[33m╰──────────────────────────────────────────────────────────╯[0m
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
CLAUDEDECK_GH_PATH="$ROOT/bin/gh" \
  "$APP/Contents/MacOS/ClaudeDeck" "$@" >/dev/null 2>&1 &
echo "ClaudeDeck demo started (pid $!). Quit it with ⌘Q; run this script again for a fresh copy."
