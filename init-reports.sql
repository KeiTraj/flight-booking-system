-- Initialize Reports Database Schema
-- Optimized for OLAP (Analytical Operations)

-- First, create base tables to receive replicated data
CREATE TABLE airlines (
    airline_id INTEGER PRIMARY KEY,
    code VARCHAR(3) NOT NULL,
    name VARCHAR(100) NOT NULL,
    created_at TIMESTAMP
);

CREATE TABLE aircraft (
    aircraft_id INTEGER PRIMARY KEY,
    registration VARCHAR(10) NOT NULL,
    model VARCHAR(50) NOT NULL,
    total_seats INTEGER NOT NULL,
    created_at TIMESTAMP
);

CREATE TABLE flights (
    flight_id INTEGER PRIMARY KEY,
    airline_id INTEGER,
    flight_number VARCHAR(10) NOT NULL,
    aircraft_id INTEGER,
    origin VARCHAR(3) NOT NULL,
    destination VARCHAR(3) NOT NULL,
    departure_time TIMESTAMP NOT NULL,
    arrival_time TIMESTAMP NOT NULL,
    base_price DECIMAL(10,2) NOT NULL,
    status VARCHAR(20),
    created_at TIMESTAMP
);

CREATE TABLE seats (
    seat_id INTEGER PRIMARY KEY,
    flight_id INTEGER,
    seat_number VARCHAR(5) NOT NULL,
    class VARCHAR(20) NOT NULL,
    is_available BOOLEAN,
    version INTEGER
);

CREATE TABLE customers (
    customer_id INTEGER PRIMARY KEY,
    email VARCHAR(255) NOT NULL,
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100) NOT NULL,
    phone VARCHAR(20),
    created_at TIMESTAMP
);

CREATE TABLE bookings (
    booking_id INTEGER PRIMARY KEY,
    customer_id INTEGER,
    booking_reference VARCHAR(10) NOT NULL,
    total_amount DECIMAL(10,2) NOT NULL,
    status VARCHAR(20),
    created_at TIMESTAMP,
    updated_at TIMESTAMP
);

CREATE TABLE booking_details (
    booking_detail_id INTEGER PRIMARY KEY,
    booking_id INTEGER,
    seat_id INTEGER,
    passenger_name VARCHAR(200) NOT NULL,
    price DECIMAL(10,2) NOT NULL,
    created_at TIMESTAMP
);

-- Create indexes for analytical queries
CREATE INDEX idx_flights_departure ON flights(departure_time);
CREATE INDEX idx_flights_route ON flights(origin, destination);
CREATE INDEX idx_flights_airline ON flights(airline_id);
CREATE INDEX idx_bookings_created ON bookings(created_at);
CREATE INDEX idx_bookings_status ON bookings(status);
CREATE INDEX idx_seats_flight ON seats(flight_id);
CREATE INDEX idx_booking_details_booking ON booking_details(booking_id);

-- Create subscription AFTER tables are created
CREATE SUBSCRIPTION reports_sub
    CONNECTION 'host=primary-db port=5432 dbname=flightdb user=replicator password=replicator_password'
    PUBLICATION reports_pub
    WITH (copy_data = true);

-- Now create denormalized materialized views for analytics
CREATE MATERIALIZED VIEW booking_analytics AS
SELECT
    b.booking_id,
    b.booking_reference,
    c.email as customer_email,
    c.first_name || ' ' || c.last_name as customer_name,
    f.flight_number,
    a.name as airline_name,
    f.origin,
    f.destination,
    f.departure_time,
    s.class,
    b.total_amount,
    COUNT(bd.booking_detail_id) as num_passengers,
    b.status as booking_status,
    b.created_at,
    b.updated_at
FROM bookings b
JOIN customers c ON b.customer_id = c.customer_id
JOIN booking_details bd ON b.booking_id = bd.booking_id
JOIN seats s ON bd.seat_id = s.seat_id
JOIN flights f ON s.flight_id = f.flight_id
JOIN airlines a ON f.airline_id = a.airline_id
GROUP BY b.booking_id, b.booking_reference, c.email, 
         c.first_name, c.last_name, f.flight_number, a.name,
         f.origin, f.destination, f.departure_time, s.class,
         b.total_amount, b.status, b.created_at, b.updated_at;

CREATE INDEX idx_ba_created ON booking_analytics(created_at);
CREATE INDEX idx_ba_airline ON booking_analytics(airline_name);
CREATE INDEX idx_ba_route ON booking_analytics(origin, destination);
CREATE INDEX idx_ba_class ON booking_analytics(class);
CREATE INDEX idx_ba_status ON booking_analytics(booking_status);

-- Flight occupancy view
CREATE MATERIALIZED VIEW flight_occupancy AS
SELECT
    f.flight_id,
    f.flight_number,
    a.name as airline_name,
    f.origin,
    f.destination,
    f.departure_time,
    ac.total_seats,
    COUNT(CASE WHEN s.is_available = FALSE THEN 1 END) as booked_seats,
    COUNT(CASE WHEN s.is_available = TRUE THEN 1 END) as available_seats,
    ROUND((COUNT(CASE WHEN s.is_available = FALSE THEN 1 END)::DECIMAL / 
           NULLIF(ac.total_seats, 0) * 100), 2) as occupancy_rate,
    COALESCE(SUM(CASE WHEN s.is_available = FALSE THEN bd.price END), 0) as revenue,
    f.status
FROM flights f
JOIN airlines a ON f.airline_id = a.airline_id
JOIN aircraft ac ON f.aircraft_id = ac.aircraft_id
LEFT JOIN seats s ON f.flight_id = s.flight_id
LEFT JOIN booking_details bd ON s.seat_id = bd.seat_id
GROUP BY f.flight_id, f.flight_number, a.name, f.origin, f.destination,
         f.departure_time, ac.total_seats, f.status;

CREATE INDEX idx_fo_departure ON flight_occupancy(departure_time);
CREATE INDEX idx_fo_route ON flight_occupancy(origin, destination);
CREATE INDEX idx_fo_airline ON flight_occupancy(airline_name);

-- Daily revenue summary
CREATE MATERIALIZED VIEW daily_revenue AS
SELECT
    DATE(b.created_at) as report_date,
    COUNT(*) as total_bookings,
    SUM(b.total_amount) as total_revenue,
    AVG(b.total_amount) as avg_booking_value,
    COUNT(bd.booking_detail_id) as total_passengers
FROM bookings b
JOIN booking_details bd ON b.booking_id = bd.booking_id
WHERE b.status = 'confirmed'
GROUP BY DATE(b.created_at);

CREATE INDEX idx_dr_date ON daily_revenue(report_date);

-- Route performance summary (FIXED - no nested aggregates)
CREATE MATERIALIZED VIEW route_performance AS
SELECT
    origin,
    destination,
    COUNT(*) as total_flights,
    SUM(booked_seats) as total_bookings,
    SUM(revenue) as total_revenue,
    AVG(occupancy_rate) as avg_occupancy_rate
FROM flight_occupancy
GROUP BY origin, destination;

CREATE INDEX idx_rp_route ON route_performance(origin, destination);

-- Function to refresh all materialized views
CREATE OR REPLACE FUNCTION refresh_all_analytics()
RETURNS void AS $$
BEGIN
    REFRESH MATERIALIZED VIEW  booking_analytics;
    REFRESH MATERIALIZED VIEW  flight_occupancy;
    REFRESH MATERIALIZED VIEW  daily_revenue;
    REFRESH MATERIALIZED VIEW  route_performance;
END;
$$ LANGUAGE plpgsql;

