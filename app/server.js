const express = require('express');
const { Pool } = require('pg');
const cors = require('cors');
const bodyParser = require('body-parser');
const path = require('path');

const app = express();
const PORT = 3000;

// Middleware
app.use(cors());
app.use(bodyParser.json());
app.use(express.static('public'));

// Database connection pools
const primaryPool = new Pool({
  host: process.env.PRIMARY_DB_HOST || 'primary-db',
  port: process.env.PRIMARY_DB_PORT || 5432,
  database: process.env.PRIMARY_DB_NAME || 'flightdb',
  user: process.env.PRIMARY_DB_USER || 'postgres',
  password: process.env.PRIMARY_DB_PASSWORD || 'postgres',
  max: 20,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 10000,
});

const reportsPool = new Pool({
  host: process.env.REPORTS_DB_HOST || 'reports-db',
  port: process.env.REPORTS_DB_PORT || 5432,
  database: process.env.REPORTS_DB_NAME || 'reports',
  user: process.env.REPORTS_DB_USER || 'postgres',
  password: process.env.REPORTS_DB_PASSWORD || 'postgres',
  max: 10,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 10000,
});

const refreshAnalytics = async () => {
  try {
    await reportsPool.query('SELECT refresh_all_analytics()');
  } catch (err) {
    console.error('Error refreshing analytics:', err);
    throw err;
  }
};

const parseDelay = (value, fallback) => {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
};

const refreshDelayMs = parseDelay(process.env.ANALYTICS_REFRESH_DELAY_MS, 2000);
const replicationLagTargetMs = parseDelay(process.env.ANALYTICS_REPLICATION_LAG_TARGET_MS, 1500);
const replicationMaxWaitMs = parseDelay(process.env.ANALYTICS_REPLICATION_MAX_WAIT_MS, 60000);
const replicationPollIntervalMs = Math.max(
  50,
  parseDelay(process.env.ANALYTICS_REPLICATION_POLL_INTERVAL_MS, 250)
);
const subscriptionName = process.env.REPORTS_SUBSCRIPTION_NAME || 'reports_sub';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const getReplicationLagMs = async () => {
  try {
    const { rows } = await reportsPool.query(
      `
        SELECT
          last_msg_receipt_time,
          latest_end_time,
          EXTRACT(EPOCH FROM write_lag) * 1000 AS write_lag_ms,
          EXTRACT(EPOCH FROM flush_lag) * 1000 AS flush_lag_ms,
          EXTRACT(EPOCH FROM apply_lag) * 1000 AS apply_lag_ms
        FROM pg_catalog.pg_stat_subscription
        WHERE subname = $1
      `,
      [subscriptionName]
    );

    if (!rows.length) {
      return null;
    }

    const {
      last_msg_receipt_time: receiptTime,
      latest_end_time: applyTime,
      write_lag_ms: writeLagMs,
      flush_lag_ms: flushLagMs,
      apply_lag_ms: applyLagMs,
    } = rows[0];

    const intervalLags = [writeLagMs, flushLagMs, applyLagMs]
      .map((lag) => {
        const parsed = Number(lag);
        return Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
      })
      .filter((lag) => lag !== null);

    if (intervalLags.length) {
      return Math.max(...intervalLags);
    }

    const now = Date.now();
    const parseTimestamp = (value) => {
      if (!value) {
        return null;
      }

      const timestamp = new Date(value).getTime();
      return Number.isFinite(timestamp) ? timestamp : null;
    };

    const timestamps = [receiptTime, applyTime].map(parseTimestamp).filter((timestamp) => timestamp !== null);

    if (!timestamps.length) {
      return 0;
    }

    return Math.max(...timestamps.map((timestamp) => Math.max(0, now - timestamp)));
  } catch (err) {
    console.error('Failed to inspect replication status:', err);
    return 0;
  }
};

const waitForReplicationCatchUp = async () => {
  if (replicationMaxWaitMs === 0) {
    return 'skipped';
  }

  const start = Date.now();
  let hasLoggedDelay = false;
  let sawLagSample = false;

  while (Date.now() - start < replicationMaxWaitMs) {
    const lagMs = await getReplicationLagMs();

    if (lagMs !== null) {
      sawLagSample = true;

      if (lagMs <= replicationLagTargetMs) {
        if (hasLoggedDelay) {
          console.info('Replication caught up; refreshing analytics.');
        }
        return 'caught-up';
      }

      if (!hasLoggedDelay) {
        console.info(
          `Waiting for replication to catch up (current lag ≈ ${Math.round(lagMs)} ms)`
        );
        hasLoggedDelay = true;
      }
    } else if (!hasLoggedDelay) {
      console.info('Waiting for replication statistics to become available...');
      hasLoggedDelay = true;
    }

    await sleep(replicationPollIntervalMs);
  }

  console.warn(
    `Timed out after ${replicationMaxWaitMs} ms while waiting for replication to catch up; proceeding with refresh`
  );
  return sawLagSample ? 'timed-out' : 'no-stats';
};

let refreshTimer = null;
let refreshPending = false;
let refreshInFlight = false;
let refreshRequestedWhileRunning = false;

const runScheduledRefresh = async () => {
  refreshTimer = null;

  if (!refreshPending) {
    return;
  }

  refreshPending = false;
  refreshInFlight = true;
  let shouldRetry = false;

  try {
    const replicationStatus = await waitForReplicationCatchUp();
    await refreshAnalytics();
    if (replicationStatus === 'timed-out' || replicationStatus === 'no-stats') {
      shouldRetry = true;
    }
  } catch (err) {
    console.error('Scheduled analytics refresh failed:', err);
  } finally {
    refreshInFlight = false;

    const pendingWhileRunning = refreshRequestedWhileRunning;
    refreshRequestedWhileRunning = false;

    if (pendingWhileRunning || shouldRetry) {
      scheduleAnalyticsRefresh();
    }
  }
};

const scheduleAnalyticsRefresh = () => {
  if (refreshInFlight) {
    refreshRequestedWhileRunning = true;
    return;
  }

  refreshPending = true;

  if (refreshTimer) {
    clearTimeout(refreshTimer);
  }

  refreshTimer = setTimeout(runScheduledRefresh, refreshDelayMs);
};


// Health check
app.get('/health', (req, res) => {
  res.json({ status: 'healthy', timestamp: new Date().toISOString() });
});

// ==================== TRANSACTIONAL OPERATIONS ====================

// Get available flights
app.get('/api/flights', async (req, res) => {
  const { origin, destination, date } = req.query;
  
  try {
    let query = `
      SELECT f.flight_id, f.flight_number, a.name as airline_name,
             f.origin, f.destination, f.departure_time, f.arrival_time,
             f.base_price, f.status,
             COUNT(s.seat_id) FILTER (WHERE s.is_available = TRUE) as available_seats
      FROM flights f
      JOIN airlines a ON f.airline_id = a.airline_id
      LEFT JOIN seats s ON f.flight_id = s.flight_id
      WHERE f.status = 'scheduled'
    `;
    
    const params = [];
    let paramCount = 1;
    
    if (origin) {
      query += ` AND f.origin = $${paramCount++}`;
      params.push(origin);
    }
    if (destination) {
      query += ` AND f.destination = $${paramCount++}`;
      params.push(destination);
    }
    if (date) {
      query += ` AND DATE(f.departure_time) = $${paramCount++}`;
      params.push(date);
    }
    
    query += ` GROUP BY f.flight_id, f.flight_number, a.name, f.origin, 
               f.destination, f.departure_time, f.arrival_time, f.base_price, f.status
               ORDER BY f.departure_time`;
    
    const result = await primaryPool.query(query, params);
    res.json(result.rows);
  } catch (err) {
    console.error('Error fetching flights:', err);
    res.status(500).json({ error: 'Failed to fetch flights' });
  }
});

// Get available seats for a flight
app.get('/api/flights/:flightId/seats', async (req, res) => {
  const { flightId } = req.params;
  
  try {
    const result = await primaryPool.query(`
      SELECT seat_id, seat_number, class, is_available
      FROM seats
      WHERE flight_id = $1
      ORDER BY seat_number
    `, [flightId]);
    
    res.json(result.rows);
  } catch (err) {
    console.error('Error fetching seats:', err);
    res.status(500).json({ error: 'Failed to fetch seats' });
  }
});

// Create booking with race condition handling
app.post('/api/bookings', async (req, res) => {
  const { customerId, seatIds, passengerNames, prices } = req.body;
  
  const client = await primaryPool.connect();
  
  try {
    await client.query('BEGIN');
    
    // Generate booking reference
    const bookingRef = 'BK' + Math.random().toString(36).substr(2, 8).toUpperCase();
    const totalAmount = prices.reduce((sum, price) => sum + parseFloat(price), 0);
    
    // Create booking
    const bookingResult = await client.query(`
      INSERT INTO bookings (customer_id, booking_reference, total_amount, status)
      VALUES ($1, $2, $3, 'pending')
      RETURNING booking_id
    `, [customerId, bookingRef, totalAmount]);
    
    const bookingId = bookingResult.rows[0].booking_id;
    
    // Use deadlock-prevention function to book seats
    try {
      await client.query(`
        SELECT book_seats($1, $2, $3, $4)
      `, [bookingId, seatIds, passengerNames, prices]);
      
      // Update booking status to confirmed
      await client.query(`
        UPDATE bookings SET status = 'confirmed' WHERE booking_id = $1
      `, [bookingId]);

      await client.query('COMMIT');
      
      scheduleAnalyticsRefresh();

      res.json({
        success: true,
        bookingId,
        bookingReference: bookingRef,
        message: 'Booking confirmed successfully'
      });
    } catch (bookingErr) {
      throw bookingErr;
    }
    
  } catch (err) {
    await client.query('ROLLBACK');
    console.error('Booking error:', err);
    
    if (err.message.includes('not available') || err.message.includes('lock')) {
      res.status(409).json({ 
        error: 'Seats no longer available. Please select different seats.' 
      });
    } else {
      res.status(500).json({ error: 'Booking failed. Please try again.' });
    }
  } finally {
    client.release();
  }
});

// Batch update flight status (e.g., cancel multiple flights)
app.post('/api/flights/batch-update', async (req, res) => {
  const { flightIds, status } = req.body;
  
  try {
    const result = await primaryPool.query(`
      SELECT batch_update_flight_status($1, $2)
    `, [flightIds, status]);
    
    res.json({
      success: true,
      rowsUpdated: result.rows[0].batch_update_flight_status,
      message: `${result.rows[0].batch_update_flight_status} flights updated`
    });
  } catch (err) {
    console.error('Batch update error:', err);
    res.status(500).json({ error: 'Batch update failed' });
  }
});

// Cancel booking
app.post('/api/bookings/:bookingId/cancel', async (req, res) => {
  const { bookingId } = req.params;
  const client = await primaryPool.connect();
  
  try {
    await client.query('BEGIN');
    
    // Get seat IDs from booking
    const seatsResult = await client.query(`
      SELECT seat_id FROM booking_details WHERE booking_id = $1
    `, [bookingId]);
    
    // Release seats
    for (const row of seatsResult.rows) {
      await client.query(`
        UPDATE seats SET is_available = TRUE WHERE seat_id = $1
      `, [row.seat_id]);
    }
    
    // Update booking status
    await client.query(`
      UPDATE bookings SET status = 'cancelled' WHERE booking_id = $1
    `, [bookingId]);
    
    await client.query('COMMIT');
    
    scheduleAnalyticsRefresh();

    res.json({ success: true, message: 'Booking cancelled successfully' });
  } catch (err) {
    await client.query('ROLLBACK');
    console.error('Cancellation error:', err);
    res.status(500).json({ error: 'Cancellation failed' });
  } finally {
    client.release();
  }
});

// ==================== ANALYTICAL OPERATIONS ====================

// Report 1: Daily Revenue Report (from Data Warehouse)
app.get('/api/reports/daily-revenue', async (req, res) => {
  const { startDate, endDate } = req.query;
  
  try {
    let query = `
      SELECT report_date, total_bookings, total_revenue,
             avg_booking_value, total_passengers
      FROM daily_revenue
    `;
    
    const params = [];
    if (startDate && endDate) {
      query += ` WHERE report_date BETWEEN $1 AND $2`;
      params.push(startDate, endDate);
    }
    
    query += ` ORDER BY report_date DESC LIMIT 30`;
    
    const result = await reportsPool.query(query, params);
    res.json(result.rows);
  } catch (err) {
    console.error('Daily revenue report error:', err);
    res.status(500).json({ error: 'Failed to generate report' });
  }
});

// Report 2: Flight Occupancy Report (from Data Warehouse)
app.get('/api/reports/flight-occupancy', async (req, res) => {
  try {
    const result = await reportsPool.query(`
      SELECT flight_number, airline_name, origin, destination,
             departure_time, total_seats, booked_seats, available_seats,
             occupancy_rate, revenue, status
      FROM flight_occupancy
      WHERE departure_time >= CURRENT_DATE
      ORDER BY occupancy_rate DESC
      LIMIT 100
    `);
    
    res.json(result.rows);
  } catch (err) {
    console.error('Flight occupancy report error:', err);
    res.status(500).json({ error: 'Failed to generate report' });
  }
});

// Report 3: Route Performance Report (from Data Warehouse)
app.get('/api/reports/route-performance', async (req, res) => {
  try {
    const result = await reportsPool.query(`
      SELECT origin, destination, total_flights, total_bookings,
             total_revenue, avg_occupancy_rate
      FROM route_performance
      ORDER BY total_revenue DESC
      LIMIT 50
    `);
    
    res.json(result.rows);
  } catch (err) {
    console.error('Route performance report error:', err);
    res.status(500).json({ error: 'Failed to generate report' });
  }
});

// Real-time analytics (from Primary DB when real-time data needed)
app.get('/api/analytics/realtime-bookings', async (req, res) => {
  try {
    const result = await primaryPool.query(`
      SELECT DATE(created_at) as booking_date,
             COUNT(*) as total_bookings,
             SUM(total_amount) as total_revenue,
             AVG(total_amount) as avg_booking_value
      FROM bookings
      WHERE created_at >= CURRENT_DATE - INTERVAL '7 days'
      GROUP BY DATE(created_at)
      ORDER BY booking_date DESC
    `);
    
    res.json(result.rows);
  } catch (err) {
    console.error('Real-time analytics error:', err);
    res.status(500).json({ error: 'Failed to fetch analytics' });
  }
});

// Refresh reports (manual trigger)
app.post('/api/reports/refresh', async (req, res) => {
  try {
    await waitForReplicationCatchUp();
    await refreshAnalytics();
    res.json({ success: true, message: 'Reports refreshed successfully' });
  } catch (err) {
    console.error('Report refresh error:', err);
    res.status(500).json({ error: 'Failed to refresh reports' });
  }
});

// Serve frontend
app.get('*', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

// Start server
app.listen(PORT, () => {
  console.log(`Flight Booking System running on port ${PORT}`);
  console.log(`Primary DB: ${process.env.PRIMARY_DB_HOST}:${process.env.PRIMARY_DB_PORT}`);
  console.log(`Reports DB: ${process.env.REPORTS_DB_HOST}:${process.env.REPORTS_DB_PORT}`);
});

// Graceful shutdown
process.on('SIGTERM', async () => {
  console.log('Shutting down gracefully...');
  await primaryPool.end();
  await reportsPool.end();
  process.exit(0);
});
