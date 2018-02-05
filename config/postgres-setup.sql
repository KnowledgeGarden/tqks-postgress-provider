--
-- File: postgres-setup.sql
--
-- Copyright 2018, TopicQuests
--
-- This SQL script creates the roles, schemas, tables, and indexes
-- necessary for topic maps.
--

-- Run as superuser.

-- Create the tablespace for TopicQuests data.
CREATE TABLESPACE tq_space LOCATION '/var/lib/pgsql/tq';

-- Primary roles
CREATE ROLE tq_users;    -- full access to user information
CREATE ROLE tq_users_ro; -- read-only access user information
CREATE ROLE tq_proxy;    -- full access to proxy information
CREATE ROLE tq_proxy_ro; -- read-only access to proxy information

CREATE USER tq_admin PASSWORD 'md50cc925a0f68135ed505afa9f1aeaf5dd'  -- full access
    CREATEDB
    NOINHERIT IN ROLE tq_users, tq_proxy;
GRANT CREATE ON TABLESPACE tq_space TO tq_admin;

CREATE USER tq_user PASSWORD 'md50c6d478265233f1cc3ff062c7e5ef382'  -- limited access
    NOINHERIT IN ROLE tq_users_ro, tq_proxy_ro;

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";


-- Switch to the tq_admin user to create the database for TQ objects.
SET ROLE tq_admin;

-- Create the database.
CREATE DATABASE tq_database ENCODING UTF8 TABLESPACE tq_space;

-- Switch to tq_database.
\c tq_database

--
-- Create a schema to hide the authentication table from public view.
--
CREATE SCHEMA IF NOT EXISTS tq_authentication;
GRANT ALL ON schema tq_authentication TO tq_users;
GRANT USAGE ON schema tq_authentication TO tq_users_ro;

CREATE TABLE IF NOT EXISTS
tq_authentication.users (
  userid       UUID UNIQUE DEFAULT uuid_generate_v4(),
  email        text UNIQUE NOT NULL check ( email ~* '^.+@.+\..+$' ),
  password     varchar(512) NOT NULL,
  handle       varchar(32) UNIQUE NOT NULL,
  first_name   text,
  last_name    text,
  language     text DEFAULT 'en' check (length(language) = 2),
  active       boolean default true,  -- true = active user
  PRIMARY KEY(userid, handle)
);

GRANT ALL PRIVILEGES ON tq_authentication.users TO tq_users;
GRANT SELECT ON tq_authentication.users TO tq_users_ro;

-- Create an index on the email column.
CREATE INDEX IF NOT EXISTS users_idx
  ON tq_authentication.users (email);

-- Encrypt the password for in inserted user.
CREATE OR REPLACE FUNCTION
tq_authentication.encrypt_password() returns trigger
  language plpgsql
  as $$
begin
  if tg_op = 'INSERT' or new.password <> old.password then
    new.password = crypt(new.password, gen_salt('bf'));
  end if;
  return new;
end
$$;

-- Trigger on insert into users table to encrypt the password.
DROP TRIGGER IF EXISTS encrypt_password ON tq_authentication.users;
CREATE TRIGGER encrypt_password
  before insert or update on tq_authentication.users
  for each row
  execute procedure tq_authentication.encrypt_password();

-- Validate a password for a given handle. Return the user ID if valid.
CREATE OR REPLACE FUNCTION
tq_authentication.user_locator(handle text, password text) returns name
  LANGUAGE plpgsql
  AS $$
BEGIN
  RETURN (
  SELECT userid FROM tq_authentication.users
   WHERE users.handle = user_locator.handle
     AND users.password = crypt(user_locator.password, users.password)
  );
END;
$$;

-- User log.
CREATE TABLE IF NOT EXISTS
tq_authentication.user_log (
  userid       UUID PRIMARY KEY,
  event_time   TIMESTAMPTZ DEFAULT NOW(),
  event        varchar(1024) NOT NULL
);

GRANT ALL PRIVILEGES ON tq_authentication.user_log TO tq_users;
GRANT SELECT ON tq_authentication.user_log TO tq_users_ro;


--
-- Create a schema to hide the proxy tables from public view.
--
CREATE SCHEMA IF NOT EXISTS tq_contents;
GRANT ALL ON schema tq_contents TO tq_proxy;
GRANT USAGE ON schema tq_contents TO tq_proxy_ro;

CREATE TABLE IF NOT EXISTS
tq_contents.proxy (
  proxyid      UUID DEFAULT uuid_generate_v4(),
  userid       UUID,
  node_type    text,
  url          text,
  is_virtual   boolean DEFAULT false,
  is_private   boolean DEFAULT false,
  is_live      boolean DEFAULT true,
  PRIMARY KEY (proxyid, userid)
);

GRANT ALL PRIVILEGES ON tq_contents.proxy TO tq_proxy;
GRANT SELECT ON tq_contents.proxy TO tq_proxy_ro;

--
-- Table to hold merge tuple locators.
--
CREATE TABLE IF NOT EXISTS
tq_contents.merge_tuple_locators (
  proxyid      UUID PRIMARY KEY,
  locator      text  -- merge tuple locator: many locators can be
                     -- associated with a proxy
);

--
-- Table to hold labels.
--
CREATE TABLE IF NOT EXISTS
tq_contents.labels (
  proxyid      UUID PRIMARY KEY,
  label        text NOT NULL check (length(event) < 1024),
  language     text NOT NULL check (length(language) = 2)
);


--
-- Table to hold details.
--
CREATE TABLE IF NOT EXISTS
tq_contents.details (
  proxyid      UUID PRIMARY KEY,
  details      varchar(1024) NOT NULL,
  language     text NOT NULL check (length(language) = 2)
);

--
-- Table to hold superclass IDs.
--
CREATE TABLE IF NOT EXISTS
tq_contents.superclasses (
  proxyid      UUID PRIMARY KEY,
  superclass   text  -- superclass locator
);

--
-- Table to hold superclass PSIs.
--
CREATE TABLE IF NOT EXISTS
tq_contents.psi (
  proxyid      UUID PRIMARY KEY,
  psi          text
);

--
-- Table to hold properties.
--
CREATE TABLE IF NOT EXISTS
tq_contents.properties (
  proxyid      UUID,
  property_key text,
  property_val text,
  PRIMARY KEY (proxyid, property_key)
);

--
-- Table to hold transitive closure.
--
CREATE TABLE IF NOT EXISTS
tq_contents.transitive_closure (
  proxyid       UUID PRIMARY KEY,
  property_type text
);

--
-- Table to hold ACL information.
--
CREATE TABLE IF NOT EXISTS
tq_contents.acls (
  proxyid       UUID PRIMARY KEY,
  acl           text
);

--
-- Table to hold subjects.
--
CREATE TABLE IF NOT EXISTS
tq_contents.subjects (
  proxyid       UUID PRIMARY KEY,
  creator       UUID,  -- user locator
  subject       text,
  comment       text,
  language      text NOT NULL check (length(language) = 2),
  last_edit     TIMESTAMPTZ DEFAULT NOW()
);

--
-- Table to hold body text.
--
CREATE TABLE IF NOT EXISTS
tq_contents.bodies (
  proxyid       UUID PRIMARY KEY,
  creator       UUID,  -- user locator
  body          text,
  comment       text,
  language      text NOT NULL check (length(language) = 2),
  last_edit     TIMESTAMPTZ DEFAULT NOW()
);


--
-- Table to contain the audit trail of all proxies.
--
CREATE TABLE IF NOT EXISTS
tq_contents.proxy_provenence (
  proxyid      UUID PRIMARY KEY,
  event_time   TIMESTAMPTZ DEFAULT NOW(),
  event        varchar(1024) NOT NULL
);

GRANT ALL PRIVILEGES ON tq_contents.proxy_provenence TO tq_proxy;
GRANT SELECT ON tq_contents.proxy_provenence TO tq_proxy_ro;