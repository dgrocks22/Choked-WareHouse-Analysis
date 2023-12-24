show databases;
create database choked;
use choked;
create table jsontable(json_data JSON);
load data infile 'C:/swift.json' into table jsontable(json_data);
select * from jsontable;
SELECT 
    JSON_UNQUOTE(JSON_EXTRACT(json_data, '$.latest_status')) AS latest_status,
    JSON_UNQUOTE(JSON_EXTRACT(json_data, '$.latest_location')) AS latest_location,
    JSON_UNQUOTE(JSON_EXTRACT(json_data, '$.shipment_id')) AS shipment_id,
    JSON_UNQUOTE(JSON_EXTRACT(json_data, '$.deduped_track_details')) AS deduped_track_details
FROM jsontable;

SELECT 
    JSON_UNQUOTE(JSON_EXTRACT(json_data, '$.latest_status')) AS latest_status,
    JSON_UNQUOTE(JSON_EXTRACT(json_data, '$.latest_location')) AS latest_location,
    JSON_UNQUOTE(JSON_EXTRACT(json_data, '$.shipment_id')) AS shipment_id,
    STR_TO_DATE(deduped.ctime, '%Y-%m-%d %H:%i:%s') AS ctime,
    deduped.location
FROM jsontable

CROSS JOIN JSON_TABLE(
    json_data->'$.deduped_track_details',
    '$[*]' COLUMNS (
        ctime VARCHAR(50) PATH '$.ctime',
        location VARCHAR(255) PATH '$.location'
    )
) AS deduped;
CREATE TABLE raw AS
SELECT 
    JSON_UNQUOTE(JSON_EXTRACT(json_data, '$.latest_status')) AS latest_status,
    JSON_UNQUOTE(JSON_EXTRACT(json_data, '$.latest_location')) AS latest_location,
    JSON_UNQUOTE(JSON_EXTRACT(json_data, '$.shipment_id')) AS shipment_id,
    STR_TO_DATE(SUBSTRING_INDEX(deduped.ctime,'.',1), '%Y-%m-%d %H:%i:%s UTC') AS ctime,
    deduped.location
FROM jsontable
CROSS JOIN JSON_TABLE(
    json_data->'$.deduped_track_details',
    '$[*]' COLUMNS (
        ctime VARCHAR(50) PATH '$.ctime',
        location VARCHAR(255) PATH '$.location'
    )
) AS deduped;
-- checking the blank values 
select * from raw 
where location=''; 
-- check the  NULL values in the location fields
select * from raw 
where location IS NULL;
delete from raw where location='';
delete from raw where location IS NULL;
-- now creating a table where my shipments have only one warehouse 
CREATE TABLE onewarehouse AS
SELECT
    shipment_id,
    latest_location,
    latest_status,
    MIN(ctime) AS start_time,
    MAX(ctime) AS end_time
FROM
    raw
GROUP BY
    shipment_id, latest_location, latest_status
HAVING
    COUNT(DISTINCT location) = 1;

select * from onewarehouse
where latest_status='In Transit' and latest_location='';
-- created a table for filling the location values in onewarehouse table 
CREATE TABLE raw_min_location AS
SELECT shipment_id, location
FROM (
    SELECT
        shipment_id,
        location,
        ROW_NUMBER() OVER (PARTITION BY shipment_id ORDER BY location) AS row_num
    FROM raw
) AS ranked
WHERE row_num = 1;
-- now updating the values in onewarehouse table 
UPDATE onewarehouse SET location = (SELECT raw_min_location.location FROM raw_min_location WHERE onewarehouse.shipment_id = raw_min_location.shipment_id);

-- updating the delay 
alter table onewarehouse add column delay INT;

UPDATE onewarehouse
SET delay= TIMESTAMPDIFF(HOUR, '2023-10-07 10:00:00', start_time)
WHERE latest_status = 'In Transit' AND latest_location IS NOT NULL AND latest_location <> '';
UPDATE onewarehouse
SET delay= TIMESTAMPDIFF(HOUR, end_time, start_time)
WHERE latest_status = 'In Transit' AND latest_location='';
UPDATE onewarehouse
SET delay= TIMESTAMPDIFF(HOUR, end_time, start_time)
WHERE latest_status = 'Delivered';
UPDATE onewarehouse
SET delay= TIMESTAMPDIFF(HOUR, '2023-10-07 10:00:00', end_time)
WHERE latest_status = 'Picked Up';
UPDATE onewarehouse
SET delay= TIMESTAMPDIFF(HOUR, '2023-10-07 10:00:00', end_time)
WHERE latest_status = 'Out for Delivery';

UPDATE onewarehouse
SET delay = ABS(delay);
CREATE TABLE average AS
SELECT
    location,
    AVG(ABS(delay)) AS average_delay
FROM onewarehouse
GROUP BY location;

ALTER TABLE onewarehouse
ADD COLUMN isdelayed BOOLEAN;


UPDATE onewarehouse
SET isdelayed = CASE WHEN delay > 48 THEN TRUE ELSE FALSE END;
-- adding a column in avergae table for number of occurences where numebr of delay occurences is stored
alter table average  add column occ int;
UPDATE average AS a
SET occ = (
    SELECT COUNT(*)
    FROM onewarehouse AS o
    WHERE o.location = a.location AND o.isdelayed = 1
);
select * from average
order by occ DESC, average_delay DESC;
-- NOW THIS GIVES US THE ANALYSIS FOR SHIPMENTS HAVING ONE WARE HOUSE 
 -- NOW FOR THE SHIPMENTS HAING MORE THAN ONE WAREHOSUE IS WHAT WE ARE DOING ANALYSIS NEXT 
-- first let's delete the shipments where there is one warehouse from the table raw 
DELETE raw
FROM raw
JOIN (
    SELECT shipment_id
    FROM raw
    GROUP BY shipment_id
    HAVING COUNT(DISTINCT location) = 1
) AS subquery ON raw.shipment_id = subquery.shipment_id;

-- Create a new table with rows where latest_status is Delivered
CREATE TABLE delivered AS
SELECT *
FROM raw
WHERE latest_status = 'Delivered';
-- Create a new table with rows where latest_status is In Transit
CREATE TABLE intrans AS
SELECT *
FROM raw
WHERE latest_status = 'In Transit';
-- Create a new table with rows where latest_status is Picked Up
CREATE TABLE pickedup AS
SELECT *
FROM raw
WHERE latest_status = 'Picked Up';
-- Create a new table with rows where latest_status is outfordelivery
CREATE TABLE outfordelivery AS
SELECT *
FROM raw
WHERE latest_status = 'Out for Delivery';
-- Create a new table with rows where latest_status is Shipment Delayed
CREATE TABLE delay AS
SELECT *
FROM raw
WHERE latest_status = 'Shipment Delayed';
-- now for columns where the parcel is delivered we just calculate a percentage of shipments delayed for which i select the threshold as 48 hours using difference in consecutive ctimes and labeling it as percentage delayed
-- i am storing these results into a new table as follows 
CREATE TABLE pickanalysis (
    location VARCHAR(255),
    percentage_delayed DECIMAL(10, 2),
    warehouse_status VARCHAR(50)
);

-- Insert the results into the new table
INSERT INTO pickanalysis
SELECT
    location,
    SUM(CASE WHEN time_difference > 172800 THEN 1 ELSE 0 END) / COUNT(*) * 100 AS percentage_delayed,
    CASE
        WHEN latest_status = 'SHIPMENT DELAYED' THEN
            'Need Immediate Attention'
        WHEN SUM(CASE WHEN time_difference > 172800 THEN 1 ELSE 0 END) / COUNT(*) * 100 > 20 THEN
            'Prioritize for Clearing'
        ELSE
            'Ignore'
    END AS warehouse_status
FROM (
    SELECT
        t1.location,
        t1.shipment_id,
        t1.latest_status,
        TIMESTAMPDIFF(SECOND, LAG(t1.ctime) OVER (PARTITION BY t1.shipment_id ORDER BY t1.ctime), t1.ctime) AS time_difference
    FROM (
        SELECT
            location,
            shipment_id,
            MAX(UPPER(latest_status)) AS latest_status,
            ctime
        FROM
            pickedup 
        GROUP BY
            location, shipment_id, ctime
    ) AS t1
) AS delayed_info
GROUP BY
    location, latest_status
ORDER BY
    percentage_delayed DESC;
-- updating the ofd analysis 
CREATE TABLE ofd AS
SELECT
    shipment_id,
    MAX(location) AS last_location,
    MAX(ctime) AS last_ctime
FROM
    outfordelivery
GROUP BY
    shipment_id;
-- Assuming your table is named last_location_ctime
ALTER TABLE ofd
ADD COLUMN delay_hours INT;
-- Update the delay_hours column with the calculated delay
UPDATE ofd
SET delay_hours = TIMESTAMPDIFF(HOUR, '2023-10-07 10:00:00', last_ctime);
alter table ofd  add column delay boolean;
UPDATE ofd SET delay = CASE WHEN delay_hours > 48 THEN TRUE ELSE FALSE END;
-- updating analysis for out for delivery and in transit
CREATE TABLE ofdfinal AS
SELECT
    last_location,
    AVG(ABS(delay_hours)) AS average_delay
FROM ofd
GROUP BY last_location;
alter table ofdfinal  add column occ int;
UPDATE ofdfinal AS a
SET occ = (
    SELECT COUNT(*)
    FROM ofd AS o
    WHERE o.last_location = a.last_location AND o.delay = 1
);
-- now doing it for intransit
CREATE TABLE intr AS
SELECT
    shipment_id,
    MAX(location) AS last_location,
    MAX(ctime) AS last_ctime
FROM
    intrans
GROUP BY
    shipment_id; 

ALTER TABLE intr
ADD COLUMN delay_hours INT;
-- Update the delay_hours column with the calculated delay
UPDATE intr
SET delay_hours = TIMESTAMPDIFF(HOUR, '2023-10-07 10:00:00', last_ctime);
alter table intr  add column delay boolean;
UPDATE intr SET delay = CASE WHEN abs(delay_hours) > 48 THEN TRUE ELSE FALSE END;

CREATE TABLE intrfinal AS
SELECT
    last_location,
    AVG(ABS(delay_hours)) AS average_delay
FROM intr
GROUP BY last_location;
alter table intrfinal  add column occ int;
UPDATE intrfinal AS a
SET occ = (
    SELECT COUNT(*)
    FROM intr AS o
    WHERE o.last_location = a.last_location AND o.delay = 1
);
------- done ---- 









