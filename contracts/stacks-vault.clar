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