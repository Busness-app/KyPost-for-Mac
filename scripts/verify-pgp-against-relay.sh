#!/usr/bin/env bash
#
# Checks that what this client would put on the wire is what the relay will
# actually accept -- by running the relay's OWN decoder and validators over it,
# not a second opinion written in this repository.
#
# Everything else here checks the send path against fakes defined in this
# repository, so the one thing never checked is whether the server agrees.
# Re-deriving its rules locally would give exactly the second, weaker copy that
# divergence is made of, so this drives the originals:
#
#   * one PGP/MIME delivery, against validatePGPMimeDeliveryShape,
#     validatePGPMimeDelivery and the SMTP normaliser;
#   * the protected-headers content part, against ExtractProtectedSubject, so a
#     non-ASCII subject is shown to round-trip;
#   * the WHOLE send request, decoded into the server's own
#     clientEncryptedSendRequest and run through its per-delivery validation and
#     its Sent-copy logic.
#
# The fixtures are the literal bytes the app would have POSTed: a test drives
# the real ClientEncryptedSender and the real ClientEncryptedSendClient over a
# stub transport and writes the captured request body out. See
# `KyPost Tests/PgpRelayFixtureEmitter.swift`.
#
# NOT part of CI: it needs a checkout of the server repo and a Go toolchain,
# neither of which the runner has. Run it by hand when the writer, the sender
# or the send client changes.
#
# It writes ONE temporary _test.go into that checkout and removes it again on
# every exit path, and refuses to start if the checkout has uncommitted work,
# so an interrupted run cannot be mistaken for the user's own edits.
#
# Ported from kypost-Linux/scripts/verify-pgp-against-relay.sh, which is the
# same idea against the Qt client.
#
# Usage: verify-pgp-against-relay.sh [path-to-server-repo]

set -euo pipefail

FIXTURE_FROM="decrypt@example.invalid"
FIXTURE_SUBJECT="Café — Redundancies confirmed"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_REPO="${1:-$(cd "$REPO_ROOT/.." && pwd)/KyPost-Server}"
WORK="$(mktemp -d)"
PROBE=""

cleanup() {
    if [ -n "$PROBE" ] && [ -f "$PROBE" ]; then
        rm -f "$PROBE"
        echo "removed the temporary probe from the server checkout"
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

if [ ! -d "$SERVER_REPO/backend/internal/api" ]; then
    echo "no server checkout at $SERVER_REPO -- pass its path as the first argument" >&2
    exit 1
fi

# Refuse to touch a checkout with work in it. This script adds and deletes a
# file there; doing that alongside someone's uncommitted changes is how a
# cleanup step deletes the wrong thing.
if [ -n "$(git -C "$SERVER_REPO" status --porcelain)" ]; then
    echo "$SERVER_REPO has uncommitted changes; refusing to write a probe into it" >&2
    exit 1
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# The app is sandboxed, so the emitter cannot write into a mktemp -d out here;
# it writes to its own container tmp and this reads them back. Derived from the
# bundle id rather than hardcoded so the rename that already happened once does
# not silently point this at an empty directory.
BUNDLE_ID=$(sed -n 's/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER = \([^;]*\);.*/\1/p' \
    "$REPO_ROOT/KyPost.xcodeproj/project.pbxproj" | grep -v '\.tests$\|\.uitests$' | sort -u | head -1)
[ -n "$BUNDLE_ID" ] || { echo "could not read PRODUCT_BUNDLE_IDENTIFIER from project.pbxproj" >&2; exit 1; }
FIXTURES="$HOME/Library/Containers/$BUNDLE_ID/Data/tmp/kypost-relay-fixtures"

echo "emitting this client's wire bytes (container: $BUNDLE_ID)"
# TEST_RUNNER_ prefixed variables reach the test host with the prefix stripped.
# Signing is required: the suite runs inside the host app and the
# data-protection Keychain refuses an unsigned process (see AGENTS.md).
TEST_RUNNER_KYPOST_EMIT_RELAY_FIXTURES=1 xcodebuild test \
    -scheme KyPost \
    -destination 'platform=macOS' \
    -only-testing:"KyPost Tests/PgpRelayFixtureEmitterTests" \
    > "$WORK/xcodebuild.log" 2>&1 \
    || { echo "the fixture emitter failed; last 40 lines:" >&2; tail -40 "$WORK/xcodebuild.log" >&2; exit 1; }

# Copied out of the container so the probe reads a path Go can reach, and so a
# stale container from an earlier run cannot be silently reused.
for f in request.json delivery.eml protected.mime; do
    if [ ! -s "$FIXTURES/$f" ]; then
        echo "the emitter produced no $f in $FIXTURES" >&2
        echo "-- it was skipped or sandboxed out, which means nothing was checked" >&2
        exit 1
    fi
    cp "$FIXTURES/$f" "$WORK/$f"
done
echo "emitted a delivery, a protected content part and a whole send request"

PROBE="$SERVER_REPO/backend/internal/api/zz_kypost_apple_shape_probe_test.go"
cat > "$PROBE" <<GOEOF
package api

// TEMPORARY probe written by kypost-for-Mac/scripts/verify-pgp-against-relay.sh.
// If this file is still here, that script did not finish; delete it.

import (
	"encoding/json"
	"os"
	"strings"
	"testing"

	"kypost-server/backend/internal/mailmsg"
	"kypost-server/backend/internal/pgpmail"
)

func TestKypostAppleDeliveryShape(t *testing.T) {
	raw, err := os.ReadFile("$WORK/delivery.eml")
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if err := validatePGPMimeDeliveryShape(string(raw)); err != nil {
		t.Fatalf("shape rejected: %v", err)
	}
	if err := validatePGPMimeDelivery(string(raw), "$FIXTURE_FROM"); err != nil {
		t.Fatalf("authorized From rejected: %v", err)
	}
	if _, err := mailmsg.PrepareSMTPMessage(raw); err != nil {
		t.Fatalf("SMTP preparation rejected: %v", err)
	}
	// The check discriminates: a From this caller may not use is still refused.
	if err := validatePGPMimeDelivery(string(raw), "someone-else@example.com"); err == nil {
		t.Fatal("an unauthorized From was accepted")
	}
}

// The WHOLE request, through this server's own decoder and its own Sent-copy
// logic -- not just one delivery's MIME. This is the closest thing to sending
// for real that does not need a live relay.
func TestKypostAppleSendRequest(t *testing.T) {
	raw, err := os.ReadFile("$WORK/request.json")
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	var req clientEncryptedSendRequest
	if err := json.Unmarshal(raw, &req); err != nil {
		t.Fatalf("this server cannot decode the request: %v", err)
	}
	if len(req.Deliveries) == 0 {
		t.Fatal("no deliveries survived decoding")
	}
	for i, d := range req.Deliveries {
		if len(d.Recipients) == 0 {
			t.Fatalf("delivery %d has no recipients", i)
		}
		if _, rerr := parseDeliveryRecipients(d.Recipients); rerr != nil {
			t.Fatalf("delivery %d recipients rejected: %v", i, rerr)
		}
		if verr := validatePGPMimeDelivery(strings.TrimSpace(d.Ciphertext), req.From); verr != nil {
			t.Fatalf("delivery %d rejected: %v", i, verr)
		}
	}
	// The blind recipient gets their own delivery, which is why the wire
	// format is a list at all.
	if len(req.Deliveries) < 2 {
		t.Fatalf("expected a separate delivery per blind recipient, got %d", len(req.Deliveries))
	}
	// The real subject never travels outside the ciphertext.
	if req.Subject != pgpmail.OuterPlaceholderSubject {
		t.Fatalf("outer subject is not the placeholder: %q", req.Subject)
	}
	// And the Sent copy is stored, which this server does only when the
	// client asserts it is ciphertext.
	if _, ok := sentCopyDraft(req); !ok {
		t.Fatal("this server would not store the Sent copy this client sent")
	}
}

func TestKypostAppleProtectedSubject(t *testing.T) {
	inner, err := os.ReadFile("$WORK/protected.mime")
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	subject, ok := pgpmail.ExtractProtectedSubject(inner)
	if !ok {
		t.Fatal("no protected subject found")
	}
	if subject != "$FIXTURE_SUBJECT" {
		t.Fatalf("protected subject round-tripped wrong: %q", subject)
	}
}
GOEOF

echo "running the relay's own validators"
( cd "$SERVER_REPO/backend" && go test ./internal/api/ -run TestKypostApple -count=1 -v ) \
    | grep -E "^(=== RUN|--- (PASS|FAIL)|ok|FAIL)" || true

( cd "$SERVER_REPO/backend" && go test ./internal/api/ -run TestKypostApple -count=1 > /dev/null )
echo "the relay decodes this client's send request, accepts every delivery, and would store the Sent copy"
