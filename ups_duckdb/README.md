# UPS – DuckDB Talend approach

Talend job: `DEMOSALES/process/UPSJobs/UPS_DuckDB_0.1.item` (Job Designs ▸ UPSJobs ▸ UPS_DuckDB).

Talend orchestrates the job and DuckDB does the data work. The UPS extract is not pushed
row by row through Talend components. DuckDB reads the CSV, cleanses it, aggregates it and
exports the results in SQL. Talend then reads the small summary back into a normal flow.

```
tLibraryLoad_1 ──OnSubjobOk──▶ tJava_1 ──OnSubjobOk──▶ tFileInputDelimited_1 ──row1──▶ tLogRow_1
(DuckDB JDBC jar)          (runs sql/ups_transform.sql)   (ups_service_summary.csv)
```

## What the SQL does (`sql/ups_transform.sql`)

| Step | DuckDB object | Purpose |
|---|---|---|
| 1 | `stg_ups_shipments` | `read_csv` of the UPS extract with explicit types (ZIPs kept as text) |
| 2 | `v_ups_standardised` | Trim and upper-case the values, then assign a `reject_reason` |
| 3 | `ups_rejects` | Rows with a missing tracking number, a negative charge, or delivery before ship date |
| 4 | `ups_shipments_clean` | Valid rows, deduplicated per tracking number, plus `transit_days` and `charge_per_lb` |
| 5 | `ups_service_summary` | Shipments, weight, charges, average transit time and delivered % per service level |
| 6 | exports | `ups_service_summary.csv`, `ups_rejects.csv` (`;`-delimited), `ups_shipments_clean.parquet` |

`tJava_1` replaces `${UPS_INPUT_FILE}` and `${OUTPUT_DIR}` in the script. It then runs each
statement, which must end with `;` at the end of a line. It also sets these globalMap values:
`UPS_RAW_ROWS`, `UPS_CLEAN_ROWS`, `UPS_REJECT_ROWS` and `UPS_SUMMARY_FILE`.

## Context variables

| Name | Default | Notes |
|---|---|---|
| `ups_input_file` | `C:/Users/nrehman/NagmaRemote/UPS/ups_shipments.csv` | UPS extract, comma-delimited, with a header |
| `ups_sql_file` | `C:/Users/nrehman/NagmaRemote/UPS/sql/ups_transform.sql` | Point this at this repo's `sql/ups_transform.sql` |
| `duckdb_file` | `C:/Users/nrehman/NagmaRemote/UPS/ups.duckdb` | Leave empty for an in-memory database |
| `output_dir` | `C:/Users/nrehman/NagmaRemote/UPS/out` | Created if it does not exist |

## Setup in Studio

1. Install the DuckDB JDBC driver from the Modules view or the `tLibraryLoad_1` prompt:
   `mvn:org.duckdb/duckdb_jdbc/1.1.3` (`duckdb_jdbc-1.1.3.jar`). It bundles the native
   libraries for Windows, Linux and macOS.
2. Copy `sample_data/ups_shipments.csv` and `sql/ups_transform.sql` to the context paths,
   or change the context values.
3. Run the job. With the sample file, the counts are raw=12, clean=8 and rejects=3
   (one duplicate tracking number is dropped).

To change the column layout of the UPS file, edit the `columns = {...}` block in step 1 of
the SQL script. No job change is needed unless the summary columns change.
