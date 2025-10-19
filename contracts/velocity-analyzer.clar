;; Velocity Analyzer Contract
;; Analyzes sales velocity and inventory turnover rates
;; Provides sales performance metrics for inventory financing decisions

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-UNAUTHORIZED (err u200))
(define-constant ERR-INVALID-DATA (err u201))
(define-constant ERR-NOT-FOUND (err u202))
(define-constant ERR-INSUFFICIENT-HISTORY (err u203))
(define-constant ERR-ALREADY-EXISTS (err u204))
(define-constant ERR-INVALID-PERIOD (err u205))

;; Constants for calculations
(define-constant DAYS-IN-YEAR u365)
(define-constant BLOCKS-PER-DAY u144) ;; Approximately 144 blocks per day
(define-constant MIN-ANALYSIS-PERIOD u1008) ;; ~7 days minimum
(define-constant MAX-ANALYSIS-PERIOD u15120) ;; ~105 days maximum

;; Data Variables
(define-data-var next-sales-id uint u1)
(define-data-var analysis-window uint u4320) ;; ~30 days default

;; Data Maps
(define-map sales-records
  { inventory-id: uint, sales-id: uint }
  {
    seller: principal,
    item-category: (string-ascii 50),
    quantity-sold: uint,
    sale-value: uint,
    sale-date: uint,
    channel: (string-ascii 30),
    verified: bool
  }
)

(define-map inventory-metrics
  { inventory-id: uint }
  {
    owner: principal,
    total-sales: uint,
    total-revenue: uint,
    avg-daily-sales: uint,
    turnover-rate: uint,
    velocity-score: uint,
    analysis-period: uint,
    last-updated: uint,
    sales-trend: (string-ascii 20)
  }
)

(define-map category-performance
  { inventory-id: uint, category: (string-ascii 50) }
  {
    total-quantity: uint,
    total-revenue: uint,
    avg-sale-value: uint,
    velocity-score: uint,
    trend-direction: (string-ascii 10),
    last-sale: uint
  }
)

(define-map velocity-history
  { inventory-id: uint, analysis-date: uint }
  {
    velocity-score: uint,
    turnover-rate: uint,
    sales-volume: uint,
    trend-change: int,
    risk-factor: uint
  }
)

(define-map authorized-reporters
  { reporter: principal }
  {
    authorized: bool,
    inventory-permissions: (list 20 uint),
    last-report: uint
  }
)

;; Authorization Functions
(define-private (is-contract-owner)
  (is-eq tx-sender CONTRACT-OWNER)
)

(define-private (is-authorized-reporter (inventory-id uint))
  (match (map-get? authorized-reporters {reporter: tx-sender})
    reporter-info
      (and
        (get authorized reporter-info)
        (is-some (index-of (get inventory-permissions reporter-info) inventory-id))
      )
    false
  )
)

(define-private (is-inventory-owner (inventory-id uint))
  (match (map-get? inventory-metrics {inventory-id: inventory-id})
    metrics (is-eq tx-sender (get owner metrics))
    false
  )
)

;; Reporter Management
(define-public (authorize-reporter (reporter principal) (inventory-permissions (list 20 uint)))
  (begin
    (asserts! (is-contract-owner) ERR-UNAUTHORIZED)
    (ok (map-set authorized-reporters
      {reporter: reporter}
      {
        authorized: true,
        inventory-permissions: inventory-permissions,
        last-report: u0
      }
    ))
  )
)

(define-public (revoke-reporter (reporter principal))
  (begin
    (asserts! (is-contract-owner) ERR-UNAUTHORIZED)
    (ok (map-set authorized-reporters
      {reporter: reporter}
      {
        authorized: false,
        inventory-permissions: (list),
        last-report: block-height
      }
    ))
  )
)

;; Sales Recording Functions
(define-public (record-sale
  (inventory-id uint)
  (item-category (string-ascii 50))
  (quantity-sold uint)
  (sale-value uint)
  (channel (string-ascii 30))
  )
  (let
    (
      (sales-id (var-get next-sales-id))
    )
    (asserts! (or (is-authorized-reporter inventory-id) (is-inventory-owner inventory-id)) ERR-UNAUTHORIZED)
    (asserts! (> quantity-sold u0) ERR-INVALID-DATA)
    (asserts! (> sale-value u0) ERR-INVALID-DATA)
    
    (map-set sales-records
      {inventory-id: inventory-id, sales-id: sales-id}
      {
        seller: tx-sender,
        item-category: item-category,
        quantity-sold: quantity-sold,
        sale-value: sale-value,
        sale-date: block-height,
        channel: channel,
        verified: true
      }
    )
    (var-set next-sales-id (+ sales-id u1))
    (update-category-metrics inventory-id item-category quantity-sold sale-value)
    (ok sales-id)
  )
)

;; Metrics Calculation Functions
(define-private (update-category-metrics (inventory-id uint) (category (string-ascii 50)) (quantity uint) (revenue uint))
  (let
    (
      (existing-metrics (default-to
        {total-quantity: u0, total-revenue: u0, avg-sale-value: u0, velocity-score: u0, trend-direction: "stable", last-sale: u0}
        (map-get? category-performance {inventory-id: inventory-id, category: category})
      ))
      (new-total-quantity (+ (get total-quantity existing-metrics) quantity))
      (new-total-revenue (+ (get total-revenue existing-metrics) revenue))
      (new-avg-sale-value (if (> new-total-quantity u0) (/ new-total-revenue new-total-quantity) u0))
    )
    (map-set category-performance
      {inventory-id: inventory-id, category: category}
      {
        total-quantity: new-total-quantity,
        total-revenue: new-total-revenue,
        avg-sale-value: new-avg-sale-value,
        velocity-score: (calculate-category-velocity inventory-id category),
        trend-direction: "up",
        last-sale: block-height
      }
    )
  )
)

(define-private (calculate-category-velocity (inventory-id uint) (category (string-ascii 50)))
  (let
    (
      (analysis-window-period (var-get analysis-window))
      (current-time block-height)
      (window-start (- current-time analysis-window-period))
    )
    ;; Simplified velocity calculation - in practice would analyze multiple sales records
    (match (map-get? category-performance {inventory-id: inventory-id, category: category})
      metrics
        (let
          (
            (recent-sales (get total-quantity metrics))
            (days-in-period (/ analysis-window-period BLOCKS-PER-DAY))
          )
          (if (> days-in-period u0)
            (/ (* recent-sales u100) days-in-period) ;; Sales per day * 100 for score
            u0
          )
        )
      u0
    )
  )
)

(define-public (analyze-inventory-velocity (inventory-id uint))
  (let
    (
      (analysis-period (var-get analysis-window))
      (current-time block-height)
      (window-start (- current-time analysis-period))
      (existing-metrics (map-get? inventory-metrics {inventory-id: inventory-id}))
    )
    (asserts! (or (is-inventory-owner inventory-id) (is-contract-owner)) ERR-UNAUTHORIZED)
    
    (let
      (
        (sales-data (calculate-sales-metrics inventory-id window-start current-time))
        (velocity-score (get velocity-score sales-data))
        (turnover-rate (get turnover-rate sales-data))
        (trend (determine-sales-trend inventory-id))
      )
      ;; Store velocity history
      (map-set velocity-history
        {inventory-id: inventory-id, analysis-date: current-time}
        {
          velocity-score: velocity-score,
          turnover-rate: turnover-rate,
          sales-volume: (get total-sales sales-data),
          trend-change: (if (is-eq trend "up") 1 (if (is-eq trend "down") -1 0)),
          risk-factor: (calculate-risk-factor velocity-score turnover-rate)
        }
      )
      
      ;; Update inventory metrics
      (ok (map-set inventory-metrics
        {inventory-id: inventory-id}
        {
          owner: (match existing-metrics metrics (get owner metrics) tx-sender),
          total-sales: (get total-sales sales-data),
          total-revenue: (get total-revenue sales-data),
          avg-daily-sales: (get avg-daily-sales sales-data),
          turnover-rate: turnover-rate,
          velocity-score: velocity-score,
          analysis-period: analysis-period,
          last-updated: current-time,
          sales-trend: trend
        }
      ))
    )
  )
)

(define-private (calculate-sales-metrics (inventory-id uint) (start-time uint) (end-time uint))
  ;; Simplified calculation - in practice would iterate through sales records
  (let
    (
      (days-in-period (/ (- end-time start-time) BLOCKS-PER-DAY))
      (mock-total-sales u100) ;; Mock data for demonstration
      (mock-total-revenue u50000) ;; Mock data
    )
    {
      total-sales: mock-total-sales,
      total-revenue: mock-total-revenue,
      avg-daily-sales: (if (> days-in-period u0) (/ mock-total-sales days-in-period) u0),
      turnover-rate: (if (> days-in-period u0) (/ (* mock-total-sales DAYS-IN-YEAR) (* days-in-period u100)) u0),
      velocity-score: (if (> days-in-period u0) (/ (* mock-total-sales u365) days-in-period) u0)
    }
  )
)

(define-private (determine-sales-trend (inventory-id uint))
  ;; Simplified trend analysis
  (let
    (
      (current-metrics (map-get? inventory-metrics {inventory-id: inventory-id}))
      (prev-analysis (map-get? velocity-history {inventory-id: inventory-id, analysis-date: (- block-height (var-get analysis-window))}))
    )
    (if (and (is-some current-metrics) (is-some prev-analysis))
        (let
          (
            (current-velocity (get velocity-score (unwrap-panic current-metrics)))
            (prev-velocity (get velocity-score (unwrap-panic prev-analysis)))
          )
          (if (> current-velocity prev-velocity)
            "up"
            (if (< current-velocity prev-velocity)
              "down"
              "stable"
            )
          )
        )
      "stable"
    )
  )
)

(define-private (calculate-risk-factor (velocity-score uint) (turnover-rate uint))
  ;; Risk calculation: lower velocity and turnover = higher risk
  (let
    (
      (velocity-risk (if (< velocity-score u50) u80 (if (< velocity-score u100) u40 u10)))
      (turnover-risk (if (< turnover-rate u2) u70 (if (< turnover-rate u4) u30 u5)))
    )
    (/ (+ velocity-risk turnover-risk) u2)
  )
)

;; Query Functions
(define-read-only (get-sales-record (inventory-id uint) (sales-id uint))
  (map-get? sales-records {inventory-id: inventory-id, sales-id: sales-id})
)

(define-read-only (get-inventory-metrics (inventory-id uint))
  (map-get? inventory-metrics {inventory-id: inventory-id})
)

(define-read-only (get-category-performance (inventory-id uint) (category (string-ascii 50)))
  (map-get? category-performance {inventory-id: inventory-id, category: category})
)

(define-read-only (get-velocity-history (inventory-id uint) (analysis-date uint))
  (map-get? velocity-history {inventory-id: inventory-id, analysis-date: analysis-date})
)

(define-read-only (get-velocity-score (inventory-id uint))
  (match (map-get? inventory-metrics {inventory-id: inventory-id})
    metrics (some (get velocity-score metrics))
    none
  )
)

(define-read-only (get-turnover-rate (inventory-id uint))
  (match (map-get? inventory-metrics {inventory-id: inventory-id})
    metrics (some (get turnover-rate metrics))
    none
  )
)

(define-read-only (get-risk-assessment (inventory-id uint))
  (match (map-get? velocity-history {inventory-id: inventory-id, analysis-date: block-height})
    history
      {
        velocity-score: (get velocity-score history),
        turnover-rate: (get turnover-rate history),
        risk-factor: (get risk-factor history),
        trend-change: (get trend-change history),
        assessment: (if (> (get risk-factor history) u60) "high-risk" (if (> (get risk-factor history) u30) "medium-risk" "low-risk"))
      }
    {
      velocity-score: u0,
      turnover-rate: u0,
      risk-factor: u100,
      trend-change: 0,
      assessment: "no-data"
    }
  )
)

;; Administrative Functions
(define-public (set-analysis-window (new-window uint))
  (begin
    (asserts! (is-contract-owner) ERR-UNAUTHORIZED)
    (asserts! (>= new-window MIN-ANALYSIS-PERIOD) ERR-INVALID-PERIOD)
    (asserts! (<= new-window MAX-ANALYSIS-PERIOD) ERR-INVALID-PERIOD)
    (ok (var-set analysis-window new-window))
  )
)

(define-public (initialize-inventory-tracking (inventory-id uint))
  (begin
    (asserts! (is-none (map-get? inventory-metrics {inventory-id: inventory-id})) ERR-ALREADY-EXISTS)
    (ok (map-set inventory-metrics
      {inventory-id: inventory-id}
      {
        owner: tx-sender,
        total-sales: u0,
        total-revenue: u0,
        avg-daily-sales: u0,
        turnover-rate: u0,
        velocity-score: u0,
        analysis-period: (var-get analysis-window),
        last-updated: block-height,
        sales-trend: "stable"
      }
    ))
  )
)

(define-read-only (get-contract-info)
  {
    owner: CONTRACT-OWNER,
    next-sales-id: (var-get next-sales-id),
    analysis-window: (var-get analysis-window)
  }
)


;; title: velocity-analyzer
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

