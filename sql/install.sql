-- ============================================================
--  ServerDepth Events — sql/install.sql
--  Run this once against your server database before starting
--  the resource. The resource also creates this table
--  automatically on start if it is missing.
-- ============================================================

CREATE TABLE IF NOT EXISTS `events_log` (
  `id`               INT            NOT NULL AUTO_INCREMENT,
  `event_id`         VARCHAR(50)    NOT NULL UNIQUE,
  `event_type`       VARCHAR(50)    NOT NULL,
  `started_at`       TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `ended_at`         TIMESTAMP      NULL,
  `winner_citizenid` VARCHAR(50)    NULL,
  `participants`     JSON           NULL,
  `rewards_given`    JSON           NULL,
  `triggered_by`     ENUM('schedule','admin','test') NOT NULL DEFAULT 'schedule',
  PRIMARY KEY (`id`),
  INDEX `idx_event_type`  (`event_type`),
  INDEX `idx_started_at`  (`started_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
