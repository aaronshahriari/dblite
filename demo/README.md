# dblite.nvim demo

A self-contained local Oracle to try/show off dblite. It runs Oracle XE in Docker,
seeds a small `departments` + `employees` schema, and points dblite at it.

## What's here

| File | Purpose |
|---|---|
| `docker-compose.yml` | Oracle XE (`gvenzl/oracle-xe`), password `oracle`, port `1521` |
| `init/01_demo.sql` | Seed schema: 8 departments, 240 employees (auto-run on first start) |
| `queries.sql` | Example statements to run in nvim |
| `dblite.binds.json` | Sample bind values for query #3 |

## Run it

**1. Start Oracle** (first run pulls ~2 GB, then seeds — give it a couple of minutes):

```sh
cd demo
docker compose up -d
docker compose logs -f          # wait for "DATABASE IS READY TO USE", then Ctrl-C
```

**2. Make sure the dblite binary is present.** Inside nvim:

```vim
:DbliteBuild
```

(Downloads the prebuilt native binary for your platform. Only needed once.)

**3. Register the connection** — the seed creates a dedicated `demo` user
(password `demo`) inside `XEPDB1`, which is what you connect as:

```vim
:DbliteAddConn oracle://demo:demo@localhost:1521/XEPDB1
:DbliteUseConn XEPDB1
```

**4. Run queries.** Open `queries.sql` from this directory (so the binds file is
found), put the cursor in a statement, and:

```vim
:Dblite run at
```

Results open in the **dbout** split. Page with `L`/`H`, walk history with `[`/`]`,
`K` to see the SQL, `d` to toggle `[TYPE]` headers, `gi` to inspect untruncated.

Try an export too:

```vim
:Dblite export csv ./employees.csv
```

## Tear down

```sh
docker compose down             # stop + remove the container (data is ephemeral)
```

The schema re-seeds automatically the next time you `docker compose up`.

## Notes

- Connection string breakdown: `demo` / `demo` are the DB user/password the
  seed script creates, `localhost:1521` is the mapped port, and `XEPDB1` is the
  pluggable database gvenzl creates by default. (The image runs init scripts as
  SYS against the CDB root, so the seed does `ALTER SESSION SET CONTAINER =
  XEPDB1` and creates the `demo` user there — see `init/01_demo.sql`.)
- Want the completion demo? Add the `dblite` blink.cmp source (see the main
  README's Autocomplete section); schema is fetched on `:DbliteUseConn`.
