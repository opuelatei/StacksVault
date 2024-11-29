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