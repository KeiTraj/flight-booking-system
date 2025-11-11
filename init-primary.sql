-- Initialize Primary Database Schema
-- Optimized for OLTP (Transactional Operations)

-- Create replication user for hot backup
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replicator_password';

-- Enable logical replication
ALTER SYSTEM SET wal_level = 'logical';
ALTER SYSTEM SET max_replication_slots = 10;

-- Normalized Schema for Transactional Efficiency

-- Airlines table
CREATE TABLE airlines (
    airline_id SERIAL PRIMARY KEY,
    code VARCHAR(3) UNIQUE NOT NULL,
    name VARCHAR(100) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_airlines_code ON airlines(code);

-- Aircraft table
CREATE TABLE aircraft (
    aircraft_id SERIAL PRIMARY KEY,
    registration VARCHAR(10) UNIQUE NOT NULL,
    model VARCHAR(50) NOT NULL,
    total_seats INTEGER NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Flights table
CREATE TABLE flights (
    flight_id SERIAL PRIMARY KEY,
    airline_id INTEGER REFERENCES airlines(airline_id),
    flight_number VARCHAR(10) NOT NULL,
    aircraft_id INTEGER REFERENCES aircraft(aircraft_id),
    origin VARCHAR(3) NOT NULL,
    destination VARCHAR(3) NOT NULL,
    departure_time TIMESTAMP NOT NULL,
    arrival_time TIMESTAMP NOT NULL,
    base_price DECIMAL(10,2) NOT NULL,
    status VARCHAR(20) DEFAULT 'scheduled',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(flight_number, departure_time)
);

CREATE INDEX idx_flights_departure ON flights(departure_time);
CREATE INDEX idx_flights_route ON flights(origin, destination);
CREATE INDEX idx_flights_status ON flights(status);

-- Seats table (normalized)
CREATE TABLE seats (
    seat_id SERIAL PRIMARY KEY,
    flight_id INTEGER REFERENCES flights(flight_id),
    seat_number VARCHAR(5) NOT NULL,
    class VARCHAR(20) NOT NULL,
    is_available BOOLEAN DEFAULT TRUE,
    version INTEGER DEFAULT 0,
    UNIQUE(flight_id, seat_number)
);

CREATE INDEX idx_seats_flight_available ON seats(flight_id, is_available);
CREATE INDEX idx_seats_class ON seats(class);

-- Customers table
CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    email VARCHAR(255) UNIQUE NOT NULL,
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100) NOT NULL,
    phone VARCHAR(20),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_customers_email ON customers(email);

-- Bookings table (Transactional)
CREATE TABLE bookings (
    booking_id SERIAL PRIMARY KEY,
    customer_id INTEGER REFERENCES customers(customer_id),
    booking_reference VARCHAR(10) UNIQUE NOT NULL,
    total_amount DECIMAL(10,2) NOT NULL,
    status VARCHAR(20) DEFAULT 'pending',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_bookings_customer ON bookings(customer_id);
CREATE INDEX idx_bookings_status ON bookings(status);
CREATE INDEX idx_bookings_created ON bookings(created_at);

-- Booking Details
CREATE TABLE booking_details (
    booking_detail_id SERIAL PRIMARY KEY,
    booking_id INTEGER REFERENCES bookings(booking_id),
    seat_id INTEGER REFERENCES seats(seat_id),
    passenger_name VARCHAR(200) NOT NULL,
    price DECIMAL(10,2) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(booking_id, seat_id)
);

CREATE INDEX idx_booking_details_booking ON booking_details(booking_id);
CREATE INDEX idx_booking_details_seat ON booking_details(seat_id);

-- Function to prevent deadlocks: Order locks by seat_id
CREATE OR REPLACE FUNCTION book_seats(
    p_booking_id INTEGER,
    p_seat_ids INTEGER[],
    p_passenger_names TEXT[],
    p_prices DECIMAL[]
) RETURNS BOOLEAN AS $$
DECLARE
    v_seat_id INTEGER;
    v_idx INTEGER;
    v_is_available BOOLEAN;
    sorted_seat_ids INTEGER[];
BEGIN
    SELECT ARRAY_AGG(seat_id ORDER BY seat_id)
    INTO sorted_seat_ids
    FROM UNNEST(p_seat_ids) AS seat_id;
    
    FOR v_idx IN 1..array_length(sorted_seat_ids, 1) LOOP
        v_seat_id := sorted_seat_ids[v_idx];
        
        SELECT is_available INTO v_is_available
        FROM seats
        WHERE seat_id = v_seat_id
        FOR UPDATE NOWAIT;
        
        IF NOT v_is_available THEN
            RAISE EXCEPTION 'Seat % is not available', v_seat_id;
        END IF;
    END LOOP;
    
    FOR v_idx IN 1..array_length(sorted_seat_ids, 1) LOOP
        v_seat_id := sorted_seat_ids[v_idx];
        
        UPDATE seats
        SET is_available = FALSE, version = version + 1
        WHERE seat_id = v_seat_id;
        
        INSERT INTO booking_details (booking_id, seat_id, passenger_name, price)
        VALUES (p_booking_id, v_seat_id, p_passenger_names[v_idx], p_prices[v_idx]);
    END LOOP;
    
    RETURN TRUE;
EXCEPTION
    WHEN lock_not_available THEN
        RAISE EXCEPTION 'Could not acquire lock on seat. Please try again.';
    WHEN OTHERS THEN
        RAISE;
END;
$$ LANGUAGE plpgsql;

-- Batch update function
CREATE OR REPLACE FUNCTION batch_update_flight_status(
    p_flight_ids INTEGER[],
    p_new_status VARCHAR
) RETURNS INTEGER AS $$
DECLARE
    rows_updated INTEGER;
BEGIN
    UPDATE flights
    SET status = p_new_status
    WHERE flight_id = ANY(p_flight_ids)
    AND status != p_new_status;
    
    GET DIAGNOSTICS rows_updated = ROW_COUNT;
    RETURN rows_updated;
END;
$$ LANGUAGE plpgsql;

-- Trigger to update booking timestamp
CREATE OR REPLACE FUNCTION update_booking_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER booking_update_timestamp
BEFORE UPDATE ON bookings
FOR EACH ROW
EXECUTE FUNCTION update_booking_timestamp();

-- Create publication for logical replication
CREATE PUBLICATION reports_pub FOR TABLE 
    airlines, flights, bookings, booking_details, customers, seats;

-- Insert sample data
INSERT INTO airlines (code, name) VALUES
('AA', 'American Airlines'),
('UA', 'United Airlines'),
('DL', 'Delta Air Lines'),
('SW', 'Southwest Airlines'),
('BA', 'British Airways');

INSERT INTO aircraft (registration, model, total_seats) VALUES
('N12345', 'Boeing 737-800', 180),
('N23456', 'Airbus A320', 150),
('N34567', 'Boeing 777-300', 350),
('N45678', 'Airbus A350', 300),
('N56789', 'Boeing 787-9', 250);

-- Generate sample flights (simpler version)
INSERT INTO flights (airline_id, flight_number, aircraft_id, origin, destination, departure_time, arrival_time, base_price, status)
SELECT 
    (SELECT airline_id FROM airlines ORDER BY RANDOM() LIMIT 1),
    'FL' || LPAD(n::TEXT, 4, '0'),
    (SELECT aircraft_id FROM aircraft ORDER BY RANDOM() LIMIT 1),
    (ARRAY['JFK', 'LAX', 'ORD', 'DFW', 'DEN'])[FLOOR(RANDOM() * 5 + 1)],
    (ARRAY['MIA', 'SEA', 'BOS', 'ATL', 'SFO'])[FLOOR(RANDOM() * 5 + 1)],
    CURRENT_DATE + (n * 3 || ' hours')::INTERVAL,
    CURRENT_DATE + ((n * 3 + 2) || ' hours')::INTERVAL,
    200 + RANDOM() * 300,
    'scheduled'
FROM generate_series(1, 50) n;

-- Create seats for each flight
-- Create seats for each flight
INSERT INTO seats (flight_id, seat_number, class, is_available)
SELECT 
    f.flight_id,
    (CASE 
        WHEN s.n <= 20 THEN 'F'
        WHEN s.n <= 50 THEN 'B'
        ELSE 'E'
    END) || 
    LPAD((((s.n - 1) / 6) + 1)::TEXT, 2, '0') ||  -- Row number: divide by 6 seats per row
    (ARRAY['A', 'B', 'C', 'D', 'E', 'F'])[(s.n - 1) % 6 + 1],  -- Column letter
    CASE 
        WHEN s.n <= 20 THEN 'First'
        WHEN s.n <= 50 THEN 'Business'
        ELSE 'Economy'
    END,
    TRUE
FROM flights f
CROSS JOIN generate_series(1, 180) s(n);

-- Generate sample customers
INSERT INTO customers (email, first_name, last_name, phone)
SELECT
    'customer' || n || '@example.com',
    'First' || n,
    'Last' || n,
    '+1555000' || LPAD(n::TEXT, 4, '0')
FROM generate_series(1, 1000) n;

-- Grant privileges
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO replicator;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO replicator;