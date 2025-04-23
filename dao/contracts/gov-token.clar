;; Nexus Harmony DAO 

;; Constants
(define-constant ERR-NOT-GOVERNOR (err u1))
(define-constant ERR-DAO-INACTIVE (err u2))
(define-constant ERR-INVALID-PROPOSAL (err u3))
(define-constant ERR-PROPOSAL-FINALIZED (err u4))
(define-constant ERR-INVALID-PARAMETER (err u5))
(define-constant ERR-INSUFFICIENT-TOKENS (err u6))

;; Data Variables
(define-data-var dao-governor principal tx-sender)
(define-data-var dao-active bool false)
(define-data-var token-threshold uint u100000) ;; 100k token minimum

;; Proposal Structure
(define-map proposals
    uint
    {
        title: (string-utf8 64),
        description: (string-utf8 256),
        votes-for: uint,
        votes-against: uint,
        executed: bool,
        passed: bool
    }
)

;; Member Profiles
(define-map member-profiles
    principal
    {
        token-balance: uint,
        voting-power: uint
    }
)

;; Voting Records
(define-map vote-records
    {proposal-id: uint, voter: principal}
    {
        vote-type: bool            ;; true = for, false = against
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
        (ok true)))

(define-public (submit-proposal
    (proposal-id uint)
    (title (string-utf8 64))
    (description (string-utf8 256)))
    (let (
        (member-profile (unwrap! (map-get? member-profiles tx-sender) ERR-INSUFFICIENT-TOKENS))
        )
        
        ;; Check DAO status
        (asserts! (var-get dao-active) ERR-DAO-INACTIVE)
        
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
                votes-for: u0,
                votes-against: u0,
                executed: false,
                passed: false
            })
        
        (ok true)))

;; Membership Functions
(define-public (register-member (token-amount uint))
    (begin
        (asserts! (var-get dao-active) ERR-DAO-INACTIVE)
        ;; Require minimum token amount
        (asserts! (>= token-amount (var-get token-threshold)) ERR-INSUFFICIENT-TOKENS)
        
        ;; Initialize member profile
        (map-set member-profiles tx-sender
            {
                token-balance: token-amount,
                voting-power: token-amount
            })
            
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
        (asserts! (is-none (map-get? vote-records {proposal-id: proposal-id, voter: tx-sender})) ERR-PROPOSAL-FINALIZED)
        
        ;; Record vote
        (map-set vote-records 
            {proposal-id: proposal-id, voter: tx-sender}
            {
                vote-type: vote-for
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
        (asserts! (is-governor) ERR-NOT-GOVERNOR)
        
        ;; Check proposal hasn't been executed
        (asserts! (not (get executed proposal)) ERR-PROPOSAL-FINALIZED)
        
        ;; Determine if proposal passed
        (let (
            (proposal-passed (> (get votes-for proposal) (get votes-against proposal)))
            )
            
            ;; Update proposal status
            (map-set proposals proposal-id
                (merge proposal {
                    executed: true,
                    passed: proposal-passed
                }))
            
            (ok proposal-passed))))

;; Read-only functions
(define-read-only (get-proposal-details (proposal-id uint))
    (map-get? proposals proposal-id))

(define-read-only (get-member-profile (member principal))
    (map-get? member-profiles member))

(define-read-only (get-dao-status)
    (var-get dao-active))

(define-public (update-token-threshold (new-threshold uint))
    (begin
        (asserts! (is-governor) ERR-NOT-GOVERNOR)
        (var-set token-threshold new-threshold)
        (ok true)))

(define-public (deactivate-dao)
    (begin
        (asserts! (is-governor) ERR-NOT-GOVERNOR)
        (var-set dao-active false)
        (ok true)))
