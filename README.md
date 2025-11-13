# Flight Booking System

## 1. Start everything
```bash
docker compose down -v
docker compose up -d --build
docker compose ps
```
Wait until `primary-db`, `reports-db`, `hot-backup`, `wal-archiver`, and `flight-app` are all `Up`. 

The UI lives at http://localhost:3000.

## 2. Core checks
- **Publication present**
  ```bash
  docker compose exec primary-db \
    psql -U postgres -d flightdb \
    -c "SELECT pubname FROM pg_publication;"
  ```
- **Subscription streaming**
  ```bash
  docker compose exec reports-db \
    psql -U postgres -d flightdb \
    -c "SELECT subname, status FROM pg_stat_subscription;"
  ```
- **Hot backup in recovery**
  ```bash
  docker compose exec hot-backup \
    psql -U postgres -c "SELECT pg_is_in_recovery();"
  ```
- **WAL archiving**
  ```bash
  docker compose exec primary-db \
    psql -U postgres -d flightdb -c "SELECT pg_switch_wal();"
  docker compose exec primary-db ls -lh /var/lib/postgresql/wal_archive | head
  docker compose exec wal-archiver ls -lh /wal_archive/compressed | head
  ```

## 3. Booking + analytics
1. Use the UI (or POST `/api/bookings`) to create a booking.
2. Trigger a refresh if needed:
   ```bash
   curl -X POST http://localhost:3000/api/reports/refresh
   ```
3. Fetch the reports:
   ```bash
  curl http://localhost:3000/api/reports/daily-revenue
  curl http://localhost:3000/api/reports/flight-occupancy
  curl http://localhost:3000/api/reports/route-performance
  ```

## 4. Load test
```bash
./scripts/run-load-test.sh
```
Outputs land in `jmeter/results/` (`results.jtl` + `report/index.html`).


