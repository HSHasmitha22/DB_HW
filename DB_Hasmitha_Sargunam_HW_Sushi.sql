-- Sushi restaurant: orders and delivery (3NF), generic SQL (PostgreSQL style)

CREATE TABLE city (
    city_id INTEGER GENERATED ALWAYS AS IDENTITY,
    name VARCHAR(100) NOT NULL UNIQUE,
    PRIMARY KEY (city_id)
);
CREATE TABLE district (
    district_id INTEGER GENERATED ALWAYS AS IDENTITY,
    city_id INT NOT NULL,
    name VARCHAR(100) NOT NULL,
    delivery_fee DECIMAL(6,2) NOT NULL,
    PRIMARY KEY (district_id),
    FOREIGN KEY (city_id) REFERENCES city(city_id),
    CHECK (delivery_fee >= 0),
    UNIQUE (city_id, name)
);
CREATE TABLE street (
    street_id INTEGER GENERATED ALWAYS AS IDENTITY,
    district_id INT NOT NULL,
    name VARCHAR(100) NOT NULL,
    PRIMARY KEY (street_id),
    FOREIGN KEY (district_id) REFERENCES district(district_id),
    UNIQUE (district_id, name)
);
CREATE TABLE customer (
    customer_id INTEGER GENERATED ALWAYS AS IDENTITY,
    first_name VARCHAR(50) NOT NULL,
    last_name VARCHAR(50) NOT NULL,
    phone VARCHAR(20) NOT NULL UNIQUE,
    email VARCHAR(100) UNIQUE,
    created_at TIMESTAMP NOT NULL,
    PRIMARY KEY (customer_id)
);
CREATE TABLE address (
    address_id INTEGER GENERATED ALWAYS AS IDENTITY,
    customer_id INT NOT NULL,
    street_id INT NOT NULL,
    house_no VARCHAR(10) NOT NULL,
    apartment VARCHAR(10),
    entrance VARCHAR(5),
    floor SMALLINT,
    note VARCHAR(200),
    PRIMARY KEY (address_id),
    FOREIGN KEY (customer_id) REFERENCES customer(customer_id),
    FOREIGN KEY (street_id) REFERENCES street(street_id)
);
CREATE TABLE menu_category (
    category_id INTEGER GENERATED ALWAYS AS IDENTITY,
    name VARCHAR(50) NOT NULL UNIQUE,
    PRIMARY KEY (category_id)
);
CREATE TABLE product (
    product_id INTEGER GENERATED ALWAYS AS IDENTITY,
    category_id INT NOT NULL,
    name VARCHAR(100) NOT NULL UNIQUE,
    description VARCHAR(300),
    price DECIMAL(8,2) NOT NULL,
    weight_g INT,
    is_available BOOLEAN NOT NULL,
    PRIMARY KEY (product_id),
    FOREIGN KEY (category_id) REFERENCES menu_category(category_id),
    CHECK (price > 0),
    CHECK (weight_g > 0)
);
CREATE TABLE ingredient (
    ingredient_id INTEGER GENERATED ALWAYS AS IDENTITY,
    name VARCHAR(80) NOT NULL UNIQUE,
    unit VARCHAR(10) NOT NULL,
    PRIMARY KEY (ingredient_id)
);
CREATE TABLE product_ingredient (
    product_id INT,
    ingredient_id INT,
    quantity DECIMAL(8,3) NOT NULL,
    PRIMARY KEY (product_id, ingredient_id),
    FOREIGN KEY (product_id) REFERENCES product(product_id),
    FOREIGN KEY (ingredient_id) REFERENCES ingredient(ingredient_id),
    CHECK (quantity > 0) 
);
CREATE TABLE allergen (
    allergen_id INTEGER GENERATED ALWAYS AS IDENTITY,
    name VARCHAR(50) NOT NULL UNIQUE,
    PRIMARY KEY (allergen_id)
);
CREATE TABLE product_allergen (
    product_id INT,
    allergen_id INT,
    PRIMARY KEY (product_id, allergen_id),
    FOREIGN KEY (product_id) REFERENCES product(product_id),
    FOREIGN KEY (allergen_id) REFERENCES allergen(allergen_id)
);
CREATE TABLE order_status (
    status_id INTEGER GENERATED ALWAYS AS IDENTITY,
    name VARCHAR(30) NOT NULL UNIQUE,
    PRIMARY KEY (status_id)
);
CREATE TABLE payment_method (
    method_id INTEGER GENERATED ALWAYS AS IDENTITY,
    name VARCHAR(30) NOT NULL UNIQUE,
    PRIMARY KEY (method_id)
);
CREATE TABLE promo_code (
    promo_id INTEGER GENERATED ALWAYS AS IDENTITY,
    code VARCHAR(20) NOT NULL UNIQUE,
    discount_percent DECIMAL(5,2) NOT NULL,
    valid_from DATE NOT NULL,
    valid_to DATE NOT NULL,
    PRIMARY KEY (promo_id),
    CHECK (discount_percent BETWEEN 0 AND 100)
);
CREATE TABLE orders (
    order_id INTEGER GENERATED ALWAYS AS IDENTITY,
    customer_id INT NOT NULL,
    address_id INT NOT NULL,
    status_id INT NOT NULL,
    promo_id INT,
    accepted_at TIMESTAMP NOT NULL,
    requested_time TIMESTAMP,
    delivery_fee DECIMAL(6,2) NOT NULL,
    comment VARCHAR(300),
    PRIMARY KEY (order_id),
    FOREIGN KEY (customer_id) REFERENCES customer(customer_id),
    FOREIGN KEY (address_id) REFERENCES address(address_id),
    FOREIGN KEY (status_id) REFERENCES order_status(status_id),
    FOREIGN KEY (promo_id) REFERENCES promo_code(promo_id)
);
CREATE TABLE order_item (
    order_id INT,
    product_id INT,
    quantity SMALLINT NOT NULL,
    unit_price DECIMAL(8,2) NOT NULL,
    PRIMARY KEY (order_id, product_id),
    FOREIGN KEY (order_id) REFERENCES orders(order_id),
    FOREIGN KEY (product_id) REFERENCES product(product_id),
    CHECK (quantity > 0),
    CHECK (unit_price > 0)
);
CREATE TABLE order_status_history (
    history_id INTEGER GENERATED ALWAYS AS IDENTITY,
    order_id INT NOT NULL,
    status_id INT NOT NULL,
    changed_at TIMESTAMP NOT NULL,
    PRIMARY KEY (history_id),
    FOREIGN KEY (order_id) REFERENCES orders(order_id),
    FOREIGN KEY (status_id) REFERENCES order_status(status_id)
);
CREATE TABLE payment (
    payment_id INTEGER GENERATED ALWAYS AS IDENTITY,
    order_id INT NOT NULL UNIQUE,
    method_id INT NOT NULL,
    amount DECIMAL(8,2) NOT NULL,
    paid_at TIMESTAMP,
    PRIMARY KEY (payment_id),
    FOREIGN KEY (order_id) REFERENCES orders(order_id),
    FOREIGN KEY (method_id) REFERENCES payment_method(method_id),
    CHECK (amount >= 0)
);

CREATE TABLE vehicle_type (
    vehicle_type_id INTEGER GENERATED ALWAYS AS IDENTITY,
    name VARCHAR(30) NOT NULL UNIQUE,
    PRIMARY KEY (vehicle_type_id)
);
CREATE TABLE courier (
    courier_id INTEGER GENERATED ALWAYS AS IDENTITY,
    vehicle_type_id INT NOT NULL,
    first_name VARCHAR(50) NOT NULL,
    last_name VARCHAR(50) NOT NULL,
    phone VARCHAR(20) NOT NULL UNIQUE,
    hired_at DATE NOT NULL,
    is_active BOOLEAN NOT NULL,
    PRIMARY KEY (courier_id),
    FOREIGN KEY (vehicle_type_id) REFERENCES vehicle_type(vehicle_type_id)
);
CREATE TABLE courier_shift (
    shift_id INTEGER GENERATED ALWAYS AS IDENTITY,
    courier_id INT NOT NULL,
    shift_start TIMESTAMP NOT NULL,
    shift_end TIMESTAMP NOT NULL,
    PRIMARY KEY (shift_id),
    FOREIGN KEY (courier_id) REFERENCES courier(courier_id),
    CHECK (shift_end > shift_start)
);
CREATE TABLE delivery (
    delivery_id INTEGER GENERATED ALWAYS AS IDENTITY,
    order_id INT NOT NULL UNIQUE,
    courier_id INT NOT NULL,
    assigned_at TIMESTAMP NOT NULL,
    picked_up_at TIMESTAMP,
    delivered_at TIMESTAMP,
    PRIMARY KEY (delivery_id),
    FOREIGN KEY (order_id) REFERENCES orders(order_id),
    FOREIGN KEY (courier_id) REFERENCES courier(courier_id)
);
CREATE TABLE review (
    review_id INTEGER GENERATED ALWAYS AS IDENTITY,
    order_id INT NOT NULL UNIQUE,
    rating SMALLINT NOT NULL,
    comment VARCHAR(500),
    created_at TIMESTAMP NOT NULL,
    PRIMARY KEY (review_id),
    FOREIGN KEY (order_id) REFERENCES orders(order_id),
    CHECK (rating BETWEEN 1 AND 5)
);
