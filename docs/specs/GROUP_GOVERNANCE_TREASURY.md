# Micro Fams V1 Group Governance and Treasury Specification

Status: approved. GT-01 through GT-12 were approved by the product owner on
2026-07-30.

## Purpose

This specification defines the Version 1 rules for groups, memberships, governance,
contributions, treasury, projects, committees, meetings, documents, and shared
assets. It keeps the useful journeys in the existing `.kiro` group specifications
while aligning them with the approved multi-tenant and FC-01 through FC-08
financial architecture.

No group money workflow may be implemented from this proposal until GT-01 through
GT-12 are approved. Non-financial records may be built only where their behaviour
is unambiguous and does not pre-empt a proposed decision.

## Authority and conflict resolution

After approval, this specification supersedes conflicting group behaviour in:

- `.kiro/specs/group-individual-wallet-system/`;
- `.kiro/specs/platform-profile-and-groups-enhancement/`;
- legacy group, consensus, contribution, and wallet migrations; and
- current controllers or services that treat checked task boxes as evidence.

The approved `FINANCIAL_CORE.md`, `MULTITENANCY.md`, and `FEATURE_FLAGS.md`
specifications remain authoritative. In particular:

- money is integer minor units with an ISO currency;
- posted balanced journals are the financial source of truth;
- `wallet_transactions`, `user_wallets.balance`, and
  `groups.group_fund_balance` are legacy evidence or derived caches;
- every group-owned record belongs to one organization;
- provider, regulated, and staged workflows are backend-feature-flagged; and
- provider callbacks and existing-obligation servicing remain available when new
  exposure is disabled.

## Definitions

- **Organization**: the tenant, security, reporting, configuration, and accounting
  boundary.
- **Group**: a governed collaboration inside one organization. A group is not a
  separate tenant in Version 1.
- **Constitution version**: the effective-dated rules controlling membership,
  quorum, votes, offices, contributions, and treasury approvals.
- **Voting snapshot**: the immutable set of eligible voters and threshold inputs
  captured when a proposal opens.
- **Contribution**: a classified payment or internal allocation to a group. Its
  economic ownership depends on its contribution type.
- **Treasury account**: a group-owned ledger account or group subledger account
  under the organization chart of accounts.
- **Restricted fund**: money limited to a disclosed project or purpose.
- **Maker-checker**: a rule under which the actor proposing or executing a
  sensitive command cannot be its final approver.

## GT-01 — Tenant boundary and group lifecycle

1. Every group MUST carry `organization_id`; every membership, office, proposal,
   vote, meeting, committee, contribution, project, document, asset, approval,
   treasury record, job, export, and audit event MUST inherit and verify it.
2. Group identifiers are not authorization. Reads and writes MUST require verified
   tenant context and resource permission.
3. A user MAY belong to multiple groups, including groups in different
   organizations. Membership and permissions are isolated per group and tenant.
4. Group states are `draft`, `active`, `suspended`, `closing`, and `closed`.
   Activation requires an approved constitution version and at least the minimum
   offices required by that constitution.
5. Suspension blocks new membership, contributions, projects, and disbursement
   proposals but preserves statements, refunds, appeals, provider callbacks,
   reconciliation, and servicing of existing obligations.
6. Closing is a controlled workflow with liability settlement, restricted-fund
   disposition, document retention, asset disposition, final accounts, and
   approval. It MUST NOT cascade-delete financial or governance evidence.
7. Public discovery MUST use a deliberate projection. Member rosters, finances,
   meeting records, and documents are private unless an authorized publication
   decision says otherwise.

## GT-02 — Membership, offices, invitations, and exits

1. Membership states are `invited`, `applicant`, `pending_payment`, `active`,
   `suspended`, `exiting`, `exited`, and `expelled`.
2. Invitation tokens MUST be hashed, single-use, expiring, revocable, and bound to
   the intended organization and group.
3. Entry requirements, fees, identity tier, eligibility evidence, approval route,
   and capacity limit MUST be versioned. A provider payment reference MUST NOT be
   accepted as proof without verified amount, currency, tenant, payer, and
   idempotency.
4. Membership roles and offices are group-scoped. Default offices are chair,
   secretary, and treasurer; organizations MAY define additional offices through
   a constitution version.
5. Office appointment, term, vacancy, temporary delegation, removal, and conflict
   rules MUST be explicit. A global platform role does not silently confer a group
   office.
6. A member MUST NOT vote on their own admission, discipline, expulsion, benefit,
   reimbursement, contract award, or other direct conflict.
7. Suspension and expulsion require notice, a reason code, evidence references,
   an independent decision path, and an appeal window. They MUST NOT erase earned
   rights, debts, statements, or audit evidence.
8. Exit settlement MUST classify every amount by economic ownership and lawful
   obligation. Remaining personal funds MUST NOT be transferred to a “primary
   group” or treated as group income merely because a grace period expired.
9. Unclaimed personal amounts move to a tenant suspense/unclaimed-funds liability
   with owner linkage and applicable retention/escheat metadata pending an
   approved legal process.

## GT-03 — Constitution, proposals, voting, and decisions

1. A constitution is immutable after activation. Amendments create a new
   effective-dated version through a proposal.
2. Proposal types include constitution amendment, membership action, office
   appointment/removal, treasury disbursement, contribution rule, project,
   committee mandate, shared-asset action, document publication, and group
   closure.
3. Each proposal MUST record tenant, group, type, proposer, constitution/rule
   version, public summary, private evidence references, open/close times,
   voting snapshot, quorum, approval threshold, conflict exclusions, state,
   result, and audit correlation.
4. Proposal states are `draft`, `open`, `approved`, `rejected`, `expired`,
   `cancelled`, `executing`, `executed`, and `execution_failed`. State transitions
   are monotonic except a separately approved retry from `execution_failed`.
5. Eligible voters are snapshotted at opening. Later membership changes MUST NOT
   manipulate that proposal’s denominator.
6. Every voter has at most one final vote of `approve`, `reject`, or `abstain`.
   Whether a vote may be changed before close is constitution-configurable and
   must retain append-only vote history.
7. Proposed Version 1 defaults are:
   - ordinary decisions: quorum of 50% of eligible voters and more approvals than
     rejections among non-abstaining votes;
   - constitution changes and group closure: quorum of two thirds and approval by
     two thirds of eligible voters;
   - suspension or expulsion: quorum of two thirds and approval by two thirds of
     eligible non-conflicted voters; and
   - treasury decisions: GT-06 applies.
8. Thresholds use integer ceiling and are stored on the voting snapshot.
9. Approval does not directly mutate unrelated domain rows. An idempotent
   execution command applies the approved decision and records success or failure.

## GT-04 — Contribution classification and ownership

1. Every contribution product MUST be classified before collection as one of:
   - `membership_fee`: group income when earned under a disclosed rule;
   - `periodic_due`: group income for governance or operating costs;
   - `member_capital`: member-attributed equity subject to approved withdrawal and
     loss-allocation rules;
   - `project_subscription`: restricted funding for a named project with disclosed
     refund/disposition rules; or
   - `savings`: a separately approved savings product and not a group contribution
     shortcut.
2. The contribution type, amount, currency, payer eligibility, due dates,
   permitted payment rails, ownership, refund rule, late rule, purpose, and
   accounting mapping MUST be versioned and disclosed before commitment.
3. A generic “group fund balance” MUST NOT imply that all contributions are
   interchangeable or withdrawable by members.
4. Contribution rules MUST NOT be changed retroactively for an existing cycle.
5. Penalties and discounts require an approved effective-dated rule, reason,
   calculation basis, cap, grace period, waiver permission, and journal mapping.
   Penalties MUST NOT be silently netted from personal funds.
6. Contributions through Paystack, Interswitch, bank transfer, cash evidence, or
   internal wallet allocation use provider-neutral payment commands and the same
   confirmation and reconciliation requirements.
7. Payment confirmation and the contribution allocation MUST be idempotent and
   atomically linked to the resulting journal.

## GT-05 — Contribution cycles

1. A cycle records one immutable contribution-rule version, period, timezone,
   member eligibility snapshot, expected amount by member, due date, grace end,
   currency, state, and audit correlation.
2. Cycle states are `draft`, `open`, `grace`, `closing`, `closed`, and `cancelled`.
3. Only one open or grace cycle may exist for the same group and contribution
   product unless the constitution explicitly permits overlapping products.
4. Member obligations are generated from the opening snapshot and may be adjusted
   only by an authorized, evidenced command that preserves the original amount and
   reason.
5. Partial and excess payments are supported. Excess value MUST follow a disclosed
   allocation or refund rule and MUST NOT silently become income.
6. Cycle close requires payment/reconciliation completion, exception reporting,
   and accounting-period compatibility. Closed-cycle financial records are
   immutable.
7. Dashboards MUST distinguish expected, received, pending, overdue, waived,
   refunded, and unreconciled amounts and derive money from posted journals.

## GT-06 — Treasury budgets, reservations, and disbursements

1. A treasury command MUST identify a budget or approved purpose, beneficiary,
   amount in minor units, currency, requested execution window, evidence,
   constitution/rule version, and idempotency key.
2. Approval reserves available funds atomically. Voting alone MUST NOT debit a
   mutable group balance or mark an external payment successful.
3. Proposed Version 1 default: a treasury disbursement requires:
   - quorum of two thirds of eligible voters;
   - approval by two thirds of eligible non-conflicted voters;
   - a final checker holding `group.treasury.approve`;
   - at least two distinct approving actors; and
   - separation between proposer, final checker, and any beneficiary.
4. A constitution MAY define lower thresholds for disclosed low-value bands, but
   no disbursement may be self-approved and regulated/live controls may impose
   stronger requirements.
5. Approval snapshots the available balance and applicable financial rule.
   Execution revalidates permission, flags, holds, beneficiary, rule version,
   period, and current available balance.
6. Internal disbursements post balanced journals between group and recipient
   liabilities. External disbursements reserve group funds, create a provider-
   neutral payout, and follow FC-05/FC-06 states, callbacks, reversals, and
   reconciliation.
7. Provider timeout remains recoverable. Failure releases or reverses the
   reservation exactly once. Late success enters reconciliation and MUST NOT
   create duplicate value.
8. Emergency expenditure follows a separately configured policy with a capped
   amount, minimum two-person approval, mandatory reason/evidence, prompt member
   notice, and ratification proposal. It is disabled by default.

## GT-07 — Treasury accounting and statements

1. Each group is an account owner under the organization ledger. Required account
   purposes include group wallet funds, restricted project funds, member capital,
   contributions receivable where applicable, pending payout, income by
   contribution type, expense by purpose, and due-to/due-from clearing where
   needed.
2. Posted journals are authoritative. Group and member dashboard balances are
   rebuildable projections from financial accounts and reservations.
3. Group money MUST NOT cross organizations inside one journal. Cross-tenant
   transfers use linked clearing entries with a correlation identifier.
4. Group statements include opening balance, posted movements, reservations,
   available balance, contribution classification, restricted/unrestricted funds,
   and closing balance by currency.
5. Members see their own contribution and attributable-capital detail. Other
   members’ private financial detail is not exposed merely because they share a
   group.
6. Treasurer, authorized finance roles, and auditors receive permission-bounded
   reports. Exports are tenant-scoped, reproducible at a cutoff, formula-injection
   safe, and audited.
7. Corrections use reversals and corrected postings. Direct edits to posted
   journals, financial projections, or legacy balance caches are forbidden.

## GT-08 — Projects and restricted funds

1. A project belongs to one group and organization and records purpose, owner,
   dates, milestones, budget version, funding sources, restricted-fund rules,
   responsible committee, state, and outcome measures.
2. Project states are `draft`, `proposed`, `approved`, `active`, `paused`,
   `completed`, `cancelled`, and `closed`.
3. Project approval creates no money. Funding and expenditure use GT-04 through
   GT-07 and preserve source restrictions.
4. Budget changes retain versions and require the configured approval threshold.
   Expenditure MUST NOT exceed available approved budget without an approved
   amendment.
5. Completion records deliverables, evidence, residual-fund disposition, assets
   created or acquired, and final financial reconciliation.

## GT-09 — Committees and meetings

1. A committee records mandate, term, members, chair, delegated permissions,
   spending ceiling, reporting duties, and state. Delegation cannot exceed the
   group’s own permissions or bypass maker-checker controls.
2. Committee membership and office history are effective-dated and auditable.
3. A meeting records type, notice time, agenda, eligible attendees, attendance,
   quorum, minutes, resolutions, linked proposals/actions, and approval status.
4. Meeting notices and agenda changes follow constitution lead times. Emergency
   meetings require an explicit reason and cannot silently weaken financial
   approval requirements.
5. Draft minutes may be corrected; approved minutes are immutable and corrections
   use an addendum linked to the original.
6. Attendance alone is not a financial approval. Votes and decisions use GT-03
   even when cast during a meeting.

## GT-10 — Documents and shared assets

1. Group documents carry tenant, group, classification, owner, version, checksum,
   storage key, access policy, retention class, legal-hold status, and audit data.
2. Storage paths and signed URLs MUST be tenant-scoped. Sensitive evidence is
   private by default and downloads are permission-checked and audited.
3. Approved constitutions, minutes, contracts, financial reports, and decision
   evidence are versioned and immutable; corrections create a new linked version.
4. A shared asset records category, acquisition source, custodian, location,
   condition, availability, valuation/depreciation metadata, maintenance schedule,
   evidence, and lifecycle state.
5. Asset booking prevents overlapping confirmed reservations. Check-out,
   check-in, damage, maintenance, disposal, and loss events are auditable.
6. Asset accounting events use approved journal mappings. Operational valuation
   metadata MUST NOT independently change the general ledger.
7. Disposal or transfer requires the configured governance and treasury approval,
   conflict checks, evidence, and any required accounting/reconciliation.

## GT-11 — Providers, flags, permissions, and notifications

1. Group and contribution journeys are backend-gated with:
   - `groups.membership.manage`;
   - `groups.governance.manage`;
   - `groups.contributions.accept_new`;
   - `groups.contributions.service_existing`;
   - `groups.treasury.create_disbursement`;
   - `groups.treasury.service_existing`; and
   - `groups.assets.manage`.
2. Financial commands also require the applicable `financial.wallets`,
   `financial.payments`, `financial.payouts`, and `financial.accounting` flags.
3. New-exposure flags fail closed. Reads, statements, callbacks, reconciliation,
   refunds, reversals, exits, and lawful existing-obligation servicing follow the
   approved fail-open policy.
4. Virtual account provisioning is asynchronous and provider-neutral. Group
   creation MUST succeed without a live provider; provisioning begins only when
   the feature flag, provider configuration, compliance evidence, and approval
   metadata are valid.
5. One active virtual account per provider, environment, currency, and group is
   idempotently enforced. Replacement requires controlled closure and
   reconciliation, not silent reassignment.
6. Permissions include separate membership, proposal, vote, office, contribution,
   treasury maker, treasury checker, report, document, meeting, committee,
   project, asset, and audit capabilities.
7. Durable tenant-aware notifications cover invitations, contribution due/paid/
   failed, proposals, votes, decisions, meetings, treasury states, project
   milestones, member discipline/appeal, and asset events.
8. Notification failure MUST NOT roll back a committed governance or financial
   state. Delivery uses an outbox with idempotency, retry, dead-letter evidence,
   and privacy-minimized payloads.

## GT-12 — Migration, testing, observability, and recovery

1. Migration MUST inventory and classify every legacy group, membership,
   contribution, consensus request, approval, virtual account, wallet transaction,
   project-like record, and balance by organization.
2. Ambiguous tenant ownership, duplicate payment/provider references, invalid
   memberships, unbalanced financial evidence, and unclassified contributions are
   quarantined. They MUST NOT be silently activated or posted.
3. Legacy balances migrate through FC-08 opening journals and signed control
   totals. Legacy transaction rows remain immutable evidence linked where
   trustworthy.
4. The legacy `process_group_fund_payment` and direct balance mutations MUST be
   disabled at cutover and removed only after compatibility consumers migrate.
5. Migration supports dry run, repeatability, pre/post counts and value totals,
   exception reports, read-only cutover, rollback before activation, and
   reconciliation to zero unexplained variance.
6. Required automated evidence includes:
   - unit and property tests for thresholds, snapshots, conflicts, contribution
     ownership, money conservation, transitions, and permissions;
   - database integration tests for tenant isolation, immutable decisions,
     concurrent votes, reservations, postings, reversals, jobs, and outboxes;
   - API tests for authentication, forged tenants, wrong roles, flags,
     idempotency, masking, rate limits, and provider degradation;
   - frontend component tests for disabled, pending, conflict, quorum, degraded,
     accessibility, and privacy states;
   - E2E tests for join/exit, contribution cycle, proposal/vote/execution,
     treasury disbursement, meeting/minutes, project close, and asset custody;
   - reconciliation and clean/legacy migration tests; and
   - security, performance, recovery, and audit-completeness tests.
7. Metrics include proposal aging, execution failures, contribution exceptions,
   reservation aging, payout/reconciliation exceptions, provider health,
   dead-letter notifications, and cross-tenant denial counts without exposing
   personal or financial details.
8. Runbooks cover provider outage, duplicate/late callbacks, failed proposal
   execution, disputed votes, unauthorized access, member exit, group closure,
   data recovery, and financial reconciliation.

## Required implementation sequence after approval

1. Group tenant/permission and lifecycle foundation plus legacy quarantine.
2. Constitution, membership, offices, proposals, voting snapshots, and appeals.
3. Committees, meetings, versioned documents, and notifications.
4. Contribution products/cycles and their approved ledger mappings.
5. Treasury budgets, reservations, approvals, payouts, and reconciliation.
6. Projects, restricted funds, shared assets, and operational dashboards.
7. Full migration, E2E, security, performance, and recovery evidence.

Each step is a separate incremental draft PR and preserves existing servicing
until the replacement path is verified.

## Approval record

The product owner must approve or amend every proposed decision:

| Decision | Recommendation | Status |
| --- | --- | --- |
| GT-01 | Groups are tenant-contained governed subentities; users may join multiple groups | Approved |
| GT-02 | Versioned memberships/offices, due process, no automatic transfer of personal funds | Approved |
| GT-03 | Immutable voting snapshots and decision-specific quorum/threshold defaults | Approved |
| GT-04 | Contributions are classified by economic ownership before collection | Approved |
| GT-05 | Versioned contribution cycles with partial/excess/penalty and close rules | Approved |
| GT-06 | Reserved funds, two-person maker-checker, and two-thirds default treasury approval | Approved |
| GT-07 | Journal-derived group accounts, statements, privacy, and reversal-only corrections | Approved |
| GT-08 | Versioned projects, budgets, restricted funds, milestones, and close | Approved |
| GT-09 | Effective-dated committees and quorum-backed immutable meeting decisions | Approved |
| GT-10 | Versioned documents and auditable shared-asset custody/lifecycle | Approved |
| GT-11 | Backend flags, provider-neutral virtual accounts, permissions, and durable notifications | Approved |
| GT-12 | Quarantined FC-08 migration plus complete test, observability, and recovery evidence | Approved |

Approval status: `approved`

Approved by: Product owner (recorded from the Codex task)

Approval date: 2026-07-30

Approved exceptions: _none recorded_
