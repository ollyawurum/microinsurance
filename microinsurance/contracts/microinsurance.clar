;; Micro Insurance - Decentralized Peer-to-Peer Coverage Platform
;; Community-driven insurance pools with democratic claim approval

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u700))
(define-constant err-not-authorized (err u701))
(define-constant err-pool-not-found (err u702))
(define-constant err-invalid-amount (err u703))
(define-constant err-not-member (err u704))
(define-constant err-already-member (err u705))
(define-constant err-claim-not-found (err u706))
(define-constant err-already-voted (err u707))
(define-constant err-claim-not-approved (err u708))
(define-constant err-claim-already-paid (err u709))
(define-constant err-insufficient-pool-funds (err u710))
(define-constant err-pool-paused (err u711))
(define-constant err-coverage-expired (err u712))
(define-constant err-invalid-threshold (err u713))
(define-constant err-voting-ended (err u714))
(define-constant err-stake-too-low (err u715))
(define-constant err-claim-limit-exceeded (err u716))
(define-constant err-pool-inactive (err u717))

;; Claim status constants
(define-constant claim-pending u1)
(define-constant claim-approved u2)
(define-constant claim-rejected u3)
(define-constant claim-paid u4)

;; Voting period (in blocks)
(define-constant voting-period u1440) ;; ~10 days
(define-constant min-stake-percentage u1000) ;; 10% of claim as stake

;; Data Variables
(define-data-var total-pools uint u0)
(define-data-var total-claims uint u0)
(define-data-var total-premiums-collected uint u0)
(define-data-var total-claims-paid uint u0)

;; Data Maps

;; Insurance pools
(define-map pools
  uint
  {
    creator: principal,
    name: (string-ascii 100),
    description: (string-ascii 500),
    max-coverage: uint,
    min-premium: uint,
    max-premium: uint,
    coverage-period-blocks: uint,
    approval-threshold: uint,
    pool-balance: uint,
    total-members: uint,
    active: bool,
    created-at: uint
  }
)

;; Member coverage details
(define-map member-coverage
  { member: principal, pool-id: uint }
  {
    premium-paid: uint,
    coverage-start: uint,
    coverage-end: uint,
    active: bool,
    total-premiums-paid: uint,
    claims-filed: uint
  }
)

;; Claims
(define-map claims
  uint
  {
    pool-id: uint,
    claimer: principal,
    amount: uint,
    description: (string-ascii 500),
    evidence-hash: (buff 32),
    filed-at: uint,
    voting-ends: uint,
    approve-votes: uint,
    reject-votes: uint,
    status: uint,
    stake-amount: uint
  }
)

;; Votes on claims
(define-map votes
  { voter: principal, claim-id: uint }
  {
    vote: bool,
    voted-at: uint
  }
)

;; Pool member count for voting power
(define-map member-voting-power
  { member: principal, pool-id: uint }
  uint
)

;; Private Functions

(define-private (is-contract-owner)
  (is-eq tx-sender contract-owner)
)

(define-private (is-pool-creator (pool-id uint))
  (match (map-get? pools pool-id)
    pool (is-eq tx-sender (get creator pool))
    false
  )
)

(define-private (is-pool-member (member principal) (pool-id uint))
  (match (map-get? member-coverage { member: member, pool-id: pool-id })
    coverage (get active coverage)
    false
  )
)

(define-private (is-coverage-active (member principal) (pool-id uint))
  (match (map-get? member-coverage { member: member, pool-id: pool-id })
    coverage (and
      (get active coverage)
      (>= stacks-block-height (get coverage-start coverage))
      (<= stacks-block-height (get coverage-end coverage))
    )
    false
  )
)

(define-private (calculate-min-stake (claim-amount uint))
  (/ (* claim-amount min-stake-percentage) u10000)
)

(define-private (calculate-vote-threshold (total-votes uint) (threshold uint))
  (/ (* total-votes threshold) u10000)
)

;; Public Functions

;; Create a new insurance pool
(define-public (create-pool
    (name (string-ascii 100))
    (description (string-ascii 500))
    (max-coverage uint)
    (min-premium uint)
    (max-premium uint)
    (coverage-period-blocks uint)
    (approval-threshold uint)
  )
  (let
    (
      (pool-id (var-get total-pools))
      (creator tx-sender)
    )
    (asserts! (> (len name) u0) err-invalid-amount)
    (asserts! (> max-coverage u0) err-invalid-amount)
    (asserts! (> min-premium u0) err-invalid-amount)
    (asserts! (<= min-premium max-premium) err-invalid-amount)
    (asserts! (> coverage-period-blocks u0) err-invalid-amount)
    (asserts! (and (>= approval-threshold u5000) (<= approval-threshold u10000)) err-invalid-threshold)
    
    (map-set pools pool-id
      {
        creator: creator,
        name: name,
        description: description,
        max-coverage: max-coverage,
        min-premium: min-premium,
        max-premium: max-premium,
        coverage-period-blocks: coverage-period-blocks,
        approval-threshold: approval-threshold,
        pool-balance: u0,
        total-members: u0,
        active: true,
        created-at: stacks-block-height
      }
    )
    
    (var-set total-pools (+ pool-id u1))
    (ok pool-id)
  )
)

;; Join an insurance pool with premium payment
(define-public (join-pool (pool-id uint) (premium uint) (coverage-duration uint))
  (let
    (
      (pool (unwrap! (map-get? pools pool-id) err-pool-not-found))
      (member tx-sender)
      (coverage-start stacks-block-height)
      (coverage-end (+ stacks-block-height coverage-duration))
    )
    (asserts! (get active pool) err-pool-inactive)
    (asserts! (not (is-pool-member member pool-id)) err-already-member)
    (asserts! (>= premium (get min-premium pool)) err-invalid-amount)
    (asserts! (<= premium (get max-premium pool)) err-invalid-amount)
    (asserts! (<= coverage-duration (get coverage-period-blocks pool)) err-invalid-amount)
    
    (try! (stx-transfer? premium member (as-contract tx-sender)))
    
    (map-set member-coverage
      { member: member, pool-id: pool-id }
      {
        premium-paid: premium,
        coverage-start: coverage-start,
        coverage-end: coverage-end,
        active: true,
        total-premiums-paid: premium,
        claims-filed: u0
      }
    )
    
    (map-set pools pool-id
      (merge pool {
        pool-balance: (+ (get pool-balance pool) premium),
        total-members: (+ (get total-members pool) u1)
      })
    )
    
    (map-set member-voting-power { member: member, pool-id: pool-id } u1)
    (var-set total-premiums-collected (+ (var-get total-premiums-collected) premium))
    
    (ok true)
  )
)

;; Pay additional premium to extend coverage
(define-public (pay-premium (pool-id uint) (premium uint) (extension-blocks uint))
  (let
    (
      (pool (unwrap! (map-get? pools pool-id) err-pool-not-found))
      (member tx-sender)
      (coverage (unwrap! (map-get? member-coverage { member: member, pool-id: pool-id }) err-not-member))
    )
    (asserts! (get active pool) err-pool-inactive)
    (asserts! (>= premium (get min-premium pool)) err-invalid-amount)
    
    (try! (stx-transfer? premium member (as-contract tx-sender)))
    
    (map-set member-coverage
      { member: member, pool-id: pool-id }
      (merge coverage {
        coverage-end: (+ (get coverage-end coverage) extension-blocks),
        total-premiums-paid: (+ (get total-premiums-paid coverage) premium)
      })
    )
    
    (map-set pools pool-id
      (merge pool {
        pool-balance: (+ (get pool-balance pool) premium)
      })
    )
    
    (var-set total-premiums-collected (+ (var-get total-premiums-collected) premium))
    (ok true)
  )
)

;; File a claim with stake
(define-public (file-claim
    (pool-id uint)
    (amount uint)
    (description (string-ascii 500))
    (evidence-hash (buff 32))
    (stake uint)
  )
  (let
    (
      (pool (unwrap! (map-get? pools pool-id) err-pool-not-found))
      (claimer tx-sender)
      (coverage (unwrap! (map-get? member-coverage { member: claimer, pool-id: pool-id }) err-not-member))
      (claim-id (var-get total-claims))
      (min-stake (calculate-min-stake amount))
      (voting-end (+ stacks-block-height voting-period))
    )
    (asserts! (get active pool) err-pool-inactive)
    (asserts! (is-coverage-active claimer pool-id) err-coverage-expired)
    (asserts! (> amount u0) err-invalid-amount)
    (asserts! (<= amount (get max-coverage pool)) err-claim-limit-exceeded)
    (asserts! (>= stake min-stake) err-stake-too-low)
    (asserts! (> (len description) u0) err-invalid-amount)
    
    (try! (stx-transfer? stake claimer (as-contract tx-sender)))
    
    (map-set claims claim-id
      {
        pool-id: pool-id,
        claimer: claimer,
        amount: amount,
        description: description,
        evidence-hash: evidence-hash,
        filed-at: stacks-block-height,
        voting-ends: voting-end,
        approve-votes: u0,
        reject-votes: u0,
        status: claim-pending,
        stake-amount: stake
      }
    )
    
    (map-set member-coverage
      { member: claimer, pool-id: pool-id }
      (merge coverage {
        claims-filed: (+ (get claims-filed coverage) u1)
      })
    )
    
    (var-set total-claims (+ claim-id u1))
    (ok claim-id)
  )
)

;; Vote on a claim
(define-public (vote-on-claim (claim-id uint) (approve bool))
  (let
    (
      (claim (unwrap! (map-get? claims claim-id) err-claim-not-found))
      (pool-id (get pool-id claim))
      (voter tx-sender)
      (voting-power (default-to u0 (map-get? member-voting-power { member: voter, pool-id: pool-id })))
    )
    (asserts! (is-pool-member voter pool-id) err-not-member)
    (asserts! (is-eq (get status claim) claim-pending) err-invalid-amount)
    (asserts! (<= stacks-block-height (get voting-ends claim)) err-voting-ended)
    (asserts! (is-none (map-get? votes { voter: voter, claim-id: claim-id })) err-already-voted)
    
    (map-set votes
      { voter: voter, claim-id: claim-id }
      {
        vote: approve,
        voted-at: stacks-block-height
      }
    )
    
    (map-set claims claim-id
      (merge claim {
        approve-votes: (if approve (+ (get approve-votes claim) voting-power) (get approve-votes claim)),
        reject-votes: (if approve (get reject-votes claim) (+ (get reject-votes claim) voting-power))
      })
    )
    
    (ok true)
  )
)

;; Execute claim payout after voting period
(define-public (execute-claim-payout (claim-id uint))
  (let
    (
      (claim (unwrap! (map-get? claims claim-id) err-claim-not-found))
      (pool-id (get pool-id claim))
      (pool (unwrap! (map-get? pools pool-id) err-pool-not-found))
      (claimer (get claimer claim))
      (amount (get amount claim))
      (stake (get stake-amount claim))
      (total-votes (+ (get approve-votes claim) (get reject-votes claim)))
      (threshold-votes (calculate-vote-threshold total-votes (get approval-threshold pool)))
      (approved (>= (get approve-votes claim) threshold-votes))
    )
    (asserts! (> stacks-block-height (get voting-ends claim)) err-voting-ended)
    (asserts! (is-eq (get status claim) claim-pending) err-claim-already-paid)
    (asserts! approved err-claim-not-approved)
    (asserts! (>= (get pool-balance pool) amount) err-insufficient-pool-funds)
    
    (map-set claims claim-id
      (merge claim { status: claim-paid })
    )
    
    (map-set pools pool-id
      (merge pool {
        pool-balance: (- (get pool-balance pool) amount)
      })
    )
    
    (try! (as-contract (stx-transfer? amount tx-sender claimer)))
    (try! (as-contract (stx-transfer? stake tx-sender claimer)))
    
    (var-set total-claims-paid (+ (var-get total-claims-paid) amount))
    (ok amount)
  )
)

;; Withdraw stake from rejected claim
(define-public (withdraw-rejected-stake (claim-id uint))
  (let
    (
      (claim (unwrap! (map-get? claims claim-id) err-claim-not-found))
      (claimer (get claimer claim))
      (stake (get stake-amount claim))
      (total-votes (+ (get approve-votes claim) (get reject-votes claim)))
      (pool (unwrap! (map-get? pools (get pool-id claim)) err-pool-not-found))
      (threshold-votes (calculate-vote-threshold total-votes (get approval-threshold pool)))
      (rejected (< (get approve-votes claim) threshold-votes))
    )
    (asserts! (is-eq tx-sender claimer) err-not-authorized)
    (asserts! (> stacks-block-height (get voting-ends claim)) err-voting-ended)
    (asserts! (is-eq (get status claim) claim-pending) err-claim-already-paid)
    (asserts! rejected err-invalid-amount)
    
    (map-set claims claim-id
      (merge claim { status: claim-rejected })
    )
    
    (try! (as-contract (stx-transfer? stake tx-sender claimer)))
    (ok stake)
  )
)

;; Add funds to pool reserve
(define-public (add-pool-funds (pool-id uint) (amount uint))
  (let
    (
      (pool (unwrap! (map-get? pools pool-id) err-pool-not-found))
      (contributor tx-sender)
    )
    (asserts! (get active pool) err-pool-inactive)
    (asserts! (> amount u0) err-invalid-amount)
    
    (try! (stx-transfer? amount contributor (as-contract tx-sender)))
    
    (map-set pools pool-id
      (merge pool {
        pool-balance: (+ (get pool-balance pool) amount)
      })
    )
    
    (ok true)
  )
)

;; Administrative Functions

(define-public (pause-pool (pool-id uint))
  (let
    (
      (pool (unwrap! (map-get? pools pool-id) err-pool-not-found))
    )
    (asserts! (or (is-contract-owner) (is-pool-creator pool-id)) err-not-authorized)
    
    (map-set pools pool-id
      (merge pool { active: false })
    )
    
    (ok true)
  )
)

(define-public (resume-pool (pool-id uint))
  (let
    (
      (pool (unwrap! (map-get? pools pool-id) err-pool-not-found))
    )
    (asserts! (or (is-contract-owner) (is-pool-creator pool-id)) err-not-authorized)
    
    (map-set pools pool-id
      (merge pool { active: true })
    )
    
    (ok true)
  )
)

;; Read-Only Functions

(define-read-only (get-pool-details (pool-id uint))
  (map-get? pools pool-id)
)

(define-read-only (get-member-coverage (member principal) (pool-id uint))
  (map-get? member-coverage { member: member, pool-id: pool-id })
)

(define-read-only (get-claim-details (claim-id uint))
  (map-get? claims claim-id)
)

(define-read-only (get-pool-balance (pool-id uint))
  (match (map-get? pools pool-id)
    pool (ok (get pool-balance pool))
    err-pool-not-found
  )
)

(define-read-only (calculate-coverage-status (member principal) (pool-id uint))
  (ok (is-coverage-active member pool-id))
)

(define-read-only (get-voting-results (claim-id uint))
  (match (map-get? claims claim-id)
    claim (ok {
      approve: (get approve-votes claim),
      reject: (get reject-votes claim),
      total: (+ (get approve-votes claim) (get reject-votes claim))
    })
    err-claim-not-found
  )
)

(define-read-only (is-pool-member-check (member principal) (pool-id uint))
  (is-pool-member member pool-id)
)

(define-read-only (calculate-pool-health (pool-id uint))
  (match (map-get? pools pool-id)
    pool (ok {
      balance: (get pool-balance pool),
      members: (get total-members pool),
      per-member: (if (> (get total-members pool) u0)
        (/ (get pool-balance pool) (get total-members pool))
        u0
      )
    })
    err-pool-not-found
  )
)

(define-read-only (get-pool-stats)
  {
    total-pools: (var-get total-pools),
    total-claims: (var-get total-claims),
    premiums-collected: (var-get total-premiums-collected),
    claims-paid: (var-get total-claims-paid)
  }
)

(define-read-only (can-file-claim (member principal) (pool-id uint))
  (ok (is-coverage-active member pool-id))
)

(define-read-only (get-voting-power (member principal) (pool-id uint))
  (ok (default-to u0 (map-get? member-voting-power { member: member, pool-id: pool-id })))
)

(define-read-only (calculate-reserve-ratio (pool-id uint))
  (match (map-get? pools pool-id)
    pool (let
      (
        (balance (get pool-balance pool))
        (max-liability (* (get max-coverage pool) (get total-members pool)))
      )
      (ok (if (> max-liability u0)
        (/ (* balance u10000) max-liability)
        u10000
      ))
    )
    err-pool-not-found
  )
)

(define-read-only (estimate-payout (claim-id uint))
  (match (map-get? claims claim-id)
    claim (ok (get amount claim))
    err-claim-not-found
  )
)