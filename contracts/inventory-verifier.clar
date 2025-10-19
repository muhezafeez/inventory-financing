;; Inventory Verifier Contract
;; Verifies inventory levels and authenticity through IoT sensors
;; Provides secure, blockchain-based inventory tracking for financing platform

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-UNAUTHORIZED (err u100))
(define-constant ERR-INVALID-INVENTORY (err u101))
(define-constant ERR-ALREADY-EXISTS (err u102))
(define-constant ERR-NOT-FOUND (err u103))
(define-constant ERR-INVALID-SENSOR (err u104))
(define-constant ERR-EXPIRED-VERIFICATION (err u105))

;; Data Variables
(define-data-var next-inventory-id uint u1)
(define-data-var verification-validity-period uint u2160) ;; ~15 days in blocks

;; Data Maps
(define-map inventories
  { inventory-id: uint }
  {
    owner: principal,
    location: (string-ascii 100),
    total-value: uint,
    item-count: uint,
    verification-status: (string-ascii 20),
    last-verified: uint,
    sensor-ids: (list 10 (string-ascii 50)),
    created-at: uint
  }
)

(define-map inventory-items
  { inventory-id: uint, item-id: uint }
  {
    name: (string-ascii 100),
    category: (string-ascii 50),
    quantity: uint,
    unit-value: uint,
    sku: (string-ascii 50),
    authenticity-hash: (buff 32),
    condition: (string-ascii 20),
    verified-at: uint
  }
)

(define-map authorized-sensors
  { sensor-id: (string-ascii 50) }
  {
    location: (string-ascii 100),
    sensor-type: (string-ascii 30),
    authorized: bool,
    last-active: uint
  }
)

(define-map verification-history
  { inventory-id: uint, verification-id: uint }
  {
    verifier: principal,
    timestamp: uint,
    total-value: uint,
    item-count: uint,
    verification-hash: (buff 32),
    sensor-data: (string-ascii 500)
  }
)

;; Authorization Functions
(define-private (is-contract-owner)
  (is-eq tx-sender CONTRACT-OWNER)
)

(define-private (is-inventory-owner (inventory-id uint))
  (match (map-get? inventories {inventory-id: inventory-id})
    inventory (is-eq tx-sender (get owner inventory))
    false
  )
)

;; Sensor Management Functions
(define-public (register-sensor (sensor-id (string-ascii 50)) (location (string-ascii 100)) (sensor-type (string-ascii 30)))
  (begin
    (asserts! (is-contract-owner) ERR-UNAUTHORIZED)
    (asserts! (is-none (map-get? authorized-sensors {sensor-id: sensor-id})) ERR-ALREADY-EXISTS)
    (ok (map-set authorized-sensors
      {sensor-id: sensor-id}
      {
        location: location,
        sensor-type: sensor-type,
        authorized: true,
        last-active: block-height
      }
    ))
  )
)

(define-public (deactivate-sensor (sensor-id (string-ascii 50)))
  (begin
    (asserts! (is-contract-owner) ERR-UNAUTHORIZED)
    (asserts! (is-some (map-get? authorized-sensors {sensor-id: sensor-id})) ERR-NOT-FOUND)
    (ok (map-set authorized-sensors
      {sensor-id: sensor-id}
      {
        location: "",
        sensor-type: "",
        authorized: false,
        last-active: block-height
      }
    ))
  )
)

(define-private (is-sensor-authorized (sensor-id (string-ascii 50)))
  (match (map-get? authorized-sensors {sensor-id: sensor-id})
    sensor (get authorized sensor)
    false
  )
)

;; Inventory Registration Functions
(define-public (register-inventory (location (string-ascii 100)) (sensor-ids (list 10 (string-ascii 50))))
  (let
    (
      (inventory-id (var-get next-inventory-id))
      (valid-sensors (filter is-sensor-authorized sensor-ids))
    )
    (asserts! (>= (len valid-sensors) u1) ERR-INVALID-SENSOR)
    (map-set inventories
      {inventory-id: inventory-id}
      {
        owner: tx-sender,
        location: location,
        total-value: u0,
        item-count: u0,
        verification-status: "pending",
        last-verified: u0,
        sensor-ids: valid-sensors,
        created-at: block-height
      }
    )
    (var-set next-inventory-id (+ inventory-id u1))
    (ok inventory-id)
  )
)

;; Item Management Functions
(define-public (add-inventory-item
  (inventory-id uint)
  (item-id uint)
  (name (string-ascii 100))
  (category (string-ascii 50))
  (quantity uint)
  (unit-value uint)
  (sku (string-ascii 50))
  (authenticity-hash (buff 32))
  (condition (string-ascii 20))
  )
  (begin
    (asserts! (is-inventory-owner inventory-id) ERR-UNAUTHORIZED)
    (asserts! (is-some (map-get? inventories {inventory-id: inventory-id})) ERR-NOT-FOUND)
    (map-set inventory-items
      {inventory-id: inventory-id, item-id: item-id}
      {
        name: name,
        category: category,
        quantity: quantity,
        unit-value: unit-value,
        sku: sku,
        authenticity-hash: authenticity-hash,
        condition: condition,
        verified-at: block-height
      }
    )
    (update-inventory-totals inventory-id)
  )
)

(define-private (update-inventory-totals (inventory-id uint))
  (let
    (
      (inventory (unwrap! (map-get? inventories {inventory-id: inventory-id}) ERR-NOT-FOUND))
      (new-item-count (+ (get item-count inventory) u1))
    )
    (ok (map-set inventories
      {inventory-id: inventory-id}
      (merge inventory {
        item-count: new-item-count
      })
    ))
  )
)

;; Verification Functions
(define-public (verify-inventory
  (inventory-id uint)
  (verification-id uint)
  (total-value uint)
  (item-count uint)
  (verification-hash (buff 32))
  (sensor-data (string-ascii 500))
  )
  (let
    (
      (inventory (unwrap! (map-get? inventories {inventory-id: inventory-id}) ERR-NOT-FOUND))
    )
    (asserts! (or (is-inventory-owner inventory-id) (is-contract-owner)) ERR-UNAUTHORIZED)
    ;; Record verification history
    (map-set verification-history
      {inventory-id: inventory-id, verification-id: verification-id}
      {
        verifier: tx-sender,
        timestamp: block-height,
        total-value: total-value,
        item-count: item-count,
        verification-hash: verification-hash,
        sensor-data: sensor-data
      }
    )
    ;; Update inventory status
    (ok (map-set inventories
      {inventory-id: inventory-id}
      (merge inventory {
        total-value: total-value,
        item-count: item-count,
        verification-status: "verified",
        last-verified: block-height
      })
    ))
  )
)

(define-public (update-item-quantity (inventory-id uint) (item-id uint) (new-quantity uint))
  (let
    (
      (item (unwrap! (map-get? inventory-items {inventory-id: inventory-id, item-id: item-id}) ERR-NOT-FOUND))
    )
    (asserts! (is-inventory-owner inventory-id) ERR-UNAUTHORIZED)
    (ok (map-set inventory-items
      {inventory-id: inventory-id, item-id: item-id}
      (merge item {
        quantity: new-quantity,
        verified-at: block-height
      })
    ))
  )
)

;; Query Functions
(define-read-only (get-inventory (inventory-id uint))
  (map-get? inventories {inventory-id: inventory-id})
)

(define-read-only (get-inventory-item (inventory-id uint) (item-id uint))
  (map-get? inventory-items {inventory-id: inventory-id, item-id: item-id})
)

(define-read-only (get-sensor-info (sensor-id (string-ascii 50)))
  (map-get? authorized-sensors {sensor-id: sensor-id})
)

(define-read-only (get-verification-history (inventory-id uint) (verification-id uint))
  (map-get? verification-history {inventory-id: inventory-id, verification-id: verification-id})
)

(define-read-only (is-verification-valid (inventory-id uint))
  (match (map-get? inventories {inventory-id: inventory-id})
    inventory
      (let
        (
          (last-verified (get last-verified inventory))
          (validity-period (var-get verification-validity-period))
        )
        (and
          (> last-verified u0)
          (<= (- block-height last-verified) validity-period)
          (is-eq (get verification-status inventory) "verified")
        )
      )
    false
  )
)

(define-read-only (get-inventory-value (inventory-id uint))
  (match (map-get? inventories {inventory-id: inventory-id})
    inventory
      (if (is-verification-valid inventory-id)
        (some (get total-value inventory))
        none
      )
    none
  )
)

;; Administrative Functions
(define-public (set-verification-validity-period (new-period uint))
  (begin
    (asserts! (is-contract-owner) ERR-UNAUTHORIZED)
    (ok (var-set verification-validity-period new-period))
  )
)

(define-read-only (get-contract-info)
  {
    owner: CONTRACT-OWNER,
    next-inventory-id: (var-get next-inventory-id),
    verification-validity-period: (var-get verification-validity-period)
  }
)


;; title: inventory-verifier
;; version:
;; summary:
;; description:

;; traits
;;

;; token definitions
;;

;; constants
;;

;; data vars
;;

;; data maps
;;

;; public functions
;;

;; read only functions
;;

;; private functions
;;

