USE crm;

-- ============================================================
-- 02_seed.sql (FIXED)
-- - Creates/Upserts 50 demo users (u_001 ~ u_050)
-- - Creates/Upserts 50 demo user_features rows
-- - Distributions are balanced:
--   gender(F/M), birth_year(10/20/30/40/50+), skin_type(4), skin_concern_primary(8)
-- - No CTE / No TEMP TABLE (safer for SOURCE / pipe)
-- ============================================================

/* ------------------------------------------------------------
  1) users: u_001 ~ u_050
------------------------------------------------------------ */
INSERT INTO users
  (user_id, customer_name, gender, birth_year, region,
   preferred_channel, sms_opt_in, kakao_opt_in, push_opt_in, email_opt_in,
   phone_e164, kakao_user_key, push_token, email)
SELECT
  CONCAT('u_', LPAD(seq.n, 3, '0'))                   AS user_id,
  CONCAT('User', LPAD(seq.n, 3, '0'))                AS customer_name,

  -- gender: F/M evenly
  CASE WHEN MOD(seq.n, 2) = 0 THEN 'M' ELSE 'F' END  AS gender,

  -- birth_year: 10/20/30/40/50+ 골고루 (2025 기준)
  CASE MOD(seq.n, 5)
    WHEN 1 THEN (2006 + MOD(seq.n, 10))  -- 10대: 2006~2015
    WHEN 2 THEN (1996 + MOD(seq.n, 10))  -- 20대: 1996~2005
    WHEN 3 THEN (1986 + MOD(seq.n, 10))  -- 30대: 1986~1995
    WHEN 4 THEN (1976 + MOD(seq.n, 10))  -- 40대: 1976~1985
    ELSE (1966 + MOD(seq.n, 10))         -- 50대+: 1966~1975
  END AS birth_year,

  -- region: rotate 5 cities
  CASE MOD(seq.n, 5)
    WHEN 0 THEN 'Seoul'
    WHEN 1 THEN 'Busan'
    WHEN 2 THEN 'Incheon'
    WHEN 3 THEN 'Daegu'
    ELSE 'Gwangju'
  END AS region,

  'SMS' AS preferred_channel,

  -- sms_opt_in: 대부분 1, 일부 0
  CASE WHEN MOD(seq.n, 7) = 0 THEN 0 ELSE 1 END AS sms_opt_in,
  0 AS kakao_opt_in,
  0 AS push_opt_in,
  0 AS email_opt_in,

  -- phone: +8210 + 8 digits
  CONCAT('+8210', LPAD(seq.n, 8, '0')) AS phone_e164,

  NULL AS kakao_user_key,
  NULL AS push_token,
  NULL AS email
FROM (
  SELECT (a.d + b.d * 10 + 1) AS n
  FROM
    (SELECT 0 AS d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
     UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) a
  CROSS JOIN
    (SELECT 0 AS d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4) b
  WHERE (a.d + b.d * 10 + 1) <= 50
) AS seq
ON DUPLICATE KEY UPDATE
  customer_name      = VALUES(customer_name),
  gender             = VALUES(gender),
  birth_year         = VALUES(birth_year),
  region             = VALUES(region),
  preferred_channel  = VALUES(preferred_channel),
  sms_opt_in         = VALUES(sms_opt_in),
  kakao_opt_in       = VALUES(kakao_opt_in),
  push_opt_in        = VALUES(push_opt_in),
  email_opt_in       = VALUES(email_opt_in),
  phone_e164         = VALUES(phone_e164),
  updated_at         = CURRENT_TIMESTAMP;


/* ------------------------------------------------------------
  2) user_features: 50 rows
  - skin_type: dry/oily/combination/normal (골고루)
  - skin_concern_primary: 8개 골고루 (피부진정/주름탄력/미백/보습/모공 매핑이 타겟에서 잘 걸리도록)
------------------------------------------------------------ */
INSERT INTO user_features
  (user_id, lifecycle_stage, last_browse_at, last_cart_at, last_purchase_at,
   cart_items_count, persona_id, skin_type,
   skin_concern_primary, sensitivity_level, top_category_30d)
SELECT
  CONCAT('u_', LPAD(seq.n, 3, '0')) AS user_id,

  -- lifecycle: new/active/dormant 골고루
  CASE
    WHEN MOD(seq.n, 10) = 0 THEN 'dormant'
    WHEN MOD(seq.n,  3) = 0 THEN 'new'
    ELSE 'active'
  END AS lifecycle_stage,

  (NOW() - INTERVAL MOD(seq.n, 14) DAY) AS last_browse_at,
  CASE WHEN MOD(seq.n, 4) = 0 THEN NULL ELSE (NOW() - INTERVAL MOD(seq.n, 48) HOUR) END AS last_cart_at,
  CASE WHEN MOD(seq.n, 5) = 0 THEN NULL ELSE (NOW() - INTERVAL MOD(seq.n, 60) DAY) END AS last_purchase_at,

  MOD(seq.n, 4) AS cart_items_count,

  CASE WHEN MOD(seq.n, 2) = 0 THEN 'ingredient_care' ELSE 'hydration' END AS persona_id,

  -- skin_type: 4종 균등
  CASE MOD(seq.n, 4)
    WHEN 0 THEN 'dry'
    WHEN 1 THEN 'oily'
    WHEN 2 THEN 'combination'
    ELSE 'normal'
  END AS skin_type,

  -- skin_concern_primary: 8종 균등
  -- (피부진정 = sensitivity/redness/barrier/acne)
  -- (주름/탄력 = wrinkles)
  -- (미백/자외선차단 = pigmentation)
  -- (영양/보습 = hydration/barrier)
  -- (블랙헤드/모공/피지 = pores)
  CASE MOD(seq.n, 8)
    WHEN 0 THEN 'sensitivity'
    WHEN 1 THEN 'acne'
    WHEN 2 THEN 'wrinkles'
    WHEN 3 THEN 'pigmentation'
    WHEN 4 THEN 'hydration'
    WHEN 5 THEN 'pores'
    WHEN 6 THEN 'redness'
    ELSE 'barrier'
  END AS skin_concern_primary,

  -- sensitivity_level: 진정/장벽 계열은 높게, 나머지는 mid 위주
  CASE MOD(seq.n, 8)
    WHEN 0 THEN 'high'   -- sensitivity
    WHEN 1 THEN 'mid'    -- acne
    WHEN 2 THEN 'mid'    -- wrinkles
    WHEN 3 THEN 'mid'    -- pigmentation
    WHEN 4 THEN 'mid'    -- hydration
    WHEN 5 THEN 'mid'    -- pores
    WHEN 6 THEN 'high'   -- redness
    ELSE 'high'          -- barrier
  END AS sensitivity_level,

  CASE MOD(seq.n, 5)
    WHEN 0 THEN 'skincare'
    WHEN 1 THEN 'makeup'
    WHEN 2 THEN 'hair'
    WHEN 3 THEN 'body'
    ELSE 'fragrance'
  END AS top_category_30d
FROM (
  SELECT (a.d + b.d * 10 + 1) AS n
  FROM
    (SELECT 0 AS d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
     UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) a
  CROSS JOIN
    (SELECT 0 AS d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4) b
  WHERE (a.d + b.d * 10 + 1) <= 50
) AS seq
ON DUPLICATE KEY UPDATE
  lifecycle_stage      = VALUES(lifecycle_stage),
  last_browse_at       = VALUES(last_browse_at),
  last_cart_at         = VALUES(last_cart_at),
  last_purchase_at     = VALUES(last_purchase_at),
  cart_items_count     = VALUES(cart_items_count),
  persona_id           = VALUES(persona_id),
  skin_type            = VALUES(skin_type),
  skin_concern_primary = VALUES(skin_concern_primary),
  sensitivity_level    = VALUES(sensitivity_level),
  top_category_30d     = VALUES(top_category_30d),
  updated_at           = CURRENT_TIMESTAMP;


/* ------------------------------------------------------------
  3) Debug
------------------------------------------------------------ */
SELECT COUNT(*) AS users_cnt FROM users;
SELECT COUNT(*) AS features_cnt FROM user_features;

SELECT skin_type, COUNT(*) AS cnt
FROM user_features
GROUP BY skin_type
ORDER BY skin_type;

SELECT skin_concern_primary, COUNT(*) AS cnt
FROM user_features
GROUP BY skin_concern_primary
ORDER BY skin_concern_primary;
