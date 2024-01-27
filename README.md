This script collects information about Oracle databases on a linux server:

1. It extracts database details from `/etc/oratab`.
2. For each valid database entry, it fetches database size, archive log mode, software version, alert log path, database role, device backup type, and recent backup details.
3. The script generates a CSV file with database details and another CSV file with backup details.
4. It also creates a JSON file with feature usage statistics for each database.
5. The JSON file is structured as an array of objects.

