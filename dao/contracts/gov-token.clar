;; Simplified DAO Governance Protocol

;; Constants
(define-constant ERR-NOT-GOVERNOR (err u1))
(define-constant ERR-DAO-INACTIVE (err u2))
(define-constant ERR-INVALID-PROPOSAL (err u3))
(define-constant ERR-PROPOSAL-FINALIZED (err u4))
(define-constant ERR-INVALID-PARAMETER (err u5))
(define-constant ERR-INSUFFICIENT-TOKENS (err u6))
(define-constant ERR-PROPOSAL-EXISTS (err u7))
(define-constant ERR-ALREADY-VOTED (err u8))
(define-constant ERR-NOT-AUTHORIZED (err u9))
(define-constant MAX-PROPOSAL-ID u1000) ;; Maximum allowed proposal ID

;; Data Variables
(define-data-var dao-governor principal tx-sender)
(define-data-var dao-active bool false)
(define-data-var governance-cycle uint u0)
(define-data-var token-threshold uint u1000000) ;; 1 governance token minimum
(define-data-var treasury-balance uint u0)
(define-data-var quorum-percentage uint u33) ;; 33% quorum required for proposal to pass

;; Proposal Structure
(define-map proposals
    uint
    {
        title: (string-utf8 128),
        description: (string-utf8 512),
        proposal-hash: (buff 32),    ;; SHA256 hash of the detailed proposal
        fund-request: uint,          ;; Amount of tokens requested for implementation
        votes-for: uint,
        votes-against: uint,
        total-possible-votes: uint,  ;; Total circulating tokens at proposal creation
        executed: bool,
        passed: bool
    }
)

;; Member Profiles
(define-map member-profiles
    principal
    {
        token-balance: uint,
        proposals-created: (list 30 uint),
        voting-power: uint           ;; Can be different from token balance (delegation)
    }
)

;; Voting Records
(define-map vote-records
    {proposal-id: uint, voter: principal}
    {
        vote-type: bool,            ;; true = for, false = against
        vote-power: uint
    }
)

;; Authorization
(define-private (is-governor)
    (is-eq tx-sender (var-get dao-governor)))

;; DAO Management Functions
(define-public (activate-dao)
    (begin
        (asserts! (is-governor) ERR-NOT-GOVERNOR)
        (var-set dao-active true)
        (var-set governance-cycle u0)
        (var-set treasury-balance u0)
        (ok true)))

(define-public (submit-proposal
    (proposal-id uint)
    (title (string-utf8 128))
    (description (string-utf8 512))
    (proposal-hash (buff 32))
    (fund-request uint))
    (let (
        (member-profile (unwrap! (map-get? member-profiles tx-sender) ERR-INSUFFICIENT-TOKENS))
        (total-token-supply u10000000) ;; Example: 10M total tokens
        )
        
        ;; Check DAO status
        (asserts! (var-get dao-active) ERR-DAO-INACTIVE)
        
        ;; Validate proposal-id is within acceptable range
        (asserts! (<= proposal-id MAX-PROPOSAL-ID) ERR-INVALID-PARAMETER)
        
        ;; Check if proposal already exists
        (asserts! (is-none (map-get? proposals proposal-id)) ERR-PROPOSAL-EXISTS)
        
        ;; Validate title and description are not empty
        (asserts! (> (len title) u0) ERR-INVALID-PARAMETER)
        (asserts! (> (len description) u0) ERR-INVALID-PARAMETER)
        
        ;; Check member has enough tokens to submit proposal
        (asserts! (>= (get token-balance member-profile) (var-get token-threshold)) ERR-INSUFFICIENT-TOKENS)
        
        ;; Set the proposal data
        (map-set proposals proposal-id
            {
                title: title,
                description: description,
                proposal-hash: proposal-hash,
                fund-request: fund-request,
                votes-for: u0,
                votes-against: u0,
                total-possible-votes: total-token-supply,
                executed: false,
                passed: false
            })
        
        ;; Update member profile
        (map-set member-profiles tx-sender
            (merge member-profile {
                proposals-created: (unwrap! (as-max-len? 
                    (append (get proposals-created member-profile) proposal-id) u30)
                    ERR-INVALID-PARAMETER)
            }))
        
        (ok true)))

;; Membership Functions
(define-public (register-member (token-amount uint))
    (begin
        (asserts! (var-get dao-active) ERR-DAO-INACTIVE)
        ;; Require minimum token amount
        (asserts! (>= token-amount (var-get token-threshold)) ERR-INSUFFICIENT-TOKENS)
        
        ;; Transfer tokens to DAO treasury
        (try! (stx-transfer? token-amount tx-sender (var-get dao-governor)))
        
        ;; Initialize member profile
        (map-set member-profiles tx-sender
            {
                token-balance: token-amount,
                proposals-created: (list),
                voting-power: token-amount
            })
            
        ;; Update treasury balance
        (var-set treasury-balance (+ (var-get treasury-balance) token-amount))
        
        (ok true)))

;; Voting Functions
(define-public (cast-vote
    (proposal-id uint)
    (vote-for bool))
    (let (
        (proposal (unwrap! (map-get? proposals proposal-id) ERR-INVALID-PROPOSAL))
        (member (unwrap! (map-get? member-profiles tx-sender) ERR-INSUFFICIENT-TOKENS))
        (voting-power (get voting-power member))
        )
        
        ;; Check DAO status
        (asserts! (var-get dao-active) ERR-DAO-INACTIVE)
        
        ;; Check proposal hasn't been executed
        (asserts! (not (get executed proposal)) ERR-PROPOSAL-FINALIZED)
        
        ;; Check member hasn't already voted
        (asserts! (is-none (map-get? vote-records {proposal-id: proposal-id, voter: tx-sender})) ERR-ALREADY-VOTED)
        
        ;; Record vote
        (map-set vote-records 
            {proposal-id: proposal-id, voter: tx-sender}
            {
                vote-type: vote-for,
                vote-power: voting-power
            })
        
        ;; Update vote counts
        (if vote-for
            (map-set proposals proposal-id
                (merge proposal {votes-for: (+ (get votes-for proposal) voting-power)}))
            (map-set proposals proposal-id
                (merge proposal {votes-against: (+ (get votes-against proposal) voting-power)}))
        )
        
        (ok true)))

;; Proposal Finalization
(define-public (finalize-proposal (proposal-id uint))
    (let (
        (proposal (unwrap! (map-get? proposals proposal-id) ERR-INVALID-PROPOSAL))
        )
        
        ;; Check DAO status
        (asserts! (var-get dao-active) ERR-DAO-INACTIVE)
        
        ;; Only governor can finalize proposals
        (asserts! (is-governor) ERR-NOT-AUTHORIZED)
        
        ;; Check proposal hasn't been executed
        (asserts! (not (get executed proposal)) ERR-PROPOSAL-FINALIZED)
        
        ;; Calculate if quorum was reached
        (let (
            (total-votes (+ (get votes-for proposal) (get votes-against proposal)))
            (quorum-threshold (/ (* (get total-possible-votes proposal) (var-get quorum-percentage)) u100))
            (proposal-passed (and 
                (> total-votes quorum-threshold)
                (> (get votes-for proposal) (get votes-against proposal))))
            )
            
            ;; Update proposal status
            (map-set proposals proposal-id
                (merge proposal {
                    executed: true,
                    passed: proposal-passed
                }))
            
            ;; If proposal passed and requested funds, transfer them
            (if (and proposal-passed (> (get fund-request proposal) u0))
                (begin
                    ;; Ensure treasury has enough balance
                    (asserts! (>= (var-get treasury-balance) (get fund-request proposal)) ERR-INSUFFICIENT-TOKENS)
                    
                    ;; Update treasury balance
                    (var-set treasury-balance (- (var-get treasury-balance) (get fund-request proposal)))
                    
                    (ok true))
                (ok false)))))

;; Read-only functions
(define-read-only (get-proposal-details (proposal-id uint))
    (map-get? proposals proposal-id))

(define-read-only (get-member-profile (member principal))
    (map-get? member-profiles member))

(define-read-only (get-dao-metrics)
    {
        active: (var-get dao-active),
        governance-cycle: (var-get governance-cycle),
        treasury-balance: (var-get treasury-balance),
        token-threshold: (var-get token-threshold),
        quorum-percentage: (var-get quorum-percentage)
    })

(define-public (update-token-threshold (new-threshold uint))
    (begin
        (asserts! (is-governor) ERR-NOT-GOVERNOR)
        (var-set token-threshold new-threshold)
        (ok true)))

(define-public (update-quorum-percentage (new-percentage uint))
    (begin
        (asserts! (is-governor) ERR-NOT-GOVERNOR)
        ;; Validate percentage is between 1 and 100
        (asserts! (and (> new-percentage u0) (<= new-percentage u100)) ERR-INVALID-PARAMETER)
        (var-set quorum-percentage new-percentage)
        (ok true)))

(define-public (deactivate-dao)
    (begin
        (asserts! (is-governor) ERR-NOT-GOVERNOR)
        (var-set dao-active false)
        (ok true)))

(define-public (advance-governance-cycle)
    (begin
        (asserts! (is-governor) ERR-NOT-GOVERNOR)
        (asserts! (var-get dao-active) ERR-DAO-INACTIVE)
        (var-set governance-cycle (+ (var-get governance-cycle) u1))
        (ok true)))

(define-public (transfer-governor-role (new-governor principal))
    (begin
        (asserts! (is-governor) ERR-NOT-GOVERNOR)
        (var-set dao-governor new-governor)
        (ok true)))