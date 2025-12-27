USE crm;

-- ============================================================
-- 02_jobs.sql
-- 목적: Execution DB 병합 이후, Template DB의 user_features를
--      "동기화/계산"하여 최신 상태로 유지
-- 실행 방식: 수동 실행(데모) 또는 크론/배치(운영)
-- 전제: carts, cart_items, orders, order_items 테이블이 crm DB에 존재
-- ============================================================

/* ------------------------------------------------------------
  JOB 1) cart_items_count 업데이트 (SUM(quantity) 기준)
  - carts.status='active' 인 장바구니만 집계
  - carts/status 컬럼이 없다면 WHERE 조건을 수정해야 함
------------------------------------------------------------ */
UPDATE user_features uf
LEFT JOIN (
  SELECT c.user_id, COALESCE(SUM(ci.quantity), 0) AS cnt
  FROM carts c
  JOIN cart_items ci ON ci.cart_id = c.cart_id
  WHERE c.status = 'active'
  GROUP BY c.user_id
) t ON t.user_id = uf.user_id
SET uf.cart_items_count = COALESCE(t.cnt, 0);


/* ------------------------------------------------------------
  JOB 2) last_cart_at 업데이트
  - active cart_items 변경 시점이 있다면 그 timestamp를 쓰는 게 더 정확함
  - 여기서는 carts.updated_at이 있다고 가정(없으면 수정)
------------------------------------------------------------ */
UPDATE user_features uf
LEFT JOIN (
  SELECT c.user_id, MAX(c.updated_at) AS last_cart_at
  FROM carts c
  WHERE c.status = 'active'
  GROUP BY c.user_id
) t ON t.user_id = uf.user_id
SET uf.last_cart_at = t.last_cart_at;


/* ------------------------------------------------------------
  JOB 3) last_purchase_at 업데이트
  - orders.status='PAID' 또는 'COMPLETED' 기준으로 최신 구매시각 갱신
  - status 값은 Execution 스키마에 맞춰 수정 필요
------------------------------------------------------------ */
UPDATE user_features uf
LEFT JOIN (
  SELECT o.user_id, MAX(o.paid_at) AS last_purchase_at
  FROM orders o
  WHERE o.status IN ('PAID','COMPLETED')
  GROUP BY o.user_id
) t ON t.user_id = uf.user_id
SET uf.last_purchase_at = t.last_purchase_at;


/* ------------------------------------------------------------
  JOB 4) (선택) lifecycle_stage 간단 갱신 규칙 예시
  - 최근 30일 구매 있으면 active, 90일 없으면 dormant
  - 운영 규칙은 기획에 맞춰 재정의 가능
------------------------------------------------------------ */
UPDATE user_features
SET lifecycle_stage = CASE
  WHEN last_purchase_at IS NULL AND last_browse_at IS NULL THEN 'new'
  WHEN last_purchase_at >= (NOW() - INTERVAL 30 DAY) THEN 'active'
  WHEN last_purchase_at <  (NOW() - INTERVAL 90 DAY) THEN 'dormant'
  ELSE lifecycle_stage
END;
