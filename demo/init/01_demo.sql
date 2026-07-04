-- dblite demo schema for Oracle XE.
-- Runs automatically the first time the container's database is created.
--
-- gvenzl runs init scripts as SYS against the CDB root, so we switch into the
-- XEPDB1 pluggable database and create everything under a dedicated DEMO user.
-- A non-Oracle-maintained owner is what makes dblite's autocomplete pick the
-- tables up (it filters to all_users.oracle_maintained = 'N'), and it keeps
-- USER_TABLES clean — exactly the two demo tables, no internal noise.

ALTER SESSION SET CONTAINER = XEPDB1;

-- Idempotent: drop the user if a previous run left one behind.
BEGIN
  EXECUTE IMMEDIATE 'DROP USER demo CASCADE';
EXCEPTION WHEN OTHERS THEN NULL;
END;
/

CREATE USER demo IDENTIFIED BY demo;
GRANT CONNECT, RESOURCE, UNLIMITED TABLESPACE TO demo;

CREATE TABLE demo.departments (
  department_id   NUMBER        PRIMARY KEY,
  department_name VARCHAR2(40)  NOT NULL,
  location        VARCHAR2(40)
);

INSERT INTO demo.departments VALUES (10, 'Engineering',     'Seattle');
INSERT INTO demo.departments VALUES (20, 'Sales',           'New York');
INSERT INTO demo.departments VALUES (30, 'Marketing',       'Austin');
INSERT INTO demo.departments VALUES (40, 'Finance',         'Chicago');
INSERT INTO demo.departments VALUES (50, 'Human Resources', 'Denver');
INSERT INTO demo.departments VALUES (60, 'Support',         'Portland');
INSERT INTO demo.departments VALUES (70, 'Operations',      'Atlanta');
INSERT INTO demo.departments VALUES (80, 'Research',        'Boston');

CREATE TABLE demo.employees (
  employee_id   NUMBER        PRIMARY KEY,
  first_name    VARCHAR2(30),
  last_name     VARCHAR2(30),
  email         VARCHAR2(80),
  hire_date     DATE,
  salary        NUMBER(9,2),
  department_id NUMBER        REFERENCES demo.departments(department_id),
  status        VARCHAR2(10)
);

-- 240 procedurally generated employees: enough rows to show off paging,
-- a spread of DATE / NUMBER / VARCHAR2 columns, and a mix of statuses.
INSERT INTO demo.employees (employee_id, first_name, last_name, email, hire_date, salary, department_id, status)
SELECT
  level AS employee_id,
  CASE MOD(level, 10)
    WHEN 0 THEN 'Ava'    WHEN 1 THEN 'Liam'  WHEN 2 THEN 'Noah'  WHEN 3 THEN 'Emma'
    WHEN 4 THEN 'Olivia' WHEN 5 THEN 'Mia'   WHEN 6 THEN 'Lucas' WHEN 7 THEN 'Sofia'
    WHEN 8 THEN 'Ethan'  ELSE 'Isla' END,
  CASE MOD(TRUNC(level / 10), 10)
    WHEN 0 THEN 'Smith'  WHEN 1 THEN 'Nguyen' WHEN 2 THEN 'Patel' WHEN 3 THEN 'Garcia'
    WHEN 4 THEN 'Chen'   WHEN 5 THEN 'Okafor' WHEN 6 THEN 'Rossi' WHEN 7 THEN 'Kim'
    WHEN 8 THEN 'Haddad' ELSE 'Novak' END,
  'user' || level || '@example.com',
  DATE '2016-01-01' + NUMTODSINTERVAL(level * 6, 'DAY'),
  ROUND(40000 + DBMS_RANDOM.VALUE(0, 90000), -2),
  10 + MOD(level, 8) * 10,
  CASE WHEN MOD(level, 6) = 0 THEN 'INACTIVE' ELSE 'ACTIVE' END
FROM dual
CONNECT BY level <= 240;

COMMIT;
