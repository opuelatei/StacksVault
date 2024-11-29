;; title: stacks-vault
;; summary: A smart contract for managing deposits, withdrawals, and rewards in a decentralized vault.
;; description: The stacks-vault contract allows users to deposit tokens, withdraw them, and claim rewards based on their deposits. It supports multiple protocols and ensures secure and efficient management of user funds. The contract includes functions for protocol management, token validation, and yield distribution.

;; traits
(define-trait sip-010-trait
  (
    (transfer (uint principal principal (optional (buff 34))) (response bool uint))
    (get-name () (response (string-ascii 32) uint))
    (get-symbol () (response (string-ascii 32) uint))
    (get-decimals () (response uint uint))
    (get-balance (principal) (response uint uint))
    (get-total-supply () (response uint uint))
    (get-token-uri () (response (optional (string-utf8 256)) uint))
  )
)

;; token definitions
;;

;; constants
(define-constant contract-owner tx-sender)
(define-constant err-not-authorized (err u1000))
(define-constant err-invalid-amount (err u1001))
(define-constant err-insufficient-balance (err u1002))
(define-constant err-protocol-not-whitelisted (err u1003))
(define-constant err-strategy-disabled (err u1004))
(define-constant err-max-deposit-reached (err u1005))
(define-constant err-min-deposit-not-met (err u1006))
(define-constant err-invalid-protocol-id (err u1007))
(define-constant err-protocol-exists (err u1008))
(define-constant err-invalid-apy (err u1009))
(define-constant err-invalid-name (err u1010))
(define-constant err-invalid-token (err u1011))
(define-constant err-token-not-whitelisted (err u1012))
(define-constant protocol-active true)
(define-constant protocol-inactive false)
(define-constant max-protocol-id u100)
(define-constant max-apy u10000) ;; 100% APY in basis points
(define-constant min-apy u0)

;; data vars
(define-data-var total-tvl uint u0)
(define-data-var platform-fee-rate uint u100) ;; 1% (base 10000)
(define-data-var min-deposit uint u100000) ;; Minimum deposit in sats
(define-data-var max-deposit uint u1000000000) ;; Maximum deposit in sats
(define-data-var emergency-shutdown bool false)

;; data maps
(define-map user-deposits 
    { user: principal } 
    { amount: uint, last-deposit-block: uint })

(define-map user-rewards 
    { user: principal } 
    { pending: uint, claimed: uint })

(define-map protocols 
    { protocol-id: uint } 
    { name: (string-ascii 64), active: bool, apy: uint })

(define-map strategy-allocations 
    { protocol-id: uint } 
    { allocation: uint }) ;; allocation in basis points (100 = 1%)

(define-map whitelisted-tokens 
    { token: principal } 
    { approved: bool })

;; public functions
(define-public (add-protocol (protocol-id uint) (name (string-ascii 64)) (initial-apy uint))
    (begin
        (asserts! (is-contract-owner) err-not-authorized)
        (asserts! (is-valid-protocol-id protocol-id) err-invalid-protocol-id)
        (asserts! (not (protocol-exists protocol-id)) err-protocol-exists)
        (asserts! (is-valid-name name) err-invalid-name)
        (asserts! (is-valid-apy initial-apy) err-invalid-apy)
        
        (map-set protocols { protocol-id: protocol-id }
            { 
                name: name,
                active: protocol-active,
                apy: initial-apy
            }
        )
        (map-set strategy-allocations { protocol-id: protocol-id } { allocation: u0 })
        (ok true)
    )
)

(define-public (update-protocol-status (protocol-id uint) (active bool))
    (begin
        (asserts! (is-contract-owner) err-not-authorized)
        (asserts! (is-valid-protocol-id protocol-id) err-invalid-protocol-id)
        (asserts! (protocol-exists protocol-id) err-invalid-protocol-id)
        
        (let ((protocol (unwrap-panic (get-protocol protocol-id))))
            (map-set protocols { protocol-id: protocol-id }
                (merge protocol { active: active })
            )
        )
        (ok true)
    )
)

(define-public (update-protocol-apy (protocol-id uint) (new-apy uint))
    (begin
        (asserts! (is-contract-owner) err-not-authorized)
        (asserts! (is-valid-protocol-id protocol-id) err-invalid-protocol-id)
        (asserts! (protocol-exists protocol-id) err-invalid-protocol-id)
        (asserts! (is-valid-apy new-apy) err-invalid-apy)
        
        (let ((protocol (unwrap-panic (get-protocol protocol-id))))
            (map-set protocols { protocol-id: protocol-id }
                (merge protocol { apy: new-apy })
            )
        )
        (ok true)
    )
)

(define-public (deposit (token-trait <sip-010-trait>) (amount uint))
    (let
        (
            (user-principal tx-sender)
            (current-deposit (default-to { amount: u0, last-deposit-block: u0 } 
                (map-get? user-deposits { user: user-principal })))
        )
        (try! (validate-token token-trait))
        (asserts! (not (var-get emergency-shutdown)) err-strategy-disabled)
        (asserts! (>= amount (var-get min-deposit)) err-min-deposit-not-met)
        (asserts! (<= (+ amount (get amount current-deposit)) (var-get max-deposit)) err-max-deposit-reached)
        
        (try! (contract-call? token-trait transfer amount user-principal (as-contract tx-sender) none))
        
        (map-set user-deposits 
            { user: user-principal }
            { 
                amount: (+ amount (get amount current-deposit)),
                last-deposit-block: block-height
            })
        
        (var-set total-tvl (+ (var-get total-tvl) amount))
        
        (try! (rebalance-protocols))
        (ok true)
    )
)

(define-public (withdraw (token-trait <sip-010-trait>) (amount uint))
    (let
        (
            (user-principal tx-sender)
            (current-deposit (default-to { amount: u0, last-deposit-block: u0 }
                (map-get? user-deposits { user: user-principal })))
        )
        (try! (validate-token token-trait))
        (asserts! (<= amount (get amount current-deposit)) err-insufficient-balance)
        
        (map-set user-deposits
            { user: user-principal }
            {
                amount: (- (get amount current-deposit) amount),
                last-deposit-block: (get last-deposit-block current-deposit)
            })
        
        (var-set total-tvl (- (var-get total-tvl) amount))
        
        (as-contract
            (try! (contract-call? token-trait transfer amount tx-sender user-principal none)))
        
        (ok true)
    )
)

(define-public (claim-rewards (token-trait <sip-010-trait>))
    (let
        (
            (user-principal tx-sender)
            (rewards (calculate-rewards user-principal (- block-height 
                (get last-deposit-block (unwrap-panic (get-user-deposit user-principal))))))
        )
        (try! (validate-token token-trait))
        (asserts! (> rewards u0) err-invalid-amount)
        
        (map-set user-rewards
            { user: user-principal }
            {
                pending: u0,
                claimed: (+ rewards 
                    (get claimed (default-to { pending: u0, claimed: u0 }
                        (map-get? user-rewards { user: user-principal }))))
            })
        
        (as-contract
            (try! (contract-call? token-trait transfer
                rewards
                tx-sender
                user-principal
                none)))
        
        (ok rewards)
    )
)

(define-public (set-platform-fee (new-fee uint))
    (begin
        (asserts! (is-contract-owner) err-not-authorized)
        (asserts! (<= new-fee u1000) err-invalid-amount)
        (var-set platform-fee-rate new-fee)
        (ok true)
    )
)

(define-public (set-emergency-shutdown (shutdown bool))
    (begin
        (asserts! (is-contract-owner) err-not-authorized)
        (var-set emergency-shutdown shutdown)
        (ok true)
    )
)

(define-public (whitelist-token (token principal))
    (begin
        (asserts! (is-contract-owner) err-not-authorized)
        (map-set whitelisted-tokens { token: token } { approved: true })
        (ok true)
    )
)

;; read only functions
(define-read-only (get-protocol (protocol-id uint))
    (map-get? protocols { protocol-id: protocol-id })
)

(define-read-only (get-user-deposit (user principal))
    (map-get? user-deposits { user: user })
)

(define-read-only (get-total-tvl)
    (var-get total-tvl)
)

(define-read-only (is-whitelisted (token <sip-010-trait>))
    (default-to false (get approved (map-get? whitelisted-tokens { token: (contract-of token) })))
)

;; private functions
(define-private (is-contract-owner)
    (is-eq tx-sender contract-owner)
)

(define-private (is-valid-protocol-id (protocol-id uint))
    (and 
        (> protocol-id u0)
        (<= protocol-id max-protocol-id)
    )
)

(define-private (is-valid-apy (apy uint))
    (and 
        (>= apy min-apy)
        (<= apy max-apy)
    )
)

(define-private (is-valid-name (name (string-ascii 64)))
    (and 
        (not (is-eq name ""))
        (<= (len name) u64)
    )
)

(define-private (protocol-exists (protocol-id uint))
    (is-some (map-get? protocols { protocol-id: protocol-id }))
)

(define-private (validate-token (token-trait <sip-010-trait>))
    (let 
        (
            (token-contract (contract-of token-trait))
            (token-info (map-get? whitelisted-tokens { token: token-contract }))
        )
        (asserts! (is-some token-info) err-token-not-whitelisted)
        (asserts! (get approved (unwrap-panic token-info)) err-protocol-not-whitelisted)
        (ok true)
    )
)

(define-private (calculate-rewards (user principal) (blocks uint))
    (let
        (
            (user-deposit (unwrap-panic (get-user-deposit user)))
            (weighted-apy (get-weighted-apy))
        )
        (/ (* (get amount user-deposit) weighted-apy blocks) (* u10000 u144 u365))
    )
)

(define-private (rebalance-protocols)
    (let
        (
            (total-allocations (fold + (map get-protocol-allocation (get-protocol-list)) u0))
        )
        (asserts! (<= total-allocations u10000) err-invalid-amount)
        (ok true)
    )
)

(define-private (get-weighted-apy)
    (fold + (map get-weighted-protocol-apy (get-protocol-list)) u0)
)

(define-private (get-weighted-protocol-apy (protocol-id uint))
    (let
        (
            (protocol (unwrap-panic (get-protocol protocol-id)))
            (allocation (get allocation (unwrap-panic 
                (map-get? strategy-allocations { protocol-id: protocol-id }))))
        )
        (if (get active protocol)
            (/ (* (get apy protocol) allocation) u10000)
            u0
        )
    )
)

(define-private (get-protocol-list)
    (list u1 u2 u3 u4 u5) ;; Supported protocol IDs
)

(define-private (get-protocol-allocation (protocol-id uint))
    (get allocation (default-to { allocation: u0 }
        (map-get? strategy-allocations { protocol-id: protocol-id })))
)