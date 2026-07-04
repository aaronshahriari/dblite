-- dblite demo queries.
-- Open this file in nvim, put the cursor inside a statement, and run it with
--   :Dblite run at      (run the whole buffer with  :Dblite run)
--
-- In the result (dbout) split:
--   L / H   next / previous page          [ / ]   previous / next in history
--   K       hover the SQL that ran        d       toggle [TYPE] annotations
--   gi      inspect the page untruncated  <C-c>   cancel an in-flight query

-- 1) 240 rows -> multiple pages. Press L / H in the result split to page through.
SELECT * FROM employees ORDER BY employee_id;

-- 2) A join. Try autocomplete here: after FROM/JOIN you get table names,
--    and after "e." you get that table's columns (blink.cmp).
SELECT e.employee_id, e.first_name, e.last_name, e.salary,
       d.department_name, d.location, e.status
FROM employees e
JOIN departments d ON d.department_id = e.department_id
ORDER BY e.salary DESC;

-- 3) Bind parameters, read from demo/dblite.binds.json in the cwd.
--    Launch nvim from the demo/ directory so dblite finds the binds file.
--    Edit the binds with  :Dblite binds  (or <leader>b).
SELECT first_name, last_name, salary, status
FROM employees
WHERE status = :status
  AND salary >= :min_salary
ORDER BY salary DESC;

-- 4) Aggregate: headcount and average pay per department.
SELECT d.department_name,
       COUNT(*)             AS headcount,
       ROUND(AVG(e.salary)) AS avg_salary
FROM employees e
JOIN departments d ON d.department_id = e.department_id
GROUP BY d.department_name
ORDER BY headcount DESC;
