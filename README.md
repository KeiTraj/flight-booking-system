## Quick start

1. **Clean restart everything**
   ```bash
   docker compose down -v
   docker compose up -d --build
   ```
   Wait until `docker compose ps` shows `primary-db`, `reports-db`, and `web-app` as `healthy`.

2. **Open the UI**  
   Visit [http://localhost:3000](http://localhost:3000) to search flights and create bookings. Each confirmed booking schedules an analytics refresh automatically; the Reports tab shows both automatic and manual refresh controls.

3. **(Optional) Watch logs**  
   `docker compose logs -f web-app` is handy while testing replication lag or refresh timing.

---

## Validate logical replication

Run from the project root:
```bash
docker compose exec primary-db \
  psql -U postgres -d flightdb \
  -c "SELECT pubname FROM pg_publication;"
```
Expected:
```
  pubname   
------------
 reports_pub
(1 row)
```

If the publication is missing (e.g., first boot), recreate it:
```bash
docker compose exec primary-db \
  psql -U postgres -d flightdb \
  -c "DROP PUBLICATION IF EXISTS reports_pub;\
      CREATE PUBLICATION reports_pub FOR TABLE \
        airlines, flights, bookings, booking_details, customers, seats, aircraft;"
```
> Tip: If you drop into the interactive `psql` prompt, type `\q` then rerun the command.

---

## Refresh & verification workflow

1. **Create at least one booking** via the UI (or POST `/api/bookings`) so there is data to aggregate.
2. **Auto refresh** – after a booking, the server waits for replication to catch up, runs `refresh_all_analytics()`, and the UI re-fetches the dashboards.
3. **Manual refresh** – either click any “Refresh” button on the Reports tab or call:
   ```bash
   curl -X POST http://localhost:3000/api/reports/refresh
   ```
4. **Inspect analytics endpoints**
   ```bash
   curl http://localhost:3000/api/reports/daily-revenue
   curl http://localhost:3000/api/reports/flight-occupancy
   curl http://localhost:3000/api/reports/route-performance
   curl http://localhost:3000/api/analytics/realtime-bookings   # primary DB comparison
   ```
5. **Force a refresh inside reports-db (optional)**
   ```bash
   docker compose exec reports-db \
     psql -U postgres -d flightdb \
     -c "SELECT refresh_all_analytics();"
   ```

---
