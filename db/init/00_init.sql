-- 00_init.sql
CREATE DATABASE IF NOT EXISTS crm DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE crm;

-- 1) users
CREATE TABLE IF NOT EXISTS users (
  user_id            VARCHAR(64)  NOT NULL,
  customer_name      VARCHAR(64)  NULL,

  gender             ENUM('F','M','U') NOT NULL DEFAULT 'U',
  birth_year         SMALLINT NULL,
  region             VARCHAR(32) NULL,

  preferred_channel  ENUM('SMS','KAKAO','PUSH','EMAIL') NOT NULL DEFAULT 'SMS',
  sms_opt_in         TINYINT(1) NOT NULL DEFAULT 0,
  kakao_opt_in       TINYINT(1) NOT NULL DEFAULT 0,
  push_opt_in        TINYINT(1) NOT NULL DEFAULT 0,
  email_opt_in       TINYINT(1) NOT NULL DEFAULT 0,

  phone_e164         VARCHAR(20)  NULL,
  kakao_user_key     VARCHAR(128) NULL,
  push_token         VARCHAR(256) NULL,
  email              VARCHAR(128) NULL,

  created_at         DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at         DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (user_id),
  KEY idx_users_phone (phone_e164),
  KEY idx_users_demo (gender, birth_year, region),
  KEY idx_users_created (created_at)
) ENGINE=InnoDB;

-- 2) user_features
CREATE TABLE IF NOT EXISTS user_features (
  user_id               VARCHAR(64) NOT NULL,

  lifecycle_stage       ENUM('new','active','dormant','churned') NOT NULL DEFAULT 'new',

  last_browse_at        DATETIME NULL,
  last_cart_at          DATETIME NULL,
  last_purchase_at      DATETIME NULL,
  cart_items_count      INT NOT NULL DEFAULT 0,

  persona_id            VARCHAR(64) NULL,

  skin_type             ENUM('dry','oily','combination','normal','unknown')
                        NOT NULL DEFAULT 'unknown',

  skin_concern_primary  ENUM('sensitivity','acne','pigmentation','wrinkles','pores','redness','hydration','barrier','unknown')
                        NOT NULL DEFAULT 'unknown',
  sensitivity_level     ENUM('low','mid','high','unknown') NOT NULL DEFAULT 'unknown',
  top_category_30d      ENUM('skincare','makeup','hair','body','fragrance','unknown')
                        NOT NULL DEFAULT 'unknown',

  updated_at            DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (user_id),
  CONSTRAINT fk_features_user FOREIGN KEY (user_id) REFERENCES users(user_id)
    ON DELETE CASCADE ON UPDATE CASCADE,

  KEY idx_feat_lifecycle (lifecycle_stage),
  KEY idx_feat_last_browse (last_browse_at),
  KEY idx_feat_last_cart (last_cart_at),
  KEY idx_feat_last_purchase (last_purchase_at),
  KEY idx_feat_cart_items (cart_items_count),
  KEY idx_feat_persona (persona_id),
  KEY idx_feat_skin_type (skin_type),
  KEY idx_feat_beauty (skin_concern_primary, sensitivity_level, top_category_30d)
) ENGINE=InnoDB;

-- 3) user_events
CREATE TABLE IF NOT EXISTS user_events (
  event_id           BIGINT NOT NULL AUTO_INCREMENT,
  user_id            VARCHAR(64) NOT NULL,

  event_type         ENUM('BROWSE','ADD_TO_CART','REMOVE_FROM_CART','PURCHASE','SEARCH','WISHLIST') NOT NULL,
  occurred_at        DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,

  product_id         VARCHAR(64) NULL,
  category_id        VARCHAR(64) NULL,
  device             ENUM('WEB','APP','UNKNOWN') NOT NULL DEFAULT 'UNKNOWN',

  payload_json       JSON NULL,

  PRIMARY KEY (event_id),
  KEY idx_events_user_time (user_id, occurred_at),
  KEY idx_events_type_time (event_type, occurred_at),
  KEY idx_events_product_time (product_id, occurred_at),

  CONSTRAINT fk_events_user FOREIGN KEY (user_id) REFERENCES users(user_id)
    ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB;

-- 4) campaign_runs
CREATE TABLE IF NOT EXISTS campaign_runs (
  run_id CHAR(36) PRIMARY KEY,
  created_by VARCHAR(64) NOT NULL,
  status VARCHAR(32) NOT NULL,
  step_id VARCHAR(16) NULL,
  brief_json JSON NULL,
  channel VARCHAR(32) NULL,
  tone VARCHAR(32) NULL,
  target_json JSON NULL,
  selected_template_id VARCHAR(64) NULL,
  final_payload_json JSON NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- 5) handoffs
CREATE TABLE IF NOT EXISTS handoffs (
  handoff_id CHAR(36) PRIMARY KEY,
  run_id CHAR(36) NOT NULL,
  stage VARCHAR(64) NOT NULL,
  payload_json JSON NOT NULL,
  payload_version INT NOT NULL DEFAULT 1,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_handoffs_run_stage_created (run_id, stage, created_at),
  CONSTRAINT fk_handoffs_run
    FOREIGN KEY (run_id) REFERENCES campaign_runs(run_id)
    ON DELETE CASCADE
) ENGINE=InnoDB;

-- 6) campaign_approvals
CREATE TABLE IF NOT EXISTS campaign_approvals (
  approval_id CHAR(36) PRIMARY KEY,
  run_id CHAR(36) NOT NULL,
  marketer_id VARCHAR(64) NOT NULL,
  decision VARCHAR(16) NOT NULL,
  comment TEXT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_approvals_run_created (run_id, created_at),
  CONSTRAINT fk_approvals_run
    FOREIGN KEY (run_id) REFERENCES campaign_runs(run_id)
    ON DELETE CASCADE
) ENGINE=InnoDB;

-- 7) campaign_send_logs (최종형)
CREATE TABLE IF NOT EXISTS campaign_send_logs (
  send_log_id BIGINT NOT NULL AUTO_INCREMENT,

  run_id CHAR(36) NOT NULL,
  user_id VARCHAR(64) NOT NULL,

  campaign_goal VARCHAR(64) NOT NULL,
  channel ENUM('SMS','KAKAO','PUSH','EMAIL') NOT NULL,
  step_id VARCHAR(16) NOT NULL,
  candidate_id VARCHAR(16) NULL,
  status ENUM('CREATED','SENT','FAILED','SKIPPED') NOT NULL DEFAULT 'CREATED',

  rendered_text TEXT NULL,
  error_code VARCHAR(64) NULL,
  error_message VARCHAR(255) NULL,

  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  sent_at DATETIME NULL,

  PRIMARY KEY (send_log_id),
  KEY idx_runs_user_time (user_id, created_at),
  KEY idx_runs_campaign (campaign_goal, step_id, channel),
  KEY idx_sendlogs_run_user_time (run_id, user_id, created_at),

  CONSTRAINT fk_sendlogs_user FOREIGN KEY (user_id) REFERENCES users(user_id)
    ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_sendlogs_run FOREIGN KEY (run_id) REFERENCES campaign_runs(run_id)
    ON DELETE CASCADE
) ENGINE=InnoDB;
