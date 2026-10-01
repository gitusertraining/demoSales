-- UPS shipments: load, cleanse and aggregate inside DuckDB.
-- Executed statement-by-statement by the Talend job UPSJobs/UPS_DuckDB (tJava_1).
-- Placeholders replaced by the job at runtime from context variables:
--   ${UPS_INPUT_FILE}  -> context.ups_input_file
--   ${OUTPUT_DIR}      -> context.output_dir
-- Every statement must end with ';' at the end of a line.

-- 1. Raw staging: DuckDB reads the UPS extract directly (no row-by-row Talend flow).
CREATE OR REPLACE TABLE stg_ups_shipments AS
SELECT *
FROM read_csv('${UPS_INPUT_FILE}',
    header = true,
    delim = ',',
    dateformat = '%Y-%m-%d',
    columns = {
        'tracking_number': 'VARCHAR',
        'ship_date': 'DATE',
        'delivery_date': 'DATE',
        'service_level': 'VARCHAR',
        'origin_zip': 'VARCHAR',
        'dest_zip': 'VARCHAR',
        'dest_state': 'VARCHAR',
        'zone': 'INTEGER',
        'actual_weight_lbs': 'DECIMAL(10,2)',
        'billed_weight_lbs': 'DECIMAL(10,2)',
        'net_charge': 'DECIMAL(12,2)',
        'status': 'VARCHAR'
    });

-- 2. Standardise values once so rejects and clean rows share the same rules.
CREATE OR REPLACE TEMP VIEW v_ups_standardised AS
SELECT
    nullif(upper(trim(tracking_number)), '') AS tracking_number,
    ship_date,
    delivery_date,
    upper(trim(service_level)) AS service_level,
    trim(origin_zip) AS origin_zip,
    trim(dest_zip) AS dest_zip,
    upper(trim(dest_state)) AS dest_state,
    zone,
    actual_weight_lbs,
    billed_weight_lbs,
    net_charge,
    upper(trim(status)) AS status,
    CASE
        WHEN nullif(upper(trim(tracking_number)), '') IS NULL THEN 'MISSING_TRACKING_NUMBER'
        WHEN net_charge < 0 THEN 'NEGATIVE_NET_CHARGE'
        WHEN delivery_date < ship_date THEN 'DELIVERED_BEFORE_SHIPPED'
    END AS reject_reason
FROM stg_ups_shipments;

-- 3. Rejected rows, kept for review.
CREATE OR REPLACE TABLE ups_rejects AS
SELECT * EXCLUDE (reject_reason), reject_reason
FROM v_ups_standardised
WHERE reject_reason IS NOT NULL;

-- 4. Clean shipments: valid rows, one per tracking number, with derived metrics.
CREATE OR REPLACE TABLE ups_shipments_clean AS
SELECT
    * EXCLUDE (reject_reason),
    date_diff('day', ship_date, delivery_date) AS transit_days,
    round(net_charge / nullif(billed_weight_lbs, 0), 4) AS charge_per_lb
FROM v_ups_standardised
WHERE reject_reason IS NULL
QUALIFY row_number() OVER (PARTITION BY tracking_number ORDER BY ship_date DESC) = 1;

-- 5. Service-level summary consumed by the Talend flow (tFileInputDelimited_1).
CREATE OR REPLACE TABLE ups_service_summary AS
SELECT
    service_level,
    count(*) AS shipments,
    sum(billed_weight_lbs)::DOUBLE AS total_billed_weight_lbs,
    sum(net_charge)::DOUBLE AS total_net_charge,
    round(avg(net_charge), 2)::DOUBLE AS avg_net_charge,
    round(avg(transit_days), 2)::DOUBLE AS avg_transit_days,
    round(100.0 * count(*) FILTER (WHERE status = 'DELIVERED') / count(*), 2)::DOUBLE AS delivered_pct
FROM ups_shipments_clean
GROUP BY service_level
ORDER BY total_net_charge DESC;

-- 6. Exports.
COPY ups_service_summary TO '${OUTPUT_DIR}/ups_service_summary.csv' (HEADER, DELIMITER ';');
COPY ups_rejects TO '${OUTPUT_DIR}/ups_rejects.csv' (HEADER, DELIMITER ';');
COPY ups_shipments_clean TO '${OUTPUT_DIR}/ups_shipments_clean.parquet' (FORMAT PARQUET);
