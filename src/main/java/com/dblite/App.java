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

        if (url == null || user == null || password == null) {
            System.err.println("Missing required env vars: DB_URL, DB_USER, DB_PASSWORD");
            System.err.println("Example DB_URL: jdbc:oracle:thin:@//localhost:1521/XEPDB1");
            System.exit(1);
        }

        int maxRows = 0;
        for (int i = 0; i < args.length; i++) {
            if ("--max-rows".equals(args[i]) && i + 1 < args.length) {
                try {
                    maxRows = Integer.parseInt(args[++i]);
                } catch (NumberFormatException e) {
                    System.err.println("Invalid --max-rows value: " + args[i]);
                    System.exit(1);
                }
            }
        }

        String query;
        try {
            query = new String(System.in.readAllBytes(), java.nio.charset.StandardCharsets.UTF_8).trim();
            query = query.replaceAll("[;/]\\s*$", "").trim();
        } catch (java.io.IOException e) {
            System.err.println("Failed to read query from stdin: " + e.getMessage());
            System.exit(1);
            return;
        }
        if (query.isEmpty()) {
            System.err.println("No query provided on stdin");
            System.exit(1);
        }

        try (Connection conn = DriverManager.getConnection(url, user, password);
             Statement stmt = conn.createStatement()) {

            if (maxRows > 0) stmt.setMaxRows(maxRows);

            try (ResultSet rs = stmt.executeQuery(query)) {
                ResultSetMetaData meta = rs.getMetaData();
                int columnCount = meta.getColumnCount();

                System.out.print("{\"columns\": [");
                for (int i = 1; i <= columnCount; i++) {
                    if (i > 1) System.out.print(", ");
                    System.out.print("\"" + escape(meta.getColumnLabel(i)) + "\"");
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
        } catch (Exception e) {
            System.err.println("Connection failed: " + e.getMessage());
            System.exit(2);
        }
    }

    private static String formatValue(ResultSet rs, int col, int sqlType) throws java.sql.SQLException {
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
