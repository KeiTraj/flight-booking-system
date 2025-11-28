# Flight Booking System

## 1. Start everything
```bash
docker compose down -v
docker compose up -d
docker compose ps
```
Wait until `primary-db`, `reports-db`, `hot-backup`, `wal-archiver`, and `flight-app` are all `Up`.

The UI lives at http://localhost:3000.

## 2. Core checks
Perform these immediately after all containers report `Up`. Bookings should only start **after** every check returns the expected output.

- **Publication present** — expect `reports_pub`.
  ```bash
  docker compose exec primary-db \
    psql -U postgres -d flightdb \
    -c "SELECT pubname FROM pg_publication;"
  ```
  Example output:
  ```
   pubname
  ----------
   reports_pub
  (1 row)
  ```

- **Subscription streaming** — expect `reports_sub | streaming`.
  ```bash
  docker compose exec reports-db \
    psql -U postgres -d flightdb \
    -c "SELECT subname, status FROM pg_stat_subscription;"
  ```

- **Hot backup in recovery** — expect `t`.
  ```bash
  docker compose exec hot-backup \
    psql -U postgres -c "SELECT pg_is_in_recovery();"
  ```

- **WAL archiving** — expect `.wal.gz` files accumulating in both directories.
  ```bash
  docker compose exec primary-db \
    psql -U postgres -d flightdb -c "SELECT pg_switch_wal();"
  docker compose exec primary-db ls -lh /var/lib/postgresql/wal_archive | head
  docker compose exec wal-archiver ls -lh /wal_archive/compressed | head
  ```


### Step-by-step booking flow
1. **Pick a flight** (UI dropdown or API):
   ```bash
   curl "http://localhost:3000/api/flights?origin=SFO&destination=JFK&date=2024-08-01"
   ```
   Expected output: array of flights with `flight_id`, `available_seats`, etc.

2. **Inspect seats**:
   ```bash
   curl http://localhost:3000/api/flights/42/seats
   ```
   Expect a list where `is_available: true` means you can book the seat.

3. **Create the booking** (UI form or API):
   ```bash
   curl -X POST http://localhost:3000/api/bookings \
     -H "Content-Type: application/json" \
     -d '{
       "customerId": 1,
       "seatIds": [101,102],
       "passengerNames": ["Ada Lovelace","Alan Turing"],
       "prices": [350, 350]
     }'
   ```
   Expected success payload:
   ```json
   {
     "success": true,
     "bookingId": 123,
     "bookingReference": "BK8XYZ123",
     "message": "Booking confirmed successfully"
   }
   ```
   If seats are gone you’ll see HTTP `409` with `Seats no longer available...`.
   
4. **Automatic analytics refresh** kicks in ~2 seconds later. To force it:
   ```bash
   curl -X POST http://localhost:3000/api/reports/refresh
   ```
   Expected output: `{"success":true,"message":"Reports refreshed successfully"}`. If replication is still catching up, the command may take a few seconds before returning the same payload.

### Expected results when checking analytics
After a booking (or refresh), run:
```bash
curl http://localhost:3000/api/reports/daily-revenue
curl http://localhost:3000/api/reports/flight-occupancy
curl http://localhost:3000/api/reports/route-performance
```
- `daily-revenue` should show the booking date with increased `total_bookings`, `total_revenue`, and `total_passengers`.
- `flight-occupancy` should reflect fewer `available_seats` and a higher `occupancy_rate` for the flight you booked.
- `route-performance` aggregates per origin/destination; expect `total_bookings` and `total_revenue` to bump by your booking amount for that route.

## 4. Load test
```bash
./scripts/run-load-test.sh
```
Outputs land in `jmeter/results/` (`results.jtl` + `report/index.html`).

## 5. Hot backup walkthrough
Follow these steps to demonstrate the hot standby and failover drill:

1. **Verify recovery mode on the standby**
   ```bash
   docker compose exec hot-backup \
     psql -U postgres -c "SELECT pg_is_in_recovery();"
   ```
   Expect `t` (true), showing the standby is replaying WAL.

2. **Check replication catch-up from the primary**
   ```bash
   docker compose exec primary-db \
     psql -U postgres -d flightdb \
     -c "SELECT client_addr, state, sent_lsn, write_lsn, flush_lsn, replay_lsn FROM pg_stat_replication;"
   ```
   Confirm the standby connection is `streaming` and `replay_lsn` is advancing.

3. **Prove read-only enforcement on the standby**
   ```bash
   docker compose exec hot-backup \
     psql -U postgres -d flightdb \
     -c "INSERT INTO flights(airline_id, flight_number, aircraft_id, origin, destination, departure_time, arrival_time, base_price) VALUES((SELECT airline_id FROM airlines WHERE code = 'AA' LIMIT 1), 'HB-TEST', (SELECT aircraft_id FROM aircraft WHERE registration = 'N12345' LIMIT 1), 'AAA', 'BBB', NOW(), NOW() + interval '1 hour', 100);"
   ```
   You should see `cannot execute INSERT in a read-only transaction`. Valid read-only queries (e.g., `SELECT count(*) FROM bookings;`) should still succeed.


