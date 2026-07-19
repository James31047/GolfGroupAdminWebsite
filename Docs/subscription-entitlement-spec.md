# Subscription & Entitlement Architecture — Golf Group Admin (v1.0, 2026-07-19)

Covers both projects: the **.NET MAUI application** (iOS, iPadOS, Android, Windows, macOS)
and the **Umbraco web site**. Defines how a subscription purchased on the web unlocks paid
features in the mobile/desktop app, and how the system stays store-compliant and extensible
to in-app purchase later.

## 1. Goals

- The **group organizer pays** a subscription (per the rough-features pricing notes:
  tablet/admin ≈ $99/yr) that unlocks group-management features for their group.
- **Authenticated members ride free**: signing in on a phone/tablet grants the basic
  member feature set at no charge.
- Certain **premium mobile features** require a subscription (either covered by the
  group's plan or by a future individual upgrade — see §5).
- One purchase, every platform: entitlements are **account-based, not device-based**.
  Buying on the web unlocks iOS, Android, Windows, and macOS immediately.
- No store commission in v1: all billing happens on the web via Stripe. The design keeps
  a clean seam for adding Apple/Google IAP in v2 (undecided today — see §11).

## 2. System components

| Component | Role |
|---|---|
| **Golf Group Admin API** (ASP.NET Core, MS SQL) | System of record: members, groups, rounds, scores, **identity, subscriptions, entitlements**. Issues JWTs. Receives Stripe webhooks. |
| **Umbraco web site** | Marketing/content pages plus the **account & billing portal**: register, sign in, subscribe (Stripe Checkout), manage subscription (Stripe Customer Portal). Calls the API server-side. |
| **MAUI app** | Signs in against the API, syncs entitlements, gates features locally, caches to SQLite (sqlite-net-pcl) for offline rounds. |
| **Stripe** | Checkout, recurring billing, invoicing, Customer Portal. Truth about *payments*; the API is truth about *entitlements*. |

The API can be hosted as a separate site or as an area within the Umbraco application
(Umbraco is ASP.NET Core, so both can share one deployment). Recommended: **separate API
project** in the same solution, deployed alongside Umbraco, sharing the MS SQL server.
This keeps Umbraco upgrades from entangling the API and lets the MAUI app talk to a
stable, versioned endpoint (`api.golfgroupadmin.com` or `/api/v1/...`).

## 3. Identity & authentication

**ASP.NET Core Identity in the API database** is the single identity store. Umbraco's
built-in Members system is *not* used for app users — one account store, no sync problems.

- **MAUI app**: username/password (email) login → API issues a short-lived **JWT access
  token** (~15 min) plus a long-lived **refresh token** (~90 days, rotating, revocable).
  Tokens stored in `SecureStorage`. Silent refresh on app start; user stays signed in
  for months, matching golfer expectations.
- **Umbraco site**: account pages sign the user in against the same Identity store
  (cookie auth). Umbraco surface pages/controllers call Identity's `SignInManager`
  directly since they share the database, or call the API if deployed separately.
- **Roles/claims**: `Member`, `GroupAdmin` (per group), `SysAdmin`. Group-scoped
  authorization uses a `GroupMembership` table, not global roles.
- Password reset and email confirmation flow through the Umbraco site (it owns the
  user-facing pages); the API sends the tokens/emails.

## 4. Plans

| Plan | Buyer | Billed | Unlocks |
|---|---|---|---|
| **Group** (~$99/yr, price TBD) | Group organizer | Stripe, annual (monthly optional) | All group-management/admin features (web + tablet/desktop app) for that group; premium member features for **every member of that group** |
| **Free member** | — | — | Basic mobile features for any authenticated user in a group |
| **Individual Premium** (v-next, optional) | Any member | Stripe (or IAP later) | Premium personal features regardless of group plan — placeholder in the model, not built in v1 |

Trials: 30-day free trial on the Group plan via Stripe's built-in trial support —
no separate code path; the webhook flow below handles `trialing` like `active`.

## 5. Entitlement model

Entitlements are **computed grants**, derived from subscriptions but stored/served
separately so clients never need to understand billing.

Feature gates (enum `Feature`): examples mapped from the rough-features list —

- `GroupAdmin.*` — match setup, team picking, payouts/prize fund, dues tracker,
  money list reports, association setup *(requires active Group plan on that group)*
- `Member.Basic` — daily signup, view teams/results, enter/upload scores, view own
  scorecards *(any authenticated member — free)*
- `Member.Premium` — power ranking & advanced stats, side bets, scorecard photo
  capture, GHIN auto-post *(member of a group with an active Group plan, or
  Individual Premium)*

The exact feature-to-tier mapping is a product decision that will move around; it lives
in a single server-side table (`FeatureGate`) so re-tiering never requires an app release.

**Resolution rule (server-side):**
`user.Entitlements = Member.Basic ∪ (Member.Premium if any of user's groups has an active Group subscription or user has Individual Premium) ∪ (GroupAdmin[g] for each group g the user administers that has an active Group subscription)`

## 6. Billing flow (web, Stripe)

1. Organizer registers / signs in on the Umbraco site and clicks **Subscribe** on their
   group's page.
2. Server creates a **Stripe Checkout Session** (`mode=subscription`), passing
   `client_reference_id = userId` and `metadata.groupId`.
3. On completion Stripe redirects back to Umbraco; the authoritative update comes from
   **webhooks to the API** (never trust the redirect):
   - `checkout.session.completed` → create `Subscription` row, link StripeCustomerId
   - `customer.subscription.updated` → update status/period end (renewals, trial→active, past_due)
   - `customer.subscription.deleted` → mark canceled
   - `invoice.payment_failed` → status `past_due` (Stripe Smart Retries handles dunning)
4. Webhook handler is **idempotent** (store processed event IDs) and verifies the
   Stripe signature.
5. **Manage billing** button → Stripe Customer Portal (card updates, cancel, invoices) —
   no custom billing UI to build or maintain.
6. Grace period: subscription grants entitlements until `CurrentPeriodEnd + 7 days`
   so a failed card doesn't lock out a group mid-league-day.

## 7. Mobile entitlement sync (MAUI)

- `GET /api/v1/me/entitlements` returns:

```json
{
  "features": ["Member.Basic", "Member.Premium", "GroupAdmin"],
  "groups": [{ "groupId": 12, "plan": "Group", "status": "active", "isAdmin": true }],
  "expiresAt": "2027-03-01T00:00:00Z",
  "refreshAfter": "2026-07-20T12:00:00Z"
}
```

- App fetches on login, on app resume, and after `refreshAfter`; caches the response in
  SQLite/`Preferences` with the fetch timestamp.
- **Offline grace: 7 days.** Within grace, cached entitlements apply (a golfer with no
  signal on the course keeps premium features). Past grace, premium features degrade to
  free tier with a "reconnect to restore" message; basic scoring **never** goes offline-dead.
- Single gate in shared code: `IEntitlementService.Has(Feature f, int? groupId = null)`.
  All feature checks go through it — UI (menu visibility), navigation guards, and the
  API repeats the check server-side (client checks are UX, server checks are security).
- Server-side enforcement: API endpoints carry `[RequiresFeature(...)]` authorization
  attributes resolving against the same entitlement service.

## 8. Store compliance (Apple / Google)

- Unlocking features via sign-in for a subscription purchased elsewhere is permitted
  (Apple guideline 3.1.3(b), multiplatform services; Google equivalent).
- v1 apps contain **no purchase UI, no pricing, and (outside the US) no link to the
  website checkout**. Wording in-app: "Premium features are enabled by your group's
  subscription. Ask your group organizer." A US-only storefront may legally show an
  external purchase link post-*Epic*, but simplest v1 posture is none anywhere.
- Windows/macOS distributed outside stores (or Microsoft Store, which permits own
  commerce) have no such restrictions — the desktop app may link straight to billing pages.

## 9. Data model additions (MS SQL)

```
AspNet* tables                    -- ASP.NET Core Identity (users, roles, tokens)
RefreshToken (Id, UserId, TokenHash, ExpiresAt, RevokedAt, ReplacedById)
StripeCustomer (UserId PK, StripeCustomerId UNIQUE)
Subscription (Id, GroupId NULL, UserId, Plan, StripeSubscriptionId,
              Status, CurrentPeriodEnd, CanceledAt, CreatedAt)
              -- GroupId set for Group plan; NULL+UserId for Individual Premium
ProcessedStripeEvent (EventId PK, ProcessedAt)      -- webhook idempotency
FeatureGate (Feature PK, RequiredTier)               -- feature → Free|GroupPlan|IndividualPremium
GroupMembership (GroupId, UserId, Role)              -- existing concept; drives resolution
```

Entitlements are computed at request time from `Subscription` + `GroupMembership` +
`FeatureGate` (cheap joins, cacheable in-memory ~60s); no denormalized entitlement table
to drift.

## 10. API surface (v1)

```
POST /api/v1/auth/register | login | refresh | logout
POST /api/v1/auth/forgot-password | reset-password
GET  /api/v1/me/entitlements
POST /api/v1/billing/checkout-session      (web only; creates Stripe Checkout)
POST /api/v1/billing/portal-session        (web only; Stripe Customer Portal)
POST /api/v1/webhooks/stripe               (Stripe only; signature-verified)
```

Everything else (groups, rounds, scores, rankings) is the existing/planned domain API,
now decorated with `[RequiresFeature]` where a gate applies.

## 11. Phasing

**Phase 1 (v1):** Identity + JWT auth in API; Stripe Checkout/Portal/webhooks; Group
plan only; entitlement endpoint + MAUI gating with offline grace; Umbraco account &
billing pages. *No IAP.*

**Phase 2 (only if store conversion matters):** Add Apple/Google IAP via RevenueCat
(`Maui.RevenueCat.InAppBilling`) for **Individual Premium** on phones. RevenueCat
webhooks feed the same `Subscription` table (`Plan = IndividualPremium`,
`Source = AppStore|PlayStore|Stripe`), so §5 resolution and the app's gating logic are
untouched. The Group plan stays web-only (organizers subscribe at a desk; avoids 15%
commission on the main revenue line).

**Decision deferred intentionally:** whether Phase 2 happens at all. The entitlement
seam (§5) is the insurance; nothing in v1 blocks it.

## 12. Open questions

1. Final feature-to-tier mapping (which rough-features items are `Member.Premium` vs
   `Member.Basic`) — start conservative: free tier generous, premium = stats/rankings,
   side bets, GHIN posting, photo capture.
2. Group plan pricing/tiers — flat ~$99/yr vs. tiered by member count.
3. Registration-number/transfer idea from the rough notes — superseded by account-based
   entitlements? (Recommend yes; a "transfer group ownership" admin action covers it.)
4. Monthly billing option and founding-member discounts (Stripe coupons cover both).
