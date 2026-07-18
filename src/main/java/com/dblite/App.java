package com.dblite;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.Statement;
import java.sql.Types;

public class App {
    public static void main(String[] args) {
        String url = System.getenv("DB_URL");
        String user = System.getenv("DB_USER");
        String password = System.getenv("DB_PASSWORD");

        if (url == null) {
            System.err.println("Missing required env var: DB_URL");
            System.err.println("Example DB_URL: jdbc:oracle:thin:@//localhost:1521/XEPDB1  or  jdbc:sqlserver://localhost:1433;databaseName=MyDB");
            System.exit(1);
        }
        boolean integratedAuth = url.toLowerCase().contains("integratedsecurity=true");
        if (!integratedAuth && (user == null || password == null)) {
            System.err.println("Missing required env vars: DB_USER, DB_PASSWORD (not required for integratedSecurity=true)");
            System.exit(1);
        }

        int maxRows = 0;
        boolean scriptMode = false;
        String toFile = null;
        String format = "csv";
        for (int i = 0; i < args.length; i++) {
            if ("--max-rows".equals(args[i]) && i + 1 < args.length) {
                try {
                    maxRows = Integer.parseInt(args[++i]);
                } catch (NumberFormatException e) {
                    System.err.println("Invalid --max-rows value: " + args[i]);
                    System.exit(1);
                }
            } else if ("--script".equals(args[i])) {
                scriptMode = true;
            } else if ("--to-file".equals(args[i]) && i + 1 < args.length) {
                toFile = args[++i];
            } else if ("--format".equals(args[i]) && i + 1 < args.length) {
                format = args[++i];
            }
        }

        String query;
        try {
            query = new String(System.in.readAllBytes(), java.nio.charset.StandardCharsets.UTF_8).trim();
            // In script mode the splitter handles terminators per-statement; only
            // the single-statement path strips a lone trailing ;/ for convenience.
            if (!scriptMode) query = query.replaceAll("[;/]\\s*$", "").trim();
        } catch (java.io.IOException e) {
            System.err.println("Failed to read query from stdin: " + e.getMessage());
            System.exit(1);
            return;
        }
        if (query.isEmpty()) {
            System.err.println("No query provided on stdin");
            System.exit(1);
        }

        if (scriptMode) {
            runScript(query, url, user, password, integratedAuth);
            return;
        }

        try (Connection conn = integratedAuth
                 ? DriverManager.getConnection(url)
                 : DriverManager.getConnection(url, user, password);
             Statement stmt = conn.createStatement()) {

            if (maxRows > 0) stmt.setMaxRows(maxRows);
            // Bulk dumps stream to a file; a larger fetch size drastically cuts
            // round-trips on big result sets (Oracle defaults to 10 rows/fetch).
            if (toFile != null) stmt.setFetchSize(1000);

            boolean hasResultSet = stmt.execute(query);

            if (hasResultSet && toFile != null) {
                try (ResultSet rs = stmt.getResultSet()) {
                    ResultSetMetaData meta = rs.getMetaData();
                    writeToFile(rs, meta, meta.getColumnCount(), toFile, format);
                }
            } else if (hasResultSet) {
                try (ResultSet rs = stmt.getResultSet()) {
                    ResultSetMetaData meta = rs.getMetaData();
                    int columnCount = meta.getColumnCount();

                    System.out.print("{\"columns\": [");
                    for (int i = 1; i <= columnCount; i++) {
                        if (i > 1) System.out.print(", ");
                        System.out.print("\"" + escape(meta.getColumnLabel(i)) + "\"");
                    }
                    System.out.println("],");
                    System.out.print("\"column_types\": [");
                    for (int i = 1; i <= columnCount; i++) {
                        if (i > 1) System.out.print(", ");
                        System.out.print("\"" + escape(meta.getColumnTypeName(i)) + "\"");
                    }
                    System.out.println("],");
                    System.out.println("\"rows\": [");

                    int rowCount = 0;
                    while (rs.next()) {
                        if (rowCount > 0) System.out.println(",");
                        System.out.print("  {");
                        for (int i = 1; i <= columnCount; i++) {
                            if (i > 1) System.out.print(", ");
                            System.out.print("\"" + escape(meta.getColumnLabel(i)) + "\": ");
                            System.out.print(formatValue(rs, i, meta.getColumnType(i)));
                        }
                        System.out.print("}");
                        rowCount++;
                    }
                    System.out.println();
                    System.out.println("]}");
                }
            } else {
                int updateCount = stmt.getUpdateCount();
                System.out.println("{\"update_count\": " + updateCount + "}");
            }
        } catch (Exception e) {
            System.err.println("Connection failed: " + e.getMessage());
            System.exit(2);
        }
    }

    // --- Script mode -------------------------------------------------------
    // Runs a SQL*Plus-style script: many statements sharing one connection.
    // Statements are executed in order, stopping at the first failure, and a
    // per-statement log is emitted as JSON. Connection-level failures exit(2)
    // (like the single-statement path); per-statement SQL errors are reported
    // in the JSON with exit(0) so the log still renders.
    private static void runScript(String script, String url, String user,
                                  String password, boolean integratedAuth) {
        java.util.List<String> stmts = splitStatements(script);
        if (stmts.isEmpty()) {
            System.err.println("No statements found in script");
            System.exit(1);
        }

        StringBuilder out = new StringBuilder();
        out.append("{\"script\": true, \"results\": [");
        int executed = 0, failed = 0;

        try (Connection conn = integratedAuth
                 ? DriverManager.getConnection(url)
                 : DriverManager.getConnection(url, user, password)) {

            for (int idx = 0; idx < stmts.size(); idx++) {
                String s = stmts.get(idx);
                if (idx > 0) out.append(", ");
                out.append("{\"index\": ").append(idx + 1);
                out.append(", \"preview\": \"").append(escape(preview(s))).append("\"");
                try (Statement stmt = conn.createStatement()) {
                    boolean rs = stmt.execute(s);
                    int uc = rs ? -1 : stmt.getUpdateCount();
                    out.append(", \"ok\": true, \"update_count\": ").append(uc).append("}");
                    executed++;
                } catch (java.sql.SQLException e) {
                    out.append(", \"ok\": false, \"error\": \"")
                       .append(escape(e.getMessage())).append("\"}");
                    failed++;
                    break; // stop at first error
                }
            }
        } catch (Exception e) {
            System.err.println("Connection failed: " + e.getMessage());
            System.exit(2);
            return;
        }

        out.append("], \"executed\": ").append(executed);
        out.append(", \"failed\": ").append(failed);
        out.append(", \"total\": ").append(stmts.size()).append("}");
        System.out.println(out);
    }

    // First ~80 chars of a statement, collapsed to a single line, for the log.
    private static String preview(String s) {
        String one = s.replaceAll("\\s+", " ").trim();
        return one.length() > 80 ? one.substring(0, 80) + "…" : one;
    }

    // Splits a SQL*Plus-style script into individual statements.
    //   - a line containing only "/" terminates the current statement
    //     (the canonical PL/SQL block terminator)
    //   - ";" terminates a statement UNLESS it is inside a PL/SQL block
    //     (DECLARE / BEGIN / CREATE PROCEDURE|FUNCTION|PACKAGE|TRIGGER|TYPE),
    //     where ";" separates inner statements
    //   - string literals ('...' with '' escape), quoted identifiers ("..."),
    //     line comments (--) and block comments (/* */) are skipped so their
    //     contents never trigger a split
    static java.util.List<String> splitStatements(String sql) {
        java.util.List<String> out = new java.util.ArrayList<>();
        StringBuilder cur = new StringBuilder();
        int n = sql.length();
        boolean inSingle = false, inDouble = false, inLine = false, inBlock = false;
        boolean lineBlank = true; // only whitespace seen on the current line so far
        int i = 0;
        while (i < n) {
            char c = sql.charAt(i);
            char nx = i + 1 < n ? sql.charAt(i + 1) : '\0';

            if (inLine) {
                cur.append(c);
                if (c == '\n') { inLine = false; lineBlank = true; }
                i++; continue;
            }
            if (inBlock) {
                cur.append(c);
                if (c == '*' && nx == '/') { cur.append(nx); i += 2; inBlock = false; continue; }
                i++; continue;
            }
            if (inSingle) {
                cur.append(c);
                if (c == '\'') {
                    if (nx == '\'') { cur.append(nx); i += 2; continue; } // '' escape
                    inSingle = false;
                }
                i++; continue;
            }
            if (inDouble) {
                cur.append(c);
                if (c == '"') inDouble = false;
                i++; continue;
            }

            if (c == '-' && nx == '-') { inLine = true; cur.append(c); i++; lineBlank = false; continue; }
            if (c == '/' && nx == '*') { inBlock = true; cur.append(c); i++; lineBlank = false; continue; }
            if (c == '\'') { inSingle = true; cur.append(c); i++; lineBlank = false; continue; }
            if (c == '"') { inDouble = true; cur.append(c); i++; lineBlank = false; continue; }

            if (c == '\n') { cur.append(c); lineBlank = true; i++; continue; }
            if (c == '\r') { cur.append(c); i++; continue; }

            // lone "/" on its own line -> terminate current statement
            if (c == '/' && lineBlank) {
                int j = i + 1;
                boolean rest = true;
                while (j < n) {
                    char d = sql.charAt(j);
                    if (d == '\n') break;
                    if (!Character.isWhitespace(d)) { rest = false; break; }
                    j++;
                }
                if (rest) {
                    flush(out, cur);
                    i = (j < n && sql.charAt(j) == '\n') ? j + 1 : j;
                    lineBlank = true;
                    continue;
                }
            }

            if (c == ';' && !isPlsqlBlock(cur)) {
                flush(out, cur);
                i++; lineBlank = false; continue;
            }

            cur.append(c);
            if (!Character.isWhitespace(c)) lineBlank = false;
            i++;
        }
        flush(out, cur);
        return out;
    }

    private static void flush(java.util.List<String> out, StringBuilder cur) {
        String s = cur.toString().trim();
        if (!s.isEmpty()) out.add(s);
        cur.setLength(0);
    }

    // Is the statement accumulated so far a PL/SQL block (where ";" is internal)?
    private static boolean isPlsqlBlock(CharSequence csq) {
        String s = csq.toString();
        int i = 0, n = s.length();
        while (i < n) { // skip leading whitespace and comments
            char c = s.charAt(i);
            if (Character.isWhitespace(c)) { i++; continue; }
            if (c == '-' && i + 1 < n && s.charAt(i + 1) == '-') {
                while (i < n && s.charAt(i) != '\n') i++;
                continue;
            }
            if (c == '/' && i + 1 < n && s.charAt(i + 1) == '*') {
                i += 2;
                while (i + 1 < n && !(s.charAt(i) == '*' && s.charAt(i + 1) == '/')) i++;
                i += 2;
                continue;
            }
            break;
        }
        String head = s.substring(Math.min(i, n)).toUpperCase();
        if (startsWithWord(head, "DECLARE") || startsWithWord(head, "BEGIN")) return true;
        if (startsWithWord(head, "CREATE")) {
            String r = head.replaceFirst(
                "^CREATE\\s+(OR\\s+REPLACE\\s+)?(EDITIONABLE\\s+|NONEDITIONABLE\\s+)?", "");
            for (String kw : new String[]{"PROCEDURE", "FUNCTION", "PACKAGE", "TRIGGER", "TYPE"}) {
                if (startsWithWord(r, kw)) return true;
            }
        }
        return false;
    }

    private static boolean startsWithWord(String s, String w) {
        if (!s.startsWith(w)) return false;
        if (s.length() == w.length()) return true;
        char c = s.charAt(w.length());
        return !(Character.isLetterOrDigit(c) || c == '_');
    }

    // --- Bulk file dump ----------------------------------------------------
    // Streams the full result set straight to `path` (CSV or JSON) row by row,
    // so arbitrarily large exports never buffer in memory. Emits a small JSON
    // summary to stdout on completion so the caller can report the row count.
    private static void writeToFile(ResultSet rs, ResultSetMetaData meta, int columnCount,
                                    String path, String format) throws Exception {
        boolean json = "json".equalsIgnoreCase(format);
        long rowCount = 0;
        try (java.io.BufferedWriter w = java.nio.file.Files.newBufferedWriter(
                java.nio.file.Paths.get(path), java.nio.charset.StandardCharsets.UTF_8)) {
            if (json) {
                w.write("{\"columns\": [");
                for (int i = 1; i <= columnCount; i++) {
                    if (i > 1) w.write(", ");
                    w.write("\"" + escape(meta.getColumnLabel(i)) + "\"");
                }
                w.write("],\n\"column_types\": [");
                for (int i = 1; i <= columnCount; i++) {
                    if (i > 1) w.write(", ");
                    w.write("\"" + escape(meta.getColumnTypeName(i)) + "\"");
                }
                w.write("],\n\"rows\": [\n");
                while (rs.next()) {
                    if (rowCount > 0) w.write(",\n");
                    w.write("  {");
                    for (int i = 1; i <= columnCount; i++) {
                        if (i > 1) w.write(", ");
                        w.write("\"" + escape(meta.getColumnLabel(i)) + "\": ");
                        w.write(formatValue(rs, i, meta.getColumnType(i)));
                    }
                    w.write("}");
                    rowCount++;
                }
                w.write("\n]}\n");
            } else {
                for (int i = 1; i <= columnCount; i++) {
                    if (i > 1) w.write(",");
                    w.write(csvEscape(meta.getColumnLabel(i)));
                }
                w.write("\n");
                while (rs.next()) {
                    for (int i = 1; i <= columnCount; i++) {
                        if (i > 1) w.write(",");
                        w.write(csvEscape(csvValue(rs, i, meta.getColumnType(i))));
                    }
                    w.write("\n");
                    rowCount++;
                }
            }
        }
        System.out.println("{\"to_file\": true, \"format\": \"" + escape(format)
            + "\", \"path\": \"" + escape(path) + "\", \"rows\": " + rowCount + "}");
    }

    // Plain (un-quoted) string form of a cell, for CSV output.
    private static String csvValue(ResultSet rs, int col, int sqlType) throws java.sql.SQLException {
        if (sqlType == Types.BLOB) {
            java.sql.Blob blob = rs.getBlob(col);
            if (blob == null || rs.wasNull()) return "";
            return "<BLOB " + blob.length() + " bytes>";
        }
        if (sqlType == Types.CLOB || sqlType == Types.NCLOB) {
            java.sql.Clob clob = rs.getClob(col);
            if (clob == null || rs.wasNull()) return "";
            return clob.getSubString(1, (int) Math.min(clob.length(), 1_000_000));
        }
        String raw = rs.getString(col);
        if (raw == null || rs.wasNull()) return "";
        return raw;
    }

    // Mirrors the Lua CSV escaper: newlines become the literal "\n", and a field
    // containing a comma or quote is wrapped in quotes with quotes doubled.
    private static String csvEscape(String val) {
        if (val == null) val = "";
        String s = val.replace("\r\n", "\\n").replace("\n", "\\n").replace("\r", "\\n");
        if (s.indexOf(',') >= 0 || s.indexOf('"') >= 0) {
            s = "\"" + s.replace("\"", "\"\"") + "\"";
        }
        return s;
    }

    private static String formatValue(ResultSet rs, int col, int sqlType) throws java.sql.SQLException {
        if (sqlType == Types.BLOB) {
            java.sql.Blob blob = rs.getBlob(col);
            if (blob == null || rs.wasNull()) return "null";
            return "\"<BLOB " + blob.length() + " bytes>\"";
        }
        if (sqlType == Types.CLOB || sqlType == Types.NCLOB) {
            java.sql.Clob clob = rs.getClob(col);
            if (clob == null || rs.wasNull()) return "null";
            String val = clob.getSubString(1, (int) Math.min(clob.length(), 1_000_000));
            return "\"" + escape(val) + "\"";
        }
        String raw = rs.getString(col);
        if (raw == null || rs.wasNull()) return "null";

        switch (sqlType) {
            case Types.BIT:
            case Types.BOOLEAN:
                return rs.getBoolean(col) ? "true" : "false";
            case Types.TINYINT:
            case Types.SMALLINT:
            case Types.INTEGER:
            case Types.BIGINT:
            case Types.FLOAT:
            case Types.REAL:
            case Types.DOUBLE:
            case Types.NUMERIC:
            case Types.DECIMAL:
                return raw;
            default:
                return "\"" + escape(raw) + "\"";
        }
    }

    private static String escape(String s) {
        StringBuilder sb = new StringBuilder(s.length() + 8);
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"':  sb.append("\\\""); break;
                case '\\': sb.append("\\\\"); break;
                case '\n': sb.append("\\n");  break;
                case '\r': sb.append("\\r");  break;
                case '\t': sb.append("\\t");  break;
                default:
                    if (c < 0x20) sb.append(String.format("\\u%04x", (int) c));
                    else sb.append(c);
            }
        }
        return sb.toString();
    }
}
