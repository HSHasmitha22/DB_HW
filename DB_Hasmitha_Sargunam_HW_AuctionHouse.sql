-- Auction House: logical model implemented as PostgreSQL DDL (3NF)
-- Naming: snake_case, singular table names, <table>_id surrogate keys.

CREATE TABLE participant (
    participant_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    first_name     varchar(60)  NOT NULL,
    last_name      varchar(60)  NOT NULL,
    email          varchar(100) NOT NULL UNIQUE,
    phone          varchar(25),
    registered_at  timestamptz  NOT NULL DEFAULT now()
);
CREATE TABLE role (
    role_id   int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    role_name varchar(30) NOT NULL UNIQUE
);
CREATE TABLE participant_role (
    participant_id integer  NOT NULL REFERENCES participant(participant_id),
    role_id        int NOT NULL REFERENCES role(role_id),
    valid_from     date     NOT NULL DEFAULT CURRENT_DATE,
    valid_to       date,
    PRIMARY KEY (participant_id, role_id, valid_from),
    CONSTRAINT ck_participant_role_period CHECK (valid_to IS NULL OR valid_to > valid_from)
);
CREATE UNIQUE INDEX ux_participant_role_open
    ON participant_role (participant_id, role_id) WHERE valid_to IS NULL;

CREATE TABLE participant_address (
    participant_address_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    participant_id integer     NOT NULL REFERENCES participant(participant_id),
    country_code   char(2)     NOT NULL CHECK (country_code ~ '^[A-Z]{2}$'),
    city           varchar(80) NOT NULL,
    street_line    varchar(120) NOT NULL,
    postal_code    varchar(15) NOT NULL,
    valid_from     date        NOT NULL DEFAULT CURRENT_DATE,
    valid_to       date,
    CONSTRAINT ck_participant_address_period CHECK (valid_to IS NULL OR valid_to > valid_from)
);
CREATE UNIQUE INDEX ux_participant_address_current
    ON participant_address (participant_id) WHERE valid_to IS NULL;

CREATE TABLE category (
    category_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    parent_category_id integer REFERENCES category(category_id),
    category_name      varchar(80) NOT NULL,
    CONSTRAINT ck_category_not_own_parent CHECK (parent_category_id IS NULL OR parent_category_id <> category_id),
    CONSTRAINT uq_category_name_per_parent UNIQUE NULLS NOT DISTINCT (parent_category_id, category_name)
);
CREATE TABLE item (
    item_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    category_id   integer      NOT NULL REFERENCES category(category_id),
    title         varchar(150) NOT NULL,
    description   text,
    creation_year smallint CHECK (creation_year BETWEEN 0 AND 2100),
    registered_at timestamptz  NOT NULL DEFAULT now()
);
CREATE TABLE item_ownership (
    item_ownership_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    item_id    integer NOT NULL REFERENCES item(item_id),
    owner_id   integer NOT NULL REFERENCES participant(participant_id),
    valid_from date    NOT NULL DEFAULT CURRENT_DATE,
    valid_to   date,
    CONSTRAINT ck_item_ownership_period CHECK (valid_to IS NULL OR valid_to > valid_from)
);
CREATE UNIQUE INDEX ux_item_ownership_current ON item_ownership (item_id) WHERE valid_to IS NULL;

CREATE TABLE item_appraisal (
    appraisal_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    item_id       integer       NOT NULL REFERENCES item(item_id),
    appraiser_id  integer       NOT NULL REFERENCES participant(participant_id),
    estimate_low  numeric(12,2) NOT NULL CHECK (estimate_low >= 0),
    estimate_high numeric(12,2) NOT NULL,
    appraised_at  timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT ck_item_appraisal_range CHECK (estimate_high >= estimate_low)
);
CREATE TABLE auction (
    auction_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    auctioneer_id integer      NOT NULL REFERENCES participant(participant_id),
    title         varchar(150) NOT NULL,
    format        varchar(10)  NOT NULL CHECK (format IN ('LIVE','ONLINE')),
    starts_at     timestamptz  NOT NULL,
    ends_at       timestamptz  NOT NULL,
    CONSTRAINT ck_auction_time CHECK (ends_at > starts_at)
);

CREATE TABLE lot (
    lot_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    auction_id    integer       NOT NULL REFERENCES auction(auction_id),
    item_id       integer       NOT NULL REFERENCES item(item_id),
    lot_number    smallint      NOT NULL CHECK (lot_number > 0),
    start_price   numeric(12,2) NOT NULL CHECK (start_price >= 0),
    reserve_price numeric(12,2),
    bid_increment numeric(12,2) NOT NULL DEFAULT 10 CHECK (bid_increment > 0),
    CONSTRAINT ck_lot_reserve CHECK (reserve_price IS NULL OR reserve_price >= start_price),
    CONSTRAINT uq_lot_number_per_auction UNIQUE (auction_id, lot_number),
    CONSTRAINT uq_item_once_per_auction  UNIQUE (auction_id, item_id)
);
CREATE TABLE lot_status_history (
    lot_id     integer     NOT NULL REFERENCES lot(lot_id),
    changed_at timestamptz NOT NULL DEFAULT now(),
    status     varchar(12) NOT NULL CHECK (status IN ('SCHEDULED','OPEN','SOLD','UNSOLD','WITHDRAWN')),
    PRIMARY KEY (lot_id, changed_at)
);
CREATE TABLE bid (
    bid_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    lot_id    integer       NOT NULL REFERENCES lot(lot_id),
    bidder_id integer       NOT NULL REFERENCES participant(participant_id),
    amount    numeric(12,2) NOT NULL CHECK (amount > 0),
    placed_at timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT uq_bid_amount_per_lot UNIQUE (lot_id, amount),
    CONSTRAINT uq_bid_with_lot       UNIQUE (bid_id, lot_id)
);
CREATE TABLE fee_schedule (
    fee_schedule_id       int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    buyer_premium_pct     numeric(5,2) NOT NULL CHECK (buyer_premium_pct BETWEEN 0 AND 100),
    seller_commission_pct numeric(5,2) NOT NULL CHECK (seller_commission_pct BETWEEN 0 AND 100),
    valid_from            date NOT NULL,
    valid_to              date,
    CONSTRAINT ck_fee_schedule_period CHECK (valid_to IS NULL OR valid_to > valid_from)
);
CREATE TABLE sale (
    sale_id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    lot_id          integer     NOT NULL UNIQUE REFERENCES lot(lot_id),
    winning_bid_id  bigint      NOT NULL UNIQUE,
    fee_schedule_id smallint    NOT NULL REFERENCES fee_schedule(fee_schedule_id),
    sold_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT fk_sale_winning_bid_same_lot
        FOREIGN KEY (winning_bid_id, lot_id) REFERENCES bid(bid_id, lot_id)
);
CREATE TABLE payment (
    payment_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sale_id    integer       NOT NULL REFERENCES sale(sale_id),
    amount     numeric(12,2) NOT NULL CHECK (amount > 0),
    method     varchar(15)   NOT NULL CHECK (method IN ('CARD','BANK_TRANSFER','CASH')),
    paid_at    timestamptz   NOT NULL DEFAULT now()
);
CREATE INDEX ix_bid_lot_amount      ON bid (lot_id, amount DESC);
CREATE INDEX ix_bid_bidder          ON bid (bidder_id);
CREATE INDEX ix_item_category       ON item (category_id);
CREATE INDEX ix_lot_item            ON lot (item_id);
CREATE INDEX ix_payment_sale        ON payment (sale_id);
