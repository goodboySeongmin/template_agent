USE crm;

-- 1) run_id 타입을 campaign_runs와 맞추기 (CHAR(36))
ALTER TABLE campaign_send_logs
  MODIFY run_id CHAR(36) NOT NULL;

-- 2) PK 교체: send_log_id 추가 후 PK를 send_log_id로 변경
ALTER TABLE campaign_send_logs
  ADD COLUMN send_log_id BIGINT NOT NULL AUTO_INCREMENT FIRST,
  DROP PRIMARY KEY,
  ADD PRIMARY KEY (send_log_id);

-- 3) 조회/중복 방지용 인덱스(실무적으로 유용)
CREATE INDEX idx_sendlogs_run_user_time
  ON campaign_send_logs(run_id, user_id, created_at);

-- 4) run_id FK 추가 (run이 삭제되면 로그도 같이 삭제)
ALTER TABLE campaign_send_logs
  ADD CONSTRAINT fk_sendlogs_run
    FOREIGN KEY (run_id) REFERENCES campaign_runs(run_id)
    ON DELETE CASCADE;

-- user_id FK는 이미 있으니 유지
