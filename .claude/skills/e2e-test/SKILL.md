---
name: e2e-test
description: Run E2E browser tests via Tidewave browser_eval against the running Phoenix dev server
argument-hint: "[path] e.g. 'pos/terminal-basic', 'pos/terminal-basic#3', 'all', 'list'"
---

# E2E Browser Test Runner

Run markdown-based E2E browser tests using Tidewave `browser_eval` against the running Phoenix dev server.

## Test Location

All E2E tests live in `docs/e2e/`. Each `.md` file contains numbered scenarios.

## Commands

### Run a test file: `/e2e [path]`

Run all scenarios in a test file. Path is relative to `docs/e2e/`.

```
/e2e pos/terminal-basic          # Run all 10 scenarios
/e2e staff/members-list          # Run all scenarios
/e2e public/checkout-link        # Run all scenarios
```

### Run a specific scenario: `/e2e [path]#[number]`

Run only one scenario from a test file.

```
/e2e pos/terminal-basic#3        # Run only Scenario 3: Product Search
/e2e pos/terminal-basic#8-10     # Run Scenarios 8 through 10
```

### List available tests: `/e2e list`

List all test files with scenario counts and last-verified dates.

### Show summary: `/e2e status`

Show overall test suite status — which tests have been verified, which are pending.

## Execution Workflow

When running tests, follow these steps precisely:

### 1. Read the Test File

Read the `.md` file from `docs/e2e/{path}.md`. Parse the frontmatter for:
- **Route**: Starting URL
- **Auth**: Authentication method needed
- **Persona**: Which E2E persona to use (admin, staff, manager)
- **Prerequisites**: Required seed data or state

### 2. Handle Auth & Persona

Test files specify an **Auth** type and a **Persona**. Use the appropriate method:

| Auth Type | Action |
|-----------|--------|
| `clerk` | Use **Clerk login** (see below) |
| `public (token)` | Generate/use token, navigate directly |
| `pos_device + pos_session` | Check if already on `/pos/` — if redirected to activate/login, handle it |
| `none` | Navigate directly |

#### Clerk Auth

Persona emails use `+clerk_test` subaddress — Clerk verification codes are always `424242`.

```javascript
// 1. Sign out from Clerk JS
await browser.eval(async () => {
  if (window.Clerk) await window.Clerk.signOut();
});
await browser.wait(1000);

// 2. Navigate to sign-in page
await browser.reload('/clerk/sign-in');
await browser.wait(4000); // Wait for Clerk widget to load

// 3. Fill email (use snapshot refs — don't use broad selectors)
// Snapshot → find email textbox ref → fill → click Continue
const snapshot = await browser.snapshot(browser.locator('#clerk-sign-in'));
// Find textbox "Email address" ref from snapshot
await browser.fill(browser.getBySnapshotRef('eXX'), 'e2e-admin+clerk_test@example.com');
// Find "Continue" button ref from snapshot
await browser.click(browser.getBySnapshotRef('eYY'));
await browser.wait(3000);

// 4. Password step — snapshot again, find password textbox + Continue
await browser.fill(browser.getBySnapshotRef('eZZ'), 'E2eTest!2026');
await browser.click(browser.getBySnapshotRef('eWW'));
await browser.wait(4000);

// 5. Client Trust verification — snapshot, find code input + Continue
await browser.fill(browser.getBySnapshotRef('eVV'), '424242');
await browser.click(browser.getBySnapshotRef('eUU'));
await browser.wait(5000);

// 6. Verify redirected away from /clerk/sign-in
```

**IMPORTANT**: The Clerk widget renders dynamic refs — always take a fresh snapshot
before each step. Don't reuse refs from earlier snapshots.

**Available personas** (from `GsNet.E2E.Personas`):

| Key | Email | Password | Tenant Role | Org Role | Interfaces |
|-----|-------|----------|-------------|----------|------------|
| `admin` | `e2e-admin+clerk_test@example.com` | `E2eTest!2026` | owner | executive @ company | admin, hq, staff, customer |
| `staff` | `e2e-staff+clerk_test@example.com` | `E2eTest!2026` | member | staff @ center | staff, customer |
| `manager` | `e2e-manager+clerk_test@example.com` | `E2eTest!2026` | member | center_manager @ center | staff, customer |
| `customer` | `e2e-customer+clerk_test@example.com` | `E2eTest!2026` | member | — (no org role) | customer |
| `hq` | `e2e-hq+clerk_test@example.com` | `E2eTest!2026` | member | director @ division | hq, staff, customer |
| `affiliate` | `e2e-affiliate+clerk_test@example.com` | `E2eTest!2026` | member | — (no org role) | affiliate, customer |
| `hr_manager` | `e2e-hr+clerk_test@example.com` | `E2eTest!2026` | member | director @ HR Team | hq, staff, customer |

Provisioned by `mix gs_net.e2e_setup` (creates Clerk accounts + GsNet records).

#### Clerk Sign-Out (for auth tests)

To fully sign out both Clerk JS and Phoenix session:

```javascript
// 1. Sign out from Clerk JS
await browser.eval(async () => {
  if (window.Clerk) await window.Clerk.signOut();
});
await browser.wait(1000);

// 2. Clear Phoenix session
await browser.reload('/clerk/session-destroy');
await browser.wait(500);
```

### 3. Execute Each Scenario

For each scenario (or the selected subset):

1. **Announce**: Print `## Scenario N: [Name]` header
2. **Execute steps** sequentially, using the step-to-Tidewave mapping below
3. **Report result**: Pass or Fail with details
4. **On failure**: Log the snapshot at failure point, note what was expected vs actual, then continue to next scenario (don't stop the suite)

### 4. Report Results

After all scenarios complete, print a summary table:

```
## Results: pos/terminal-basic

| # | Scenario | Result | Notes |
|---|----------|--------|-------|
| 1 | Product Grid Loads | PASS | |
| 2 | Category Filtering | PASS | |
| 3 | Product Search | FAIL | Search input not found |
...

Total: 8/10 passed
```

### 5. Update Last Verified

If ALL scenarios pass, update the test file's `Last Verified` date to today.

## Step Language → Tidewave Mapping

Use these exact patterns to translate markdown steps into `browser_eval` calls:

| Step | Tidewave |
|------|----------|
| Navigate to `/path` | `browser.reload("/path")` |
| Snapshot [element] | `console.log(await browser.snapshot(browser.locator('selector')))` |
| Snapshot page | `console.log(await browser.snapshot(browser.locator('body')))` |
| Verify [element] visible with text "[text]" | Snapshot → check output contains text |
| Verify [element] exists | Snapshot → check element appears in tree |
| Click [button with text] | `await browser.click(browser.locator('button', { hasText: 'text' }))` |
| Click [link with text] | `await browser.click(browser.locator('a', { hasText: 'text' }))` |
| Click [element by ref] | `await browser.click(browser.getBySnapshotRef('eXX'))` |
| Fill "[field name]" with "[value]" | `await browser.fill(browser.locator('input[name="field"]'), "value")` |
| Fill [placeholder text] with "[value]" | `await browser.fill(browser.locator('input[placeholder="text"]'), "value")` |
| Wait [N] ms | `await browser.wait(N)` |
| Select "[option]" from "[select]" | Use `browser.eval` with dispatchEvent |
| Sign out from Clerk | `await browser.eval(async () => { if (window.Clerk) await window.Clerk.signOut(); })` |
| Fill verification code | `await browser.fill(codeInputRef, '424242')` |

## Snapshot-First Approach (CRITICAL)

**Always prefer snapshots over DOM scripting:**

1. Take a snapshot of the relevant section
2. Read the snapshot to find element refs (`eXX`)
3. Use `browser.getBySnapshotRef('eXX')` to interact with found elements
4. Use `browser.click()` and `browser.fill()` over `browser.eval()` where possible

This avoids brittle CSS selectors and matches how the test files describe elements (by text/role, not by class).

**Clerk widget note**: The Clerk sign-in widget re-renders between steps (email → password → verification). Always take a **fresh snapshot** after each transition — refs from previous steps will be stale.

## Error Handling

- **Element not found**: Wait 2 seconds, retry once. If still not found, mark FAIL.
- **Navigation redirect**: Note the redirect, check if it's auth-related. Handle auth if so.
- **LiveView patch**: After clicks that trigger LiveView events, wait 500ms for patch to complete before snapshotting.
- **Modal/dialog**: After triggering a modal, wait 300ms, then snapshot the modal specifically.
- **Clerk widget loading**: Wait 3-4 seconds after navigating to `/clerk/sign-in` for the widget to mount.
- **Clerk step transitions**: Wait 3-4 seconds between Clerk steps (email→password→verification) for the widget to re-render.

## Directory Structure Convention

Test files mirror the app's route structure:

```
docs/e2e/
├── README.md                        # This guide
│
├── auth/                            # Authentication flows
│   ├── clerk-login.md               # 6 scenarios — Clerk SSO login/logout
│   └── pos-device-auth.md           # 6 scenarios — POS device activation + PIN
│
├── pos/                             # POS terminal (/pos/*)
│   ├── terminal-basic.md            # 10 scenarios — product grid, cart, payment
│   └── terminal-membership.md       # 5 scenarios — membership + agreement signing
│
├── staff/                           # Staff portal (/staff/*)
│   ├── members-list.md              # 10 scenarios — Cinder table, search, filter
│   ├── dashboard.md                 # 4 scenarios — staff landing, navigation
│   └── member-detail.md             # 6 scenarios — member view, transfers, status
│
├── public/                          # Public pages (no auth)
│   └── checkout-link.md             # 10 scenarios — review → payment → sign → confirm
│
├── admin/                           # Admin console (/admin/*)
│   ├── catalog-management.md        # 8 scenarios — product CRUD, pricing, publishing
│   ├── organization.md              # 5 scenarios — org tree view, edit units
│   ├── users-invites.md             # 6 scenarios — user list, invite code CRUD
│   └── events-roster.md             # 6 scenarios — roster, attendance, enrollment
│
├── customer/                        # Customer portal (/my/*)
│   ├── workshop-catalog.md          # 5 scenarios — browse, filter, enroll
│   └── events.md                    # 5 scenarios — my events, deferred registration
│
└── hq/                              # HQ dashboard (/hq/*) — future
```

### Naming Conventions

- **File names**: `kebab-case.md`, match the feature/page name
- **No nesting beyond one level**: `pos/terminal-basic.md`, NOT `pos/terminal/basic.md`
- **Group by app section**, not by test type (no separate `smoke/`, `regression/` folders)

### Test File Header Template

Every test file MUST have this frontmatter:

```markdown
# E2E: [Page/Feature Name]

> **Route**: /path/to/page
> **Auth**: clerk | pos_device | pos_session | public (token) | none
> **Persona**: admin | staff | manager
> **Prerequisites**: [what must be true before tests run]
> **Last Verified**: YYYY-MM-DD | —
```

### Adding New Tests

When creating a new E2E test file:

1. Determine the correct subdirectory from the route structure above
2. Use the header template
3. Number scenarios sequentially: `### Scenario 1:`, `### Scenario 2:`, etc.
4. Write steps in natural language using the step vocabulary above
5. Include `**Expected**:` after each scenario's steps
6. Separate scenarios with `---` horizontal rules

## Quick Reference

```
/e2e list                    # Show all test files
/e2e status                  # Overall pass/fail status
/e2e pos/terminal-basic      # Run all scenarios in file
/e2e pos/terminal-basic#3    # Run one scenario
/e2e pos/terminal-basic#8-10 # Run scenario range
```

## Clerk Test Email Quick Reference

| Concept | Value |
|---------|-------|
| Test email suffix | `+clerk_test` (e.g., `user+clerk_test@example.com`) |
| Verification code | `424242` (always, no email sent) |
| Password (all personas) | `E2eTest!2026` |
| Provisioning | `mix gs_net.e2e_setup` |
| Clerk docs | https://clerk.com/docs/guides/development/testing/test-emails-and-phones |
