--
-- PostgreSQL database dump
--

-- Dumped from database version 17.4
-- Dumped by pg_dump version 17.6 (Ubuntu 17.6-2.pgdg22.04+1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: timescaledb; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS timescaledb WITH SCHEMA public;


--
-- Name: EXTENSION timescaledb; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION timescaledb IS 'Enables scalable inserts and complex queries for time-series data (Community Edition)';


--
-- Name: monitoring; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA monitoring;


--
-- Name: SCHEMA monitoring; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA monitoring IS 'monitoring schema';


--
-- Name: pg_stat_statements; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_stat_statements WITH SCHEMA public;


--
-- Name: EXTENSION pg_stat_statements; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_stat_statements IS 'track planning and execution statistics of all SQL statements executed';


SET search_path = public, monitoring, pg_catalog;


--
-- Name: compute_uptime_series(timestamp with time zone); Type: FUNCTION; Schema: monitoring; Owner: -
--

CREATE FUNCTION monitoring.compute_uptime_series(startdate timestamp with time zone DEFAULT '2024-01-01 01:00:00+01'::timestamp with time zone) RETURNS TABLE(dt timestamp with time zone, du bigint, uptime numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    WITH all_times AS (
        SELECT DISTINCT datetime
        FROM mesures
		where datetime > startdate - INTERVAL '15 minutes'
        ORDER BY datetime
    ),
    all_du_ids AS (
        SELECT DISTINCT du_id FROM mesures
    ),
    time_du_matrix AS (
        SELECT t.datetime, d.du_id
        FROM all_times t
        CROSS JOIN all_du_ids d
    ),
    present_data AS (
        SELECT datetime, du_id FROM mesures
    ),
    marked_status AS (
        SELECT m.datetime,
               m.du_id,
               CASE WHEN p.du_id IS NOT NULL THEN true ELSE false END AS is_present
        FROM time_du_matrix m
        LEFT JOIN present_data p
        ON m.datetime = p.datetime AND m.du_id = p.du_id
    ),
    with_lag AS (
        SELECT *,
               LAG(is_present) OVER (PARTITION BY du_id ORDER BY datetime) AS was_present,
               LAG(datetime) OVER (PARTITION BY du_id ORDER BY datetime) AS prev_datetime
        FROM marked_status
    ),
    with_delta AS (
        SELECT *,
               CASE
                   WHEN is_present AND was_present THEN datetime - prev_datetime
                   ELSE INTERVAL '0'
               END AS delta
        FROM with_lag
    ),
    -- Increment group whenever presence is false (missing)
    with_group AS (
        SELECT *,
               SUM(CASE WHEN NOT is_present THEN 1 ELSE 0 END)
                   OVER (PARTITION BY du_id ORDER BY datetime ROWS UNBOUNDED PRECEDING) AS group_id
        FROM with_delta
    )
    SELECT datetime, du_id,
           EXTRACT(EPOCH FROM SUM(delta) OVER (PARTITION BY du_id, group_id ORDER BY datetime)) AS uptime
    FROM with_group
    ORDER BY du_id, datetime;
END;
$$;


--
-- Name: device_uptime_in_range_all(timestamp with time zone, timestamp with time zone); Type: FUNCTION; Schema: monitoring; Owner: -
--

CREATE FUNCTION monitoring.device_uptime_in_range_all(start_time timestamp with time zone, end_time timestamp with time zone) RETURNS TABLE(du bigint, uptime_seconds numeric, uptime_percentage numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
        WITH all_devices AS (
        SELECT DISTINCT du_id FROM monitoring.mesures
    ),
	timeperiod AS (
		SELECT
			EXTRACT(EPOCH FROM (MAX(datetime)  - MIN(datetime))) + 60 AS duration,
			MIN(datetime) as min_time,
			MAX(datetime) as max_time
		FROM
			monitoring.mesures m
        WHERE datetime BETWEEN start_time AND end_time
	),
all_times AS (
    SELECT 
        datetime,
        LAG(datetime) OVER (ORDER BY datetime) AS prev_datetime
    FROM (
        SELECT DISTINCT datetime
        FROM monitoring.mesures 
        WHERE datetime BETWEEN start_time AND end_time
    ) dt
),
    device_data AS (
        SELECT 
            d.du_id,
            a.datetime,
			a.prev_datetime,
			m.temperature,
			LAG(temperature) OVER (PARTITION BY d.du_id ORDER BY a.datetime) as prev_temp
        FROM all_times a  CROSS JOIN all_devices d LEFT  JOIN monitoring.mesures m ON a.datetime=m.datetime AND m.du_id = d.du_id
    )

,device_uptime AS (
        SELECT
            d.du_id,
            SUM(
                CASE 
                    WHEN temperature IS NOT NULL THEN 
						CASE
							WHEN prev_datetime IS NOT NULL THEN
								CASE WHEN prev_temp IS NOT NULL THEN
									CASE WHEN (datetime - prev_datetime) < INTERVAL '1 hour' THEN
                        				EXTRACT(EPOCH FROM (datetime - prev_datetime))
									ELSE
										0
									END
								ELSE
									0
								END
							ELSE 60 -- For first record
						END
                    ELSE 0  
                END
            ) AS uptime_seconds_raw
        FROM device_data d
        GROUP BY d.du_id
    )
    SELECT 
        a.du_id,
        COALESCE(d.uptime_seconds_raw,0) AS uptime_seconds,
        COALESCE(ROUND(
            (d.uptime_seconds_raw / p.duration) * 100, 
            2
        )::NUMERIC, 0) AS uptime_percentage
    FROM all_devices a LEFT JOIN device_uptime d on a.du_id=d.du_id, timeperiod p;
END;
$$;


--
-- Name: devices_uptime(); Type: FUNCTION; Schema: monitoring; Owner: -
--

CREATE FUNCTION monitoring.devices_uptime() RETURNS TABLE(date timestamp with time zone, du bigint, uptime_seconds numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    WITH all_devices AS (
        SELECT DISTINCT du_id FROM mesures
    ),
	timeperiod AS (
		SELECT
			EXTRACT(EPOCH FROM (MAX(datetime)  - MIN(datetime))) + 60 AS duration,
			MIN(datetime) as min_time,
			MAX(datetime) as max_time
		FROM
			mesures m
	),
    device_data AS (
        SELECT 
            m.du_id,
            datetime,
            LEAD(datetime) OVER w AS next_datetime
        FROM mesures m
        WINDOW w AS (PARTITION BY m.du_id ORDER BY datetime)
    )
	SELECT
		datetime,
		d.du_id,
		SUM(
			CASE 
				WHEN next_datetime IS NOT NULL THEN 
					EXTRACT(EPOCH FROM (next_datetime - datetime))
				ELSE 0  
			END
		) AS uptime_seconds_raw
	FROM all_devices a LEFT JOIN device_data d on a.du_id=d.du_id
	GROUP BY d.du_id, datetime;
    
END;
$$;


--
-- Name: get_uptimes_series(timestamp with time zone, timestamp with time zone); Type: FUNCTION; Schema: monitoring; Owner: -
--

CREATE FUNCTION monitoring.get_uptimes_series(start_ts timestamp with time zone, end_ts timestamp with time zone) RETURNS TABLE(dt timestamp with time zone, du text, uptime numeric)
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
    RETURN QUERY
    WITH all_times AS (
        SELECT DISTINCT datetime
        FROM mesures
        WHERE datetime BETWEEN start_ts AND end_ts
    ),
    all_du_ids AS (
        SELECT DISTINCT du_id FROM mesures
    ),
    time_du_matrix AS (
        SELECT t.datetime, d.du_id
        FROM all_times t
        CROSS JOIN all_du_ids d
    )
    SELECT 
        a.datetime AS time, 
        a.du_id::TEXT AS metric, 
        COALESCE(m.uptime, 0) AS uptime
    FROM time_du_matrix a
    LEFT JOIN mesures m  
        ON a.datetime = m.datetime AND a.du_id = m.du_id
    ORDER BY time, a.du_id;
END;
$$;


--
-- Name: update_uptime(timestamp with time zone); Type: FUNCTION; Schema: monitoring; Owner: -
--

CREATE FUNCTION monitoring.update_uptime(startdate timestamp with time zone DEFAULT '2024-01-01 01:00:00+01'::timestamp with time zone) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    WITH all_times AS (
        SELECT DISTINCT datetime
        FROM mesures
        WHERE datetime >= startdate 
    ),
    all_du_ids AS (
        SELECT DISTINCT du_id FROM mesures
    ),
    time_du_matrix AS (
        SELECT t.datetime, d.du_id
        FROM all_times t
        CROSS JOIN all_du_ids d
    ),
    present_data AS (
        SELECT datetime, du_id FROM mesures
    ),
    marked_status AS (
        SELECT m.datetime,
               m.du_id,
               CASE WHEN p.du_id IS NOT NULL THEN true ELSE false END AS is_present
        FROM time_du_matrix m
        LEFT JOIN present_data p
        ON m.datetime = p.datetime AND m.du_id = p.du_id
    ),
    with_lag AS (
        SELECT *,
               LAG(is_present) OVER (PARTITION BY du_id ORDER BY datetime) AS was_present,
               LAG(datetime) OVER (PARTITION BY du_id ORDER BY datetime) AS prev_datetime
        FROM marked_status
    ),
    with_delta AS (
        SELECT *,
               CASE
                   WHEN is_present AND was_present THEN datetime - prev_datetime
                   ELSE INTERVAL '0'
               END AS delta
        FROM with_lag
    ),
    with_group AS (
        SELECT *,
               SUM(CASE WHEN NOT is_present THEN 1 ELSE 0 END)
               OVER (PARTITION BY du_id ORDER BY datetime ROWS UNBOUNDED PRECEDING) AS group_id
        FROM with_delta
    ),
    present_rows AS (
        SELECT datetime, du_id, group_id, delta
        FROM with_group
        WHERE is_present
    ),
    base_uptime AS (
        SELECT du_id, MAX(datetime) AS last_time
        FROM mesures
        WHERE datetime <= startdate AND uptime IS NOT NULL
        GROUP BY du_id
    ),
    base_values AS (
        SELECT b.du_id, m.uptime AS base_uptime
        FROM base_uptime b
        JOIN mesures m ON m.du_id = b.du_id AND m.datetime = b.last_time
    ),
    computed_uptime AS (
        SELECT pr.datetime,
               pr.du_id,
               CASE 
                   WHEN pr.group_id = 0 THEN
                       COALESCE(b.base_uptime, 0) + EXTRACT(EPOCH FROM SUM(delta) OVER (PARTITION BY pr.du_id, group_id ORDER BY datetime))
                   ELSE
                       EXTRACT(EPOCH FROM SUM(delta) OVER (PARTITION BY pr.du_id, group_id ORDER BY datetime))
               END AS uptime
        FROM present_rows pr
        LEFT JOIN base_values b ON pr.du_id = b.du_id
    )
    UPDATE mesures m
    SET uptime = cu.uptime
    FROM computed_uptime cu
    WHERE m.datetime = cu.datetime AND m.du_id = cu.du_id;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: spectres; Type: TABLE; Schema: monitoring; Owner: -
--

CREATE TABLE monitoring.spectres (
    datetime timestamp with time zone NOT NULL,
    du_id bigint NOT NULL,
    len integer NOT NULL,
    powers_0 double precision[],
    powers_1 double precision[],
    powers_2 double precision[],
    powers_3 double precision[],
    weight integer,
    ts_list bigint[]
);


--
-- Name: mesures; Type: TABLE; Schema: monitoring; Owner: -
--

CREATE TABLE monitoring.mesures (
    datetime timestamp with time zone NOT NULL,
    du_id bigint NOT NULL,
    temperature double precision,
    voltage double precision,
    weight integer,
    uptime numeric,
    ts_list bigint[]
);



--
-- Name: antennas; Type: TABLE; Schema: monitoring; Owner: -
--

CREATE TABLE monitoring.antennas (
    longitude double precision NOT NULL,
    latitude double precision NOT NULL,
    du_id integer NOT NULL,
    altitude double precision
);


--
-- Name: files; Type: TABLE; Schema: monitoring; Owner: -
--

CREATE TABLE monitoring.files (
    filename character varying NOT NULL,
    date_record timestamp with time zone NOT NULL
);


--
-- Name: frequences; Type: TABLE; Schema: monitoring; Owner: -
--

CREATE TABLE monitoring.frequences (
    len integer NOT NULL,
    freq double precision[] NOT NULL
);



--
-- Name: antennas antenna_du_id_key; Type: CONSTRAINT; Schema: monitoring; Owner: -
--

ALTER TABLE ONLY monitoring.antennas
    ADD CONSTRAINT antenna_du_id_key UNIQUE (du_id);


--
-- Name: antennas antennas_pkey; Type: CONSTRAINT; Schema: monitoring; Owner: -
--

ALTER TABLE ONLY monitoring.antennas
    ADD CONSTRAINT antennas_pkey PRIMARY KEY (du_id);


--
-- Name: files files_pkey; Type: CONSTRAINT; Schema: monitoring; Owner: -
--

ALTER TABLE ONLY monitoring.files
    ADD CONSTRAINT files_pkey PRIMARY KEY (filename);


--
-- Name: frequences frequences_pkey; Type: CONSTRAINT; Schema: monitoring; Owner: -
--

ALTER TABLE ONLY monitoring.frequences
    ADD CONSTRAINT frequences_pkey PRIMARY KEY (len);


--
-- Name: mesures mesures_pkey; Type: CONSTRAINT; Schema: monitoring; Owner: -
--

ALTER TABLE ONLY monitoring.mesures
    ADD CONSTRAINT mesures_pkey PRIMARY KEY (datetime, du_id);


--
-- Name: spectres spectres_pkey; Type: CONSTRAINT; Schema: monitoring; Owner: -
--

ALTER TABLE ONLY monitoring.spectres
    ADD CONSTRAINT spectres_pkey PRIMARY KEY (datetime, du_id);



--
-- Name: mesures_datetime_idx; Type: INDEX; Schema: monitoring; Owner: -
--

CREATE INDEX mesures_datetime_idx ON monitoring.mesures USING btree (datetime DESC);


--
-- Name: spectres_datetime_idx; Type: INDEX; Schema: monitoring; Owner: -
--

CREATE INDEX spectres_datetime_idx ON monitoring.spectres USING btree (datetime DESC);


SELECT create_hypertable('monitoring.spectres', 'datetime');
SELECT create_hypertable('monitoring.mesures', 'datetime');

--
-- PostgreSQL database dump complete
--


